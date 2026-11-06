import AppKit
import Darwin
import Foundation

enum RemoteVoiceFocus: String { case local, remote, unknown }

/// Reads only the user-selected public Deskflow log. Raw lines never leave this reader.
final class RemoteVoiceFocusReader {
    private let url: URL
    private let isSourceRunning: () -> Bool
    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var partial = Data()
    private var oversizedLine = false
    private var focus: RemoteVoiceFocus = .unknown

    init(url: URL, isSourceRunning: @escaping () -> Bool) {
        self.url = url
        self.isSourceRunning = isSourceRunning
    }

    static func transition(_ line: String, from state: RemoteVoiceFocus) -> RemoteVoiceFocus {
        if line.contains("entering screen") { return .local }
        if line.contains("leaving screen") || line.contains("connected to server") { return .remote }
        if ["disconnected", "connection failed", "failed to connect", "server is dead",
            "connection reset", "connection timed out", "suspend"].contains(where: line.contains) {
            return .unknown
        }
        return state
    }

    func snapshot() -> RemoteVoiceFocus {
        guard isSourceRunning(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let nextInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { focus = .unknown; return .unknown }
        do {
            if handle == nil || nextInode != inode || size < offset {
                try? handle?.close()
                handle = try FileHandle(forReadingFrom: url)
                inode = nextInode
                offset = size > 65_536 ? size - 65_536 : 0
                partial.removeAll(keepingCapacity: true)
                oversizedLine = offset > 0
                focus = .unknown
            }
            guard let handle else { return .unknown }
            if size > offset {
                if size - offset > 65_536 {
                    offset = size - 65_536
                    partial.removeAll(keepingCapacity: true)
                    oversizedLine = true
                    focus = .unknown
                }
                try handle.seek(toOffset: offset)
                let bytes = try handle.read(upToCount: Int(min(65_536, size - offset))) ?? Data()
                offset += UInt64(bytes.count)
                for byte in bytes {
                    if byte == 10 {
                        if !oversizedLine, let line = String(data: partial, encoding: .utf8) {
                            focus = Self.transition(line, from: focus)
                        }
                        partial.removeAll(keepingCapacity: true)
                        oversizedLine = false
                    } else if !oversizedLine, partial.count < 4_096 {
                        partial.append(byte)
                    } else {
                        // Never treat the suffix of an oversized line as a focus event.
                        oversizedLine = true
                        partial.removeAll(keepingCapacity: true)
                    }
                }
            }
            return focus
        } catch { focus = .unknown; return .unknown }
    }

    deinit { try? handle?.close() }

    static func selectedServerMatches(url: URL, expected: String) -> Bool {
        guard !expected.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 65_536,
              let file = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var client = false
        for raw in file.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { client = line == "[client]" }
            else if client, line.hasPrefix("remoteHost=") {
                return String(line.dropFirst("remoteHost=".count)) == expected
            }
        }
        return false
    }
}

enum RemoteVoiceWire {
    static let maximumBody = 65_536
    static func frame(_ kind: UInt8, session: UUID? = nil, payload: Data = Data()) -> Data {
        var body = Data([kind])
        if var uuid = session?.uuid {
            withUnsafeBytes(of: &uuid) { body.append(contentsOf: $0) }
        }
        body.append(payload)
        var length = UInt32(body.count).littleEndian
        var result = Data()
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(body)
        return result
    }

    static func extract(_ buffer: inout Data) throws -> [Data] {
        enum Invalid: Error { case length }
        var frames: [Data] = []
        while buffer.count >= 4 {
            let size = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
            guard size > 0, size <= maximumBody else { throw Invalid.length }
            guard buffer.count >= size + 4 else { break }
            frames.append(Data(buffer[4..<(size + 4)]))
            buffer = Data(buffer.dropFirst(size + 4))
        }
        return frames
    }
}

enum RemoteVoicePipeReader {
    static let maximumRead = 4_096

    /// nil means temporarily empty; empty Data means EOF. Never wait for a full buffer.
    static func readAvailable(from handle: FileHandle) throws -> Data? {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0,
              flags & O_NONBLOCK != 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bytes = [UInt8](repeating: 0, count: maximumRead)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            let error = errno
            if error == EINTR { continue }
            if error == EAGAIN || error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
    }
}

/// One authenticated SSH stream. No new TCP listener, key material, or content log.
protocol RemoteVoiceTransporting: AnyObject {
    @discardableResult func send(_ frame: Data) -> Bool
    func cancelConnection()
    func retryIfDisconnected()
}

final class RemoteVoiceSSHTransport: RemoteVoiceTransporting {
    private let queue = DispatchQueue(label: "sayall.remote-voice.ssh", qos: .userInitiated)
    private let lock = NSLock()
    private var ready = false
    private var reserved = 0
    private var reservedReceive = 0
    private var receiveOverflow = false
    private var reservationGeneration = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var writer: DispatchSourceWrite?
    private var writerRunning = false
    private var tx = Data()
    private var rx = Data()
    private var generation = 0
    private var awaitingDrain: [Data: Int] = [:]
    private var submittedSamples: [Data: Int] = [:]
    private var awaitingStart = Set<Data>()
    private var awaitingCancel = Set<Data>()
    private var reconnects = 0
    private let host: String
    private let logger: (String) -> Void

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    init(host: String, logger: @escaping (String) -> Void) {
        self.host = host
        self.logger = logger
        connect()
    }

    private func connect() {
        queue.async { [weak self] in
            guard let self, self.process == nil,
                  self.host.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
            else { return }
            self.generation += 1
            let attempt = self.generation
            self.lock.lock(); self.reservationGeneration = attempt; self.lock.unlock()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = "& (Join-Path $env:LOCALAPPDATA 'SayAllRemoteVoice\\SayAllRemoteVoice.exe') --relay"
            let encoded = command.data(using: .utf16LittleEndian)!.base64EncodedString()
            child.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
                "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                self.host, "powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = stderr
            self.input = stdin.fileHandleForWriting
            self.output = stdout.fileHandleForReading
            self.errors = stderr.fileHandleForReading
            self.process = child
            stdout.fileHandleForReading.readabilityHandler = { [weak self] file in
                guard let self else { return }
                self.lock.lock()
                guard self.reservationGeneration == attempt else {
                    self.lock.unlock(); file.readabilityHandler = nil; return
                }
                guard self.reservedReceive + 4_096 <= 262_144 else {
                    let first = !self.receiveOverflow
                    self.receiveOverflow = true
                    self.lock.unlock()
                    file.readabilityHandler = nil
                    if first { self.queue.async { [weak self] in self?.fail("receive_backpressure") } }
                    return
                }
                self.reservedReceive += 4_096
                self.lock.unlock()
                let result = Result { try RemoteVoicePipeReader.readAvailable(from: file) }
                self.queue.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.lock.lock()
                    self.reservedReceive = max(0, self.reservedReceive - 4_096)
                    self.lock.unlock()
                    switch result {
                    case .success(let data):
                        if let data { self.receive(data, attempt: attempt) }
                    case .failure: self.fail("read_failed")
                    }
                }
            }
            // Drain SSH errors without persisting hostnames, paths, or credentials.
            stderr.fileHandleForReading.readabilityHandler = { file in _ = file.availableData }
            child.terminationHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.fail("connection_closed")
                }
            }
            do {
                try child.run()
                let fd = stdin.fileHandleForWriting.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: self.queue)
                writer.setEventHandler { [weak self] in self?.flush() }
                self.writer = writer
                self.logger("REMOTE VOICE connection=starting content_logged=false")
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.generation == attempt, !self.isReady else { return }
                    self.fail("handshake_timeout")
                }
            } catch { self.fail("launch_failed") }
        }
    }

    @discardableResult
    func send(_ frame: Data) -> Bool {
        let encoded = Data((frame.base64EncodedString() + "\n").utf8)
        lock.lock()
        guard ready, frame.count <= RemoteVoiceWire.maximumBody + 4,
              reserved + encoded.count <= 131_072 else { lock.unlock(); return false }
        reserved += encoded.count
        let attempt = reservationGeneration
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.generation == attempt, self.process != nil else { return }
            self.tx.append(encoded)
            if frame.count >= 21, frame[4] == 1 {
                let id = Data(frame[5..<21])
                guard self.awaitingStart.count < 4, self.submittedSamples.count < 4 else { self.fail("too_many_sessions"); return }
                self.awaitingStart.insert(id)
                self.submittedSamples[id] = 0
                let attempt = self.generation
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.generation == attempt, self.awaitingStart.contains(id) else { return }
                    self.fail("start_timeout")
                }
            }
            if frame.count >= 21, frame[4] == 4 {
                let id = Data(frame[5..<21])
                guard self.awaitingCancel.count < 4 else { self.fail("too_many_sessions"); return }
                self.awaitingCancel.insert(id)
            }
            if frame.count >= 21, frame[4] == 2 {
                let id = Data(frame[5..<21])
                guard let previous = self.submittedSamples[id], (frame.count - 21) % 2 == 0 else { self.fail("invalid_audio_session"); return }
                self.submittedSamples[id] = previous + (frame.count - 21) / 2
            }
            if frame.count >= 21, frame[4] == 3 {
                let id = Data(frame[5..<21])
                guard self.awaitingDrain.count < 4 else { self.fail("too_many_sessions"); return }
                guard let samples = self.submittedSamples[id] else { self.fail("invalid_end_session"); return }
                self.awaitingDrain[id] = samples
                let attempt = self.generation
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.generation == attempt, self.awaitingDrain[id] != nil else { return }
                    self.fail("drain_timeout")
                }
            }
            if !self.writerRunning { self.writerRunning = true; self.writer?.resume() }
        }
        return true
    }

    private func flush() {
        guard let input else { return }
        while !tx.isEmpty {
            let count = tx.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                fail("write_failed"); return
            }
            guard count > 0 else { return }
            tx = Data(tx.dropFirst(count))
            lock.lock(); reserved = max(0, reserved - count); lock.unlock()
        }
        if writerRunning { writerRunning = false; writer?.suspend() }
    }

    private func receive(_ data: Data, attempt: Int) {
        guard generation == attempt else { return }
        guard !data.isEmpty else { fail("stream_closed"); return }
        guard rx.count + data.count <= 180_000 else { fail("response_overflow"); return }
        rx.append(data)
        do {
            while let newline = rx.firstIndex(of: 10) {
                let line = Data(rx[..<newline].filter { $0 != 13 })
                rx = Data(rx.dropFirst(newline + 1))
                guard line.count <= 90_000, let decoded = Data(base64Encoded: line) else { fail("invalid_encoding"); return }
                var binary = decoded
                let frames = try RemoteVoiceWire.extract(&binary)
                guard frames.count == 1, binary.isEmpty, let frame = frames.first else { fail("invalid_frame_count"); return }
                switch frame.first {
                case 128:
                    guard frame.count == 2, frame[1] == 1, !isReady else { fail("protocol_mismatch"); return }
                    lock.lock(); ready = true; lock.unlock()
                    reconnects = 0
                    logger("REMOTE VOICE connection=ready content_logged=false")
                case 129:
                    guard frame.count == 17, awaitingStart.remove(Data(frame[1..<17])) != nil else { fail("invalid_ack"); return }
                    logger("REMOTE VOICE phase=target_started external_voice_result=unknown")
                case 130:
                    guard frame.count == 25 else { fail("invalid_drain_ack"); return }
                    let id = Data(frame[1..<17])
                    let played = frame[17..<25].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                    guard let expected = awaitingDrain.removeValue(forKey: id), played == UInt64(expected) else { fail("incomplete_audio_delivery"); return }
                    submittedSamples.removeValue(forKey: id)
                    logger("REMOTE VOICE phase=target_drained completion=normal external_voice_result=unknown")
                case 132:
                    guard frame.count == 17 else { fail("invalid_cancel_ack"); return }
                    let id = Data(frame[1..<17])
                    guard awaitingCancel.remove(id) != nil else { fail("invalid_cancel_ack"); return }
                    submittedSamples.removeValue(forKey: id)
                    logger("REMOTE VOICE phase=target_cancelled completion=forced external_voice_result=unknown")
                default: fail("target_failed"); return
                }
            }
            if rx.count > 90_000 { fail("response_line_overflow") }
        } catch { fail("invalid_response") }
    }

    private func fail(_ reason: String) {
        guard process != nil else { return }
        generation += 1
        lock.lock(); ready = false; reserved = 0; reservedReceive = 0; receiveOverflow = false
        reservationGeneration = generation
        lock.unlock()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        if let writer {
            if !writerRunning { writer.resume() }
            writer.cancel()
        }
        writer = nil; writerRunning = false
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
        let old = process; process = nil
        old?.terminationHandler = nil
        if old?.isRunning == true { old?.terminate() }
        tx.removeAll(); rx.removeAll(); awaitingDrain.removeAll(); awaitingStart.removeAll(); awaitingCancel.removeAll(); submittedSamples.removeAll()
        logger("REMOTE VOICE connection=failed reason=\(reason) completion=forced external_voice_result=unknown")
        if reason != "shutdown", reason != "cancelled", reconnects < 3 {
            reconnects += 1
            let attempt = generation
            let delay = Double(1 << (reconnects - 1))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == attempt else { return }
                self.connect()
            }
        }
    }

    func cancelConnection() { queue.async { [weak self] in self?.fail("cancelled") } }
    func retryIfDisconnected() { connect() }
    deinit { fail("shutdown") }
}

/// Target is fixed before the first PCM and remains fixed through ordered tail delivery.
final class RemoteVoiceRoute {
    private enum Active { case local(Int), remote(UUID, Int), blocked }
    private var active: Active = .blocked
    private let snapshot: (() -> RemoteVoiceFocus)?
    private let transport: RemoteVoiceTransporting?
    private let logger: (String) -> Void
    private let blockedSignal: () -> Void
    private let enabled: Bool
    private var samples = 0
    private var startedAt = 0.0

    init(defaults: UserDefaults = .standard, logger: @escaping (String) -> Void = AppLogger.shared.write,
         blockedSignal: @escaping () -> Void = { NSSound.beep() }) {
        self.logger = logger
        self.blockedSignal = blockedSignal
        enabled = defaults.bool(forKey: "remoteVoice.enabled")
        if enabled,
           let host = defaults.string(forKey: "remoteVoice.sshHost"),
           let path = defaults.string(forKey: "remoteVoice.focusLog"), path.hasPrefix("/"),
           let configPath = defaults.string(forKey: "remoteVoice.deskflowConfig"), configPath.hasPrefix("/"),
           let expectedServer = defaults.string(forKey: "remoteVoice.expectedDeskflowServer"), !expectedServer.isEmpty {
            var pid = pid_t(defaults.integer(forKey: "remoteVoice.deskflowPID"))
            var lastLookup = -5.0
            let running: () -> Bool = {
                func matches(_ candidate: pid_t) -> Bool {
                    guard candidate > 1, kill(candidate, 0) == 0 else { return false }
                    var buffer = [CChar](repeating: 0, count: 4_096)
                    guard proc_pidpath(candidate, &buffer, UInt32(buffer.count)) > 0 else { return false }
                    return String(cString: buffer).hasSuffix("/deskflow-core")
                }
                if matches(pid) { return true }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastLookup >= 5 else { return false }
                lastLookup = now
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = ["-U", String(geteuid()), "-x", "deskflow-core"]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit() } catch { return false }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard data.count <= 1_024, let text = String(data: data, encoding: .utf8) else { return false }
                let candidates = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                guard candidates.count == 1, let candidate = candidates.first, matches(candidate) else { return false }
                pid = candidate
                return true
            }
            _ = running() // Warm source identity at startup, outside the voice press path.
            let reader = RemoteVoiceFocusReader(url: URL(fileURLWithPath: path), isSourceRunning: running)
            _ = reader.snapshot() // Initial bounded tail parsing stays off the first voice press.
            snapshot = {
                guard RemoteVoiceFocusReader.selectedServerMatches(url: URL(fileURLWithPath: configPath), expected: expectedServer) else { return .unknown }
                return reader.snapshot()
            }
            transport = RemoteVoiceSSHTransport(host: host, logger: logger)
        } else { snapshot = nil; transport = nil }
    }

    init(snapshot: @escaping () -> RemoteVoiceFocus, transport: RemoteVoiceTransporting,
         logger: @escaping (String) -> Void = { _ in }, blockedSignal: @escaping () -> Void = {}) {
        self.snapshot = snapshot; self.transport = transport
        self.logger = logger; self.blockedSignal = blockedSignal
        enabled = true
    }

    /// true means the normal Mac pipeline owns the session.
    func begin(generation: Int) -> Bool {
        samples = 0
        startedAt = ProcessInfo.processInfo.systemUptime
        guard let snapshot, let transport else {
            if enabled {
                active = .blocked; blockedSignal()
                logger("REMOTE VOICE phase=blocked reason=configuration_incomplete")
                return false
            }
            active = .local(generation); return true
        }
        switch snapshot() {
        case .local: active = .local(generation); return true
        case .remote:
            let id = UUID()
            guard transport.send(RemoteVoiceWire.frame(1, session: id)) else {
                transport.retryIfDisconnected()
                active = .blocked; blockedSignal()
                logger("REMOTE VOICE phase=blocked reason=target_not_ready")
                return false
            }
            active = .remote(id, generation)
            logger("REMOTE VOICE phase=started target=remote content_logged=false")
        case .unknown:
            active = .blocked; blockedSignal()
            logger("REMOTE VOICE phase=blocked reason=focus_unknown")
        }
        return false
    }

    func consume(_ pcm: [Int16], generation: Int) -> Bool {
        switch active {
        case .local(let expected): return expected != generation
        case .blocked: return true
        case .remote(let id, let expected):
            guard expected == generation else { return true }
            var data = Data(capacity: pcm.count * 2)
            for var value in pcm.map({ $0.littleEndian }) { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            guard transport?.send(RemoteVoiceWire.frame(2, session: id, payload: data)) == true else {
                _ = transport?.send(RemoteVoiceWire.frame(4, session: id))
                transport?.cancelConnection()
                active = .blocked; blockedSignal()
                logger("REMOTE VOICE phase=failed reason=backpressure completion=forced received_samples=\(samples)")
                return true
            }
            if samples == 0 {
                logger("REMOTE VOICE phase=first_pcm source_start_to_submit_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))")
            }
            samples += pcm.count
            return true
        }
    }

    func end(_ reason: ChromecastVoiceEndReason) -> Bool {
        switch active {
        case .local: active = .blocked; return true
        case .blocked: return false
        case .remote(let id, _):
            defer { active = .blocked } // Late PCM must never spill into the Mac pipeline.
            let sent = transport?.send(RemoteVoiceWire.frame(reason.isNormal ? 3 : 4, session: id)) == true
            if !sent { transport?.cancelConnection() }
            logger("REMOTE VOICE phase=stop_submitted completion=\(reason.isNormal && sent ? "pending_drain" : "forced") received_samples=\(samples) external_voice_result=unknown")
            return false
        }
    }
}
