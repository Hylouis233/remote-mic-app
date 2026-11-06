// Current-user desktop audio receiver and SSH stdio relay. No network listener.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SayAllRemoteVoice {
    static class FailureReason {
        static readonly HashSet<string> Known = new HashSet<string> {
            "frame_length", "frame_count", "line_length", "virtual_output_not_unique", "output_open_failed",
            "pcm_shape", "audio_backpressure", "output_prepare_failed", "output_write_failed", "session_missing",
            "session_conflict", "voice_key_failed", "session_mismatch", "drain_or_release_failed", "unknown_operation",
            "audio_probe_failed", "voice_key_not_supported"
        };
        public static string Of(Exception error) { return Known.Contains(error.Message) ? error.Message : error.GetType().Name; }
    }
    static class Wire {
        public const int Maximum = 65536;
        public static byte[] Read(Stream stream) {
            byte[] header = new byte[4];
            int first = stream.Read(header, 0, 4);
            if (first == 0) return null;
            Fill(stream, header, first, 4 - first);
            uint length = BitConverter.ToUInt32(header, 0);
            if (length == 0 || length > Maximum) throw new InvalidDataException("frame_length");
            byte[] body = new byte[(int)length];
            Fill(stream, body, 0, body.Length);
            return body;
        }
        static void Fill(Stream stream, byte[] data, int offset, int count) {
            while (count > 0) {
                int n = stream.Read(data, offset, count);
                if (n == 0) throw new EndOfStreamException();
                offset += n; count -= n;
            }
        }
        public static void Write(Stream stream, byte[] body) {
            if (body.Length == 0 || body.Length > Maximum) throw new InvalidDataException("frame_length");
            byte[] header = BitConverter.GetBytes((uint)body.Length);
            stream.Write(header, 0, 4); stream.Write(body, 0, body.Length); stream.Flush();
        }
        // SSH shells may normalize line endings. Base64 keeps native PCM intact.
        public static string ReadLine(TextReader reader) {
            StringBuilder line = new StringBuilder();
            while (true) {
                int c = reader.Read();
                if (c == -1) return line.Length == 0 ? null : line.ToString();
                if (c == '\n') return line.ToString();
                if (c != '\r') line.Append((char)c);
                if (line.Length > 90000) throw new InvalidDataException("line_length");
            }
        }
        public static byte[] DecodeLine(string line) {
            byte[] data = Convert.FromBase64String(line);
            using (MemoryStream memory = new MemoryStream(data)) {
                byte[] body = Read(memory);
                if (body == null || memory.Position != memory.Length) throw new InvalidDataException("frame_count");
                return body;
            }
        }
        public static string EncodeLine(byte[] body) {
            using (MemoryStream memory = new MemoryStream()) { Write(memory, body); return Convert.ToBase64String(memory.ToArray()); }
        }
    }

    sealed class EventLog {
        readonly object gate = new object();
        readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SayAllRemoteVoice", "Logs");
        const long Limit = 2 * 1024 * 1024;
        public void Write(string category) {
            lock (gate) {
                try {
                    Directory.CreateDirectory(directory);
                    for (int i = 0; i < 3; i++) {
                        string p = Path.Combine(directory, "events" + i + ".log");
                        if (File.Exists(p) && File.GetLastWriteTimeUtc(p) < DateTime.UtcNow.AddDays(-7)) File.Delete(p);
                    }
                    string current = Path.Combine(directory, "events0.log");
                    byte[] bytes = Encoding.UTF8.GetBytes(DateTime.UtcNow.ToString("O") + " " + category + "\n");
                    if (File.Exists(current) && new FileInfo(current).Length + bytes.Length > Limit) {
                        string last = Path.Combine(directory, "events2.log");
                        if (File.Exists(last)) File.Delete(last);
                        string previous = Path.Combine(directory, "events1.log");
                        if (File.Exists(previous)) File.Move(previous, last);
                        File.Move(current, previous);
                    }
                    using (FileStream f = new FileStream(current, FileMode.Append, FileAccess.Write, FileShare.Read)) f.Write(bytes, 0, bytes.Length);
                } catch { /* Diagnostics never capture payloads or stop cleanup. */ }
            }
        }
    }

    sealed class WaveOutput : IDisposable {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Caps {
            public ushort manufacturer, product;
            public uint version;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
            public uint formats; public ushort channels, reserved; public uint support;
        }
        [StructLayout(LayoutKind.Sequential, Pack = 2)]
        struct Format { public ushort tag, channels; public uint rate, average; public ushort align, bits, size; }
        [StructLayout(LayoutKind.Sequential)]
        struct Header {
            public IntPtr data; public uint length, recorded; public UIntPtr user;
            public uint flags, loops; public IntPtr next; public UIntPtr reserved;
        }
        delegate void WaveCallback(IntPtr device, uint message, UIntPtr instance, UIntPtr parameter, UIntPtr unused);
        [DllImport("winmm.dll")] static extern uint waveOutGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern uint waveOutGetDevCapsW(UIntPtr id, out Caps caps, uint size);
        [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr handle, uint id, ref Format format, WaveCallback callback, UIntPtr instance, uint flags);
        [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr handle, IntPtr header, uint size);
        [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr handle);
        [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr handle);
        sealed class Buffer { public IntPtr Data, Header; public int Bytes, Samples; }
        readonly object gate = new object();
        readonly Dictionary<IntPtr, Buffer> buffers = new Dictionary<IntPtr, Buffer>();
        readonly ManualResetEventSlim drained = new ManualResetEventSlim(true);
        readonly WaveCallback callback;
        IntPtr device;
        int queuedBytes;
        bool closed;
        bool resetting;
        public long PlayedSamples { get; private set; }
        public int PendingSamples { get { lock (gate) return buffers.Values.Sum(b => b.Samples); } }
        static readonly uint HeaderSize = (uint)Marshal.SizeOf(typeof(Header));

        public static string[] Devices() {
            List<string> result = new List<string>();
            for (uint i = 0; i < waveOutGetNumDevs(); i++) {
                Caps caps;
                result.Add(waveOutGetDevCapsW((UIntPtr)i, out caps, (uint)Marshal.SizeOf(typeof(Caps))) == 0 ? caps.name : "unavailable");
            }
            return result.ToArray();
        }
        public static uint Select(string requested) {
            string[] devices = Devices();
            int[] matches = Enumerable.Range(0, devices.Length).Where(i =>
                devices[i].IndexOf(requested, StringComparison.OrdinalIgnoreCase) >= 0 &&
                (devices[i].IndexOf("CABLE", StringComparison.OrdinalIgnoreCase) >= 0 || devices[i].IndexOf("VB-Audio", StringComparison.OrdinalIgnoreCase) >= 0)).ToArray();
            if (String.IsNullOrWhiteSpace(requested) || matches.Length != 1) throw new InvalidOperationException("virtual_output_not_unique");
            return (uint)matches[0];
        }
        public WaveOutput(uint id) {
            callback = OnWave;
            Format format = new Format { tag = 1, channels = 1, rate = 16000, average = 32000, align = 2, bits = 16, size = 0 };
            if (waveOutOpen(out device, id, ref format, callback, UIntPtr.Zero, 0x00030000) != 0) throw new IOException("output_open_failed");
        }
        public void Append(byte[] pcm, int samples) {
            if (pcm.Length == 0 || pcm.Length % 2 != 0 || pcm.Length > 32000) throw new InvalidDataException("pcm_shape");
            Buffer buffer = new Buffer { Bytes = pcm.Length, Samples = samples };
            lock (gate) {
                if (closed || queuedBytes + pcm.Length > 64000) throw new IOException("audio_backpressure");
                buffer.Data = Marshal.AllocHGlobal(pcm.Length); buffer.Header = Marshal.AllocHGlobal((int)HeaderSize);
                Marshal.Copy(pcm, 0, buffer.Data, pcm.Length);
                Marshal.StructureToPtr(new Header { data = buffer.Data, length = (uint)pcm.Length }, buffer.Header, false);
                if (waveOutPrepareHeader(device, buffer.Header, HeaderSize) != 0) {
                    Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data); throw new IOException("output_prepare_failed");
                }
                buffers.Add(buffer.Header, buffer); queuedBytes += pcm.Length; drained.Reset();
                if (waveOutWrite(device, buffer.Header, HeaderSize) != 0) {
                    buffers.Remove(buffer.Header); queuedBytes -= buffer.Bytes;
                    waveOutUnprepareHeader(device, buffer.Header, HeaderSize);
                    Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data);
                    if (buffers.Count == 0) drained.Set();
                    throw new IOException("output_write_failed");
                }
            }
        }
        void OnWave(IntPtr handle, uint message, UIntPtr instance, UIntPtr parameter, UIntPtr unused) {
            if (message != 0x3BD) return;
            IntPtr pointer = new IntPtr(unchecked((long)parameter.ToUInt64()));
            ThreadPool.QueueUserWorkItem(delegate {
                lock (gate) {
                    Buffer buffer;
                    if (!buffers.TryGetValue(pointer, out buffer)) return;
                    waveOutUnprepareHeader(device, pointer, HeaderSize);
                    buffers.Remove(pointer); queuedBytes -= buffer.Bytes;
                    if (!resetting) PlayedSamples += buffer.Samples;
                    Marshal.FreeHGlobal(buffer.Data); Marshal.FreeHGlobal(buffer.Header);
                    if (buffers.Count == 0) drained.Set();
                    Monitor.PulseAll(gate);
                }
            });
        }
        public bool Drain() {
            Stopwatch deadline = Stopwatch.StartNew();
            lock (gate) {
                while (queuedBytes > 64000 - 4800) {
                    int remaining = 3500 - (int)deadline.ElapsedMilliseconds;
                    if (remaining <= 0 || !Monitor.Wait(gate, remaining)) return false;
                }
                Append(new byte[4800], 0);
            }
            return drained.Wait(Math.Max(0, 3500 - (int)deadline.ElapsedMilliseconds));
        }
        public void Dispose() {
            bool pending;
            lock (gate) { if (closed) return; closed = true; pending = buffers.Count > 0; resetting = pending; }
            // Normal drain has no buffers left. Only forced cleanup resets audio.
            if (pending) { waveOutReset(device); drained.Wait(2000); }
            lock (gate) {
                foreach (Buffer b in buffers.Values) {
                    waveOutUnprepareHeader(device, b.Header, HeaderSize);
                    Marshal.FreeHGlobal(b.Data); Marshal.FreeHGlobal(b.Header);
                }
                buffers.Clear(); queuedBytes = 0;
                waveOutClose(device); device = IntPtr.Zero;
            }
            GC.KeepAlive(callback);
        }
    }

    static class VoiceKey {
        [StructLayout(LayoutKind.Sequential)] struct MouseInput { public int x, y; public uint data, flags, time; public UIntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct KeyboardInput { public ushort key, scan; public uint flags, time; public UIntPtr extra; }
        [StructLayout(LayoutKind.Explicit)] struct InputUnion {
            [FieldOffset(0)] public MouseInput mouse;
            [FieldOffset(0)] public KeyboardInput keyboard;
        }
        [StructLayout(LayoutKind.Sequential)] struct Input { public uint type; public InputUnion data; }
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
        public static bool Post(ushort key, bool down) {
            Input input = new Input { type = 1, data = new InputUnion { keyboard = new KeyboardInput { key = key,
                scan = (ushort)MapVirtualKey(key, 0), flags = down ? 0u : 2u, extra = (UIntPtr)0x53415652u } } };
            return SendInput(1, new Input[] { input }, Marshal.SizeOf(typeof(Input))) == 1;
        }
    }

    sealed class VoiceKeyLease {
        readonly ushort key;
        readonly Func<ushort, bool, bool> post;
        readonly Action<int> delay;
        public bool Held { get; private set; }
        public VoiceKeyLease(ushort key, Func<ushort, bool, bool> post, Action<int> delay) { this.key = key; this.post = post; this.delay = delay; }
        public bool Acquire() { Held = true; return post(key, true); }
        public bool Release() {
            if (!Held) return true;
            for (int i = 0; i < 3; i++) {
                if (post(key, false)) { Held = false; return true; }
                if (i != 2) delay(25);
            }
            return false;
        }
        public static bool Expired(long now, long last, long frequency) { return now - last >= frequency * 3; }
    }

    sealed class DesktopReceiver : IDisposable {
        public const string PipeName = "SayAll.RemoteVoice.v1";
        readonly EventLog log = new EventLog();
        readonly object sessionGate = new object();
        readonly uint deviceId;
        readonly VoiceKeyLease voiceKey;
        volatile bool stopping;
        NamedPipeServerStream pipe;
        WaveOutput output;
        byte[] session;
        long received;
        long lastInput;
        long startedAt;
        int cleanupRetries;
        int running;
        readonly System.Threading.Timer watchdog;

        public DesktopReceiver(string device, ushort key) {
            deviceId = WaveOutput.Select(device); voiceKey = new VoiceKeyLease(key, VoiceKey.Post, Thread.Sleep);
            watchdog = new System.Threading.Timer(CheckDeadline, null, 500, 500);
        }
        void CheckDeadline(object state) {
            if (!Monitor.TryEnter(sessionGate)) return;
            try {
                if (session != null && VoiceKeyLease.Expired(Stopwatch.GetTimestamp(), lastInput, Stopwatch.Frequency)) {
                    log.Write("phase=timeout completion=forced reason=input_idle");
                    CancelCore();
                    try { if (pipe != null) pipe.Dispose(); } catch { }
                } else if (session == null && voiceKey.Held && cleanupRetries > 0) {
                    cleanupRetries--;
                    voiceKey.Release();
                    if (!voiceKey.Held) log.Write("phase=cleanup result=key_released");
                    else if (cleanupRetries == 0) log.Write("phase=cleanup result=failed key_release=unknown");
                }
            } finally { Monitor.Exit(sessionGate); }
        }
        public void Run() {
            if (Interlocked.Exchange(ref running, 1) != 0) return;
            int failures = 0;
            string previousFailure = null;
            log.Write("connection=listening content_logged=false");
            try {
            while (!stopping) {
                PipeSecurity security = new PipeSecurity();
                SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                security.SetAccessRuleProtection(true, false);
                security.SetOwner(user);
                security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
                try {
                    using (NamedPipeServerStream stream = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1,
                        PipeTransmissionMode.Byte, PipeOptions.None, 65536, 65536, security)) {
                        pipe = stream; stream.WaitForConnection();
                        failures = 0; previousFailure = null;
                        Wire.Write(stream, new byte[] { 128, 1 });
                        byte[] frame;
                        while (!stopping && (frame = Wire.Read(stream)) != null) { lock (sessionGate) Handle(stream, frame); }
                    }
                } catch (Exception error) {
                    if (!stopping) {
                        string reason = FailureReason.Of(error);
                        Cancel();
                        if (previousFailure != reason) log.Write("connection=failed reason=" + reason + " content_logged=false");
                        previousFailure = reason;
                        failures++;
                        if (failures >= 5) { log.Write("connection=blocked retry_limit=5"); break; }
                        Thread.Sleep(250 * (1 << (failures - 1)));
                    }
                } finally { Cancel(); pipe = null; }
            }
            } finally { Interlocked.Exchange(ref running, 0); }
        }
        void Handle(Stream stream, byte[] frame) {
            if (frame.Length == 1 && frame[0] == 6 && session == null && !voiceKey.Held) {
                using (WaveOutput probe = new WaveOutput(deviceId)) {
                    probe.Append(new byte[32000], 16000); probe.Append(new byte[32000], 16000);
                    if (!probe.Drain() || probe.PlayedSamples != 32000) throw new IOException("audio_probe_failed");
                    Wire.Write(stream, (new byte[] { 134 }).Concat(BitConverter.GetBytes(probe.PlayedSamples)).ToArray());
                    log.Write("phase=audio_probe played_samples=32000 completion=normal voice_key_posted=false");
                }
                return;
            }
            if (frame.Length < 17) throw new InvalidDataException("session_missing");
            byte[] id = frame.Skip(1).Take(16).ToArray();
            byte kind = frame[0];
            lastInput = Stopwatch.GetTimestamp();
            if (kind == 1) {
                if (frame.Length != 17 || session != null || voiceKey.Held) throw new InvalidDataException("session_conflict");
                output = new WaveOutput(deviceId); session = id; received = 0;
                startedAt = Stopwatch.GetTimestamp();
                if (!voiceKey.Acquire()) throw new IOException("voice_key_failed");
                log.Write("phase=started target=virtual_audio external_voice_result=unknown");
                Wire.Write(stream, (new byte[] { 129 }).Concat(id).ToArray());
                return;
            }
            if (session == null || !session.SequenceEqual(id)) throw new InvalidDataException("session_mismatch");
            if (kind == 2) {
                byte[] pcm = frame.Skip(17).ToArray();
                if (received == 0) log.Write("phase=first_pcm target_start_to_receipt_ms=" + ((Stopwatch.GetTimestamp() - startedAt) * 1000 / Stopwatch.Frequency));
                output.Append(pcm, pcm.Length / 2); received += pcm.Length / 2;
            } else if (kind == 3 && frame.Length == 17) {
                bool success = output.Drain();
                long played = output.PlayedSamples;
                int interrupted = output.PendingSamples;
                bool released = voiceKey.Release();
                output.Dispose(); output = null; session = null;
                log.Write("phase=ended completion=" + (success && released ? "normal" : "forced") + " received_samples=" + received +
                    " played_samples=" + played + " interrupted_samples=" + interrupted + " external_voice_result=unknown");
                if (!success || !released) throw new IOException("drain_or_release_failed");
                Wire.Write(stream, (new byte[] { 130 }).Concat(id).Concat(BitConverter.GetBytes(played)).ToArray());
            } else if (kind == 4 && frame.Length == 17) {
                Cancel(); Wire.Write(stream, (new byte[] { 132 }).Concat(id).ToArray());
            } else { throw new InvalidDataException("unknown_operation"); }
        }
        void Cancel() {
            lock (sessionGate) { CancelCore(); }
        }
        void CancelCore() {
            int interrupted = output == null ? 0 : output.PendingSamples;
            if (voiceKey.Held) {
                voiceKey.Release();
                if (voiceKey.Held) { cleanupRetries = 3; log.Write("phase=cleanup result=retrying key_release=unknown"); }
            }
            if (output != null) { output.Dispose(); output = null; }
            if (session != null) log.Write("phase=ended completion=forced received_samples=" + received + " interrupted_samples=" + interrupted);
            session = null;
        }
        public bool HasUnreleasedKey { get { lock (sessionGate) return voiceKey.Held; } }
        public void Dispose() {
            stopping = true; try { if (pipe != null) pipe.Dispose(); } catch { } Cancel();
            if (!HasUnreleasedKey) watchdog.Dispose();
        }
    }

    static class Program {
        [DllImport("kernel32.dll")] static extern bool FreeConsole();
        [STAThread] static int Main(string[] args) {
            try {
                if (args.Contains("--list-devices")) {
                    string[] names = WaveOutput.Devices();
                    for (int i = 0; i < names.Length; i++) Console.WriteLine(i + "\t" + names[i]);
                    return 0;
                }
                if (args.Contains("--relay")) return Relay();
                if (args.Contains("--diagnose-audio")) {
                    using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", DesktopReceiver.PipeName, PipeDirection.InOut)) {
                        pipe.Connect(5000);
                        if (!Wire.Read(pipe).SequenceEqual(new byte[] { 128, 1 })) return 21;
                        Wire.Write(pipe, new byte[] { 6 });
                        byte[] result = Wire.Read(pipe);
                        if (result.Length != 9 || result[0] != 134 || BitConverter.ToInt64(result, 1) != 32000) return 22;
                        Console.WriteLine("PASS desktop receiver: same-user pipe, virtual output, 32000 silent samples and drain; no voice key posted");
                        return 0;
                    }
                }
                if (args.Contains("--self-test")) return SelfTest();
                if (args.Contains("--audio-self-test")) {
                    using (WaveOutput audio = new WaveOutput(WaveOutput.Select(Value(args, "--device", "CABLE Input")))) {
                        audio.Append(new byte[32000], 16000); audio.Append(new byte[32000], 16000);
                        if (!audio.Drain() || audio.PlayedSamples != 32000) return 17;
                        Console.WriteLine("PASS virtual output: 32000 silent PCM samples played and tail drained; no voice key posted");
                        return 0;
                    }
                }
                if (args.Contains("--stdio-self-test")) {
                    Console.WriteLine(Wire.EncodeLine(new byte[] { 128, 1 })); Console.Out.Flush();
                    string line = Wire.ReadLine(Console.In);
                    if (line == null) return 15;
                    Console.WriteLine(Wire.EncodeLine(Wire.DecodeLine(line))); Console.Out.Flush();
                    return 0;
                }
                if (!args.Contains("--desktop") || !Environment.UserInteractive || Process.GetCurrentProcess().SessionId == 0) return 2;
                string device = Value(args, "--device", "CABLE Input");
                ushort key = UInt16.Parse(Value(args, "--voice-key", "113"));
                if ((key < 112 || key > 123) && key != 164) throw new InvalidOperationException("voice_key_not_supported");
                bool owned;
                using (Mutex singleton = new Mutex(true, "Local\\SayAllRemoteVoiceDesktop", out owned)) {
                    if (!owned) return 3;
                    EventWaitHandleSecurity stopSecurity = new EventWaitHandleSecurity();
                    SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
                    stopSecurity.SetAccessRuleProtection(true, false);
                    stopSecurity.AddAccessRule(new EventWaitHandleAccessRule(sid, EventWaitHandleRights.FullControl, AccessControlType.Allow));
                    bool stopCreated;
                    using (EventWaitHandle stopSignal = new EventWaitHandle(false, EventResetMode.AutoReset,
                        "Global\\SayAllRemoteVoice.Stop." + sid.Value, out stopCreated, stopSecurity))
                    using (DesktopReceiver receiver = new DesktopReceiver(device, key))
                    using (NotifyIcon tray = new NotifyIcon { Icon = SystemIcons.Information, Text = "SayAll remote voice", Visible = true }) {
                        FreeConsole();
                        RegisteredWaitHandle stopWait = ThreadPool.RegisterWaitForSingleObject(stopSignal, delegate {
                            receiver.Dispose();
                            for (int i = 0; i < 40 && receiver.HasUnreleasedKey; i++) Thread.Sleep(50);
                            if (!receiver.HasUnreleasedKey) Application.Exit();
                        }, null, Timeout.Infinite, true);
                        ContextMenuStrip menu = new ContextMenuStrip();
                        menu.Items.Add("Retry connection", null, delegate { Task.Run(delegate { receiver.Run(); }); });
                        menu.Items.Add("Exit", null, delegate {
                            receiver.Dispose();
                            if (receiver.HasUnreleasedKey) { MessageBox.Show("The voice key could not be released. Return to the normal desktop and retry Exit.", "SayAll"); return; }
                            Application.ExitThread();
                        });
                        tray.ContextMenuStrip = menu;
                        Task.Run(delegate { receiver.Run(); });
                        Application.Run();
                        stopWait.Unregister(null);
                        receiver.Dispose(); tray.Visible = false;
                    }
                    singleton.ReleaseMutex(); return 0;
                }
            } catch (Exception error) {
                Console.Error.WriteLine("SayAll receiver failed: " + FailureReason.Of(error));
                return 1;
            }
        }
        static string Value(string[] args, string key, string fallback) {
            int index = Array.IndexOf(args, key); return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback;
        }
        static int Relay() {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", DesktopReceiver.PipeName, PipeDirection.InOut)) {
                pipe.Connect(5000);
                Task input = Task.Run(delegate {
                    string line;
                    while ((line = Wire.ReadLine(Console.In)) != null) Wire.Write(pipe, Wire.DecodeLine(line));
                    pipe.Dispose();
                });
                Task output = Task.Run(delegate {
                    byte[] frame;
                    while ((frame = Wire.Read(pipe)) != null) { Console.Out.WriteLine(Wire.EncodeLine(frame)); Console.Out.Flush(); }
                });
                Task.WaitAny(input, output);
                return 0;
            }
        }
        static int SelfTest() {
            byte[] data = new byte[] { 2, 0, 10, 13, 255, 128 };
            if (!Wire.DecodeLine(Wire.EncodeLine(data)).SequenceEqual(data)) return 10;
            using (MemoryStream invalid = new MemoryStream(BitConverter.GetBytes((uint)(Wire.Maximum + 1)))) {
                try { Wire.Read(invalid); return 11; } catch (InvalidDataException) { }
            }
            using (MemoryStream partial = new MemoryStream(new byte[] { 2, 0, 0, 0, 1 })) {
                try { Wire.Read(partial); return 12; } catch (EndOfStreamException) { }
            }
            try { Wire.DecodeLine(Wire.EncodeLine(data) + Wire.EncodeLine(data)); return 13; } catch { }
            try { Wire.ReadLine(new StringReader(new string('A', 90001))); return 14; } catch (InvalidDataException) { }
            bool allowRelease = false; int keyCalls = 0;
            VoiceKeyLease lease = new VoiceKeyLease(113, delegate(ushort key, bool down) { keyCalls++; return down || allowRelease; }, delegate(int ms) { });
            if (!lease.Acquire() || lease.Release() || !lease.Held || keyCalls != 4) return 18;
            allowRelease = true;
            if (!lease.Release() || lease.Held) return 19;
            if (VoiceKeyLease.Expired(2999, 0, 1000) || !VoiceKeyLease.Expired(3000, 0, 1000) || VoiceKeyLease.Expired(4000, 2000, 1000)) return 20;
            Console.WriteLine("PASS framing, binary-safe relay, input bounds, release ownership/recovery and idle deadline; no audio or keyboard posted");
            return 0;
        }
    }
}
