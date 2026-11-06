import Foundation
import Testing
@testable import RemoteMic

@Suite("Remote voice route")
struct RemoteVoiceRouteTests {
    final class Transport: RemoteVoiceTransporting {
        var accept = true
        var frames: [Data] = []
        var cancels = 0
        var retries = 0
        func send(_ frame: Data) -> Bool { if accept { frames.append(frame) }; return accept }
        func cancelConnection() { cancels += 1 }
        func retryIfDisconnected() { retries += 1 }
    }

    @Test func enabledIncompleteConfigurationCannotRedirectToMac() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "remoteVoice.enabled")
        var signals = 0
        let route = RemoteVoiceRoute(defaults: defaults, logger: { _ in }, blockedSignal: { signals += 1 })
        #expect(!route.begin(generation: 1))
        #expect(route.consume([1], generation: 1))
        #expect(!route.end(.holdRelease))
        #expect(signals == 1)
    }

    @Test func changedDeskflowServerInvalidatesBinding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[client]\nremoteHost=windows-host\n[other]\nremoteHost=ignored\n".utf8).write(to: url)
        #expect(RemoteVoiceFocusReader.selectedServerMatches(url: url, expected: "windows-host"))
        #expect(!RemoteVoiceFocusReader.selectedServerMatches(url: url, expected: "different-host"))
    }

    @Test func routePinsTargetAndRejectsOldOrLatePCM() {
        var focus: RemoteVoiceFocus = .remote
        let transport = Transport()
        let route = RemoteVoiceRoute(snapshot: { focus }, transport: transport)
        #expect(!route.begin(generation: 1))
        #expect(route.consume([12, -12], generation: 0))
        #expect(transport.frames.count == 1)
        focus = .local
        #expect(route.consume([12, -12], generation: 1))
        #expect(!route.end(.holdRelease))
        #expect(transport.frames.map { $0[4] } == [1, 2, 3])
        #expect(route.consume([99], generation: 1))
        #expect(transport.frames.count == 3)
        #expect(route.begin(generation: 2))
        #expect(route.consume([99], generation: 1))
        #expect(!route.consume([55], generation: 2))
        #expect(route.end(.holdRelease))
        #expect(route.consume([55], generation: 2))
        #expect(transport.frames.count == 3)
    }

    @Test func unavailableTargetDoesNotFallBackToMacAndCanRetry() {
        let transport = Transport(); transport.accept = false
        var signals = 0
        let route = RemoteVoiceRoute(snapshot: { .remote }, transport: transport, blockedSignal: { signals += 1 })
        #expect(!route.begin(generation: 1))
        #expect(route.consume([1, 2], generation: 1))
        #expect(!route.end(.holdRelease))
        #expect(signals == 1 && transport.retries == 1)
        transport.accept = true
        #expect(!route.begin(generation: 2))
        #expect(route.consume([1, 2], generation: 2))
        #expect(!route.end(.cancelled("test")))
        #expect(transport.frames.map { $0[4] } == [1, 2, 4])
    }

    @Test func audioBackpressureCancelsOnceWithoutLeakingToLocal() {
        let transport = Transport()
        let route = RemoteVoiceRoute(snapshot: { .remote }, transport: transport)
        #expect(!route.begin(generation: 1))
        transport.accept = false
        #expect(route.consume([1, 2], generation: 1))
        #expect(route.consume([3, 4], generation: 1))
        #expect(transport.cancels == 1)
        #expect(!route.end(.holdRelease))
        #expect(transport.frames.map { $0[4] } == [1])
    }

    @Test func focusUsesExplicitEdgesAndDisconnectInvalidates() {
        #expect(RemoteVoiceFocusReader.transition("INFO: connected to server", from: .unknown) == .remote)
        #expect(RemoteVoiceFocusReader.transition("INFO: entering screen", from: .remote) == .local)
        #expect(RemoteVoiceFocusReader.transition("INFO: leaving screen", from: .local) == .remote)
        #expect(RemoteVoiceFocusReader.transition("INFO: disconnected from server", from: .remote) == .unknown)
        #expect(RemoteVoiceFocusReader.transition("unrelated status", from: .local) == .local)
    }

    @Test func readerRetainsPartialLinesAndBoundsOversizedLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("INFO: entering screen\nINFO: leav".utf8).write(to: url)
        var alive = true
        let reader = RemoteVoiceFocusReader(url: url, isSourceRunning: { alive })
        #expect(reader.snapshot() == .local)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ing screen\n".utf8))
        #expect(reader.snapshot() == .remote)
        try handle.write(contentsOf: Data((String(repeating: "x", count: 6_000) + "entering screen\n").utf8))
        #expect(reader.snapshot() == .remote)
        alive = false
        #expect(reader.snapshot() == .unknown)
        try handle.close()
    }

    @Test func rotationDoesNotKeepOldFocus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("INFO: leaving screen\n".utf8).write(to: url)
        let reader = RemoteVoiceFocusReader(url: url, isSourceRunning: { true })
        #expect(reader.snapshot() == .remote)
        try Data("new log without an edge\n".utf8).write(to: url, options: .atomic)
        #expect(reader.snapshot() == .unknown)
    }

    @Test func wirePreservesBinaryPCMAndPartialFrames() throws {
        let session = UUID()
        let pcm = Data([0, 10, 13, 255, 0, 128])
        let frame = RemoteVoiceWire.frame(2, session: session, payload: pcm)
        var partial = Data(frame.prefix(12))
        #expect(try RemoteVoiceWire.extract(&partial).isEmpty)
        partial.append(frame.dropFirst(12))
        let bodies = try RemoteVoiceWire.extract(&partial)
        #expect(bodies.count == 1)
        #expect(bodies.first?.first == 2)
        #expect(bodies.first.map { Data($0.dropFirst(17)) } == pcm)
        #expect(partial.isEmpty)
        let ascii = frame.base64EncodedString()
        #expect(Data(base64Encoded: ascii) == frame)
    }

    @Test func invalidLengthsAreRejectedBeforeAllocation() {
        for size: UInt32 in [0, 65_537, .max] {
            var n = size.littleEndian
            var data = withUnsafeBytes(of: &n) { Data($0) }
            #expect(throws: (any Error).self) { _ = try RemoteVoiceWire.extract(&data) }
        }
    }
}
