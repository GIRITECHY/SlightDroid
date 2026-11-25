// SlightDroid launcher: minimal ADB client over TCP (no adb.exe, no adb server process).
// Speaks the ADB transport protocol directly to the guest's adbd (forwarded by QEMU to
// 127.0.0.1:<port> only). The Lite guest is a userdebug build without adb auth.
// C# 5 / .NET Framework 4.x.
using System;
using System.IO;
using System.Net.Sockets;
using System.Text;

namespace SlightDroid {
    public sealed class AdbException : Exception { public AdbException(string m) : base(m) { } }

    public sealed class Adb : IDisposable {
        const uint A_CNXN = 0x4e584e43, A_OPEN = 0x4e45504f, A_OKAY = 0x59414b4f,
                   A_CLSE = 0x45534c43, A_WRTE = 0x45545257, A_AUTH = 0x48545541;
        const uint VERSION = 0x01000000;
        const uint MAXDATA = 256 * 1024;

        readonly TcpClient tcp;
        readonly NetworkStream s;
        uint maxData = 4096;
        uint nextLocalId = 1;

        Adb(TcpClient c) { tcp = c; s = c.GetStream(); }

        public static Adb Connect(int port, int timeoutMs) {
            var c = new TcpClient();
            var ar = c.BeginConnect("127.0.0.1", port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { c.Close(); throw new AdbException("connect timeout"); }
            c.EndConnect(ar);
            c.ReceiveTimeout = timeoutMs; c.SendTimeout = timeoutMs; c.NoDelay = true;
            var a = new Adb(c);
            try { a.Handshake(); } catch { a.Dispose(); throw; }
            return a;
        }

        void Handshake() {
            Send(A_CNXN, VERSION, MAXDATA, Encoding.ASCII.GetBytes("host::SlightDroid\0"));
            Msg m = Recv();
            if (m.Cmd == A_AUTH) throw new AdbException("guest asks for adb authentication");
            if (m.Cmd != A_CNXN) throw new AdbException("unexpected reply to CNXN");
            maxData = Math.Min(m.Arg1, MAXDATA);
        }

        struct Msg { public uint Cmd, Arg0, Arg1; public byte[] Data; }

        void Send(uint cmd, uint a0, uint a1, byte[] data) { Send(cmd, a0, a1, data, data == null ? 0 : data.Length); }

        void Send(uint cmd, uint a0, uint a1, byte[] data, int len) {
            var h = new byte[24];
            uint sum = 0;
            for (int i = 0; i < len; i++) sum += data[i];
            Put(h, 0, cmd); Put(h, 4, a0); Put(h, 8, a1); Put(h, 12, (uint)len); Put(h, 16, sum); Put(h, 20, cmd ^ 0xffffffff);
            s.Write(h, 0, 24);
            if (len > 0) s.Write(data, 0, len);
        }

        Msg Recv() {
            var h = ReadExact(24);
            var m = new Msg { Cmd = Get(h, 0), Arg0 = Get(h, 4), Arg1 = Get(h, 8) };
            uint len = Get(h, 12);
            if (Get(h, 20) != (m.Cmd ^ 0xffffffff)) throw new AdbException("bad adb packet");
            m.Data = len > 0 ? ReadExact((int)len) : new byte[0];
            return m;
        }

        // Next message addressed to our stream 'local'. adbd can still send a late CLSE (or a
        // stray OKAY) for an earlier stream on the same connection; those are skipped.
        Msg RecvFor(uint local) {
            while (true) {
                Msg m = Recv();
                if (m.Arg1 == local) return m;
            }
        }

        byte[] ReadExact(int n) {
            var b = new byte[n]; int o = 0;
            while (o < n) { int r = s.Read(b, o, n - o); if (r <= 0) throw new AdbException("connection closed"); o += r; }
            return b;
        }

        static void Put(byte[] b, int o, uint v) { b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); b[o + 2] = (byte)(v >> 16); b[o + 3] = (byte)(v >> 24); }
        static uint Get(byte[] b, int o) { return (uint)(b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24); }

        // Opens a stream to a service, optionally sends 'input' (streamed from a file), returns all output.
        public string Run(string service, Stream input, Action<long> progress) {
            uint local = nextLocalId++;
            Send(A_OPEN, local, 0, Encoding.UTF8.GetBytes(service + "\0"));
            Msg m = RecvFor(local);
            if (m.Cmd == A_CLSE) throw new AdbException("service refused: " + service);
            if (m.Cmd != A_OKAY) throw new AdbException("unexpected reply to OPEN");
            uint remote = m.Arg0;
            var output = new StringBuilder();

            if (input != null) {
                var buf = new byte[maxData];
                long sent = 0; int n;
                while ((n = input.Read(buf, 0, buf.Length)) > 0) {
                    Send(A_WRTE, local, remote, buf, n);
                    sent += n;
                    // wait for the OKAY for this chunk; collect any output that arrives meanwhile
                    while (true) {
                        m = RecvFor(local);
                        if (m.Cmd == A_OKAY) break;
                        if (m.Cmd == A_WRTE) { output.Append(Encoding.UTF8.GetString(m.Data)); Send(A_OKAY, local, remote, null); continue; }
                        if (m.Cmd == A_CLSE) return output.ToString();
                    }
                    if (progress != null) progress(sent);
                }
            }
            while (true) {
                m = RecvFor(local);
                if (m.Cmd == A_WRTE) { output.Append(Encoding.UTF8.GetString(m.Data)); Send(A_OKAY, local, remote, null); }
                else if (m.Cmd == A_CLSE) { Send(A_CLSE, local, remote, null); break; }
            }
            return output.ToString();
        }

        public string Shell(string cmd) { return Run("shell:" + cmd, null, null).Trim(); }

        // Streams the APK into "cmd package install -S <size>" (Android 7+); no temp file in the guest.
        public string InstallApk(string path, Action<long, long> progress) {
            using (var f = File.OpenRead(path)) {
                long total = f.Length;
                return Run("exec:cmd package install -r -S " + total, f,
                    sent => { if (progress != null) progress(sent, total); }).Trim();
            }
        }

        public void Dispose() { try { tcp.Close(); } catch { } }

        // Quotes a string for the Android shell.
        public static string Sh(string s) { return "'" + s.Replace("'", "'\\''") + "'"; }

        // ---------- byte streams (used by the file-sync protocol) ----------
        public AdbStream Open(string service) {
            uint local = nextLocalId++;
            Send(A_OPEN, local, 0, Encoding.UTF8.GetBytes(service + "\0"));
            Msg m = RecvFor(local);
            if (m.Cmd != A_OKAY) throw new AdbException("service refused: " + service);
            return new AdbStream(this, local, m.Arg0);
        }

        public sealed class AdbStream : IDisposable {
            readonly Adb a; readonly uint local, remote;
            byte[] pending = new byte[0]; int pendingOff;
            bool closed;

            internal AdbStream(Adb a, uint local, uint remote) { this.a = a; this.local = local; this.remote = remote; }

            public void Write(byte[] b, int off, int len) {
                while (len > 0) {
                    int n = (int)Math.Min(len, a.maxData);
                    var chunk = new byte[n]; Buffer.BlockCopy(b, off, chunk, 0, n);
                    a.Send(A_WRTE, local, remote, chunk, n);
                    while (true) {                       // wait for OKAY; buffer anything the device sends meanwhile
                        Msg m = a.RecvFor(local);
                        if (m.Cmd == A_OKAY) break;
                        if (m.Cmd == A_WRTE) { Append(m.Data); a.Send(A_OKAY, local, remote, null); continue; }
                        if (m.Cmd == A_CLSE) { closed = true; throw new AdbException("stream closed by device"); }
                    }
                    off += n; len -= n;
                }
            }

            void Append(byte[] d) {
                var rest = pending.Length - pendingOff;
                var nb = new byte[rest + d.Length];
                Buffer.BlockCopy(pending, pendingOff, nb, 0, rest); Buffer.BlockCopy(d, 0, nb, rest, d.Length);
                pending = nb; pendingOff = 0;
            }

            public byte[] ReadExact(int n) {
                var r = new byte[n]; int got = 0;
                while (got < n) {
                    if (pendingOff < pending.Length) {
                        int k = Math.Min(n - got, pending.Length - pendingOff);
                        Buffer.BlockCopy(pending, pendingOff, r, got, k); pendingOff += k; got += k; continue;
                    }
                    if (closed) throw new AdbException("stream closed by device");
                    Msg m = a.RecvFor(local);
                    if (m.Cmd == A_WRTE) { Append(m.Data); a.Send(A_OKAY, local, remote, null); }
                    else if (m.Cmd == A_CLSE) closed = true;
                }
                return r;
            }

            public void Dispose() { if (!closed) { try { a.Send(A_CLSE, local, remote, null); } catch { } } }
        }
    }

    // ADB file-sync protocol ("sync:" service): list, push, pull. Files stream in 64 KB pieces.
    public sealed class AdbSync : IDisposable {
        public struct Entry { public string Name; public bool IsDir; public long Size; public DateTime Modified; }

        readonly Adb.AdbStream s;
        public AdbSync(Adb adb) { s = adb.Open("sync:"); }

        static byte[] Req(string id, byte[] body) {
            var b = new byte[8 + body.Length];
            Encoding.ASCII.GetBytes(id, 0, 4, b, 0);
            BitConverter.GetBytes(body.Length).CopyTo(b, 4);
            body.CopyTo(b, 8);
            return b;
        }
        void Send(string id, byte[] body) { var b = Req(id, body); s.Write(b, 0, b.Length); }
        void Send(string id, string body) { Send(id, Encoding.UTF8.GetBytes(body)); }
        string Id(byte[] h) { return Encoding.ASCII.GetString(h, 0, 4); }
        static int I32(byte[] b, int o) { return BitConverter.ToInt32(b, o); }
        static DateTime Unix(int t) { return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds((uint)t).ToLocalTime(); }

        string Fail(byte[] h) { return Encoding.UTF8.GetString(s.ReadExact(I32(h, 4))); }

        public System.Collections.Generic.List<Entry> List(string dir) {
            var list = new System.Collections.Generic.List<Entry>();
            Send("LIST", dir);
            while (true) {
                var h = s.ReadExact(4);
                string id = Id(h);
                if (id == "DONE") { s.ReadExact(16); break; }
                if (id != "DENT") throw new AdbException("bad LIST reply " + id);
                var f = s.ReadExact(16);
                int mode = I32(f, 0), size = I32(f, 4), time = I32(f, 8), nameLen = I32(f, 12);
                string name = Encoding.UTF8.GetString(s.ReadExact(nameLen));
                if (name == "." || name == "..") continue;
                list.Add(new Entry { Name = name, IsDir = (mode & 0xF000) == 0x4000 || (mode & 0xF000) == 0xA000,
                                     Size = (uint)size, Modified = Unix(time) });
            }
            return list;
        }

        public void Push(string localPath, string remotePath, Action<long, long> progress) {
            using (var f = File.OpenRead(localPath)) {
                Send("SEND", remotePath + ",33188");          // 0100644
                var buf = new byte[64 * 1024]; long sent = 0; int n;
                while ((n = f.Read(buf, 0, buf.Length)) > 0) {
                    var body = new byte[n]; Buffer.BlockCopy(buf, 0, body, 0, n);
                    Send("DATA", body);
                    sent += n; if (progress != null) progress(sent, f.Length);
                }
                var done = Req("DONE", new byte[0]);
                BitConverter.GetBytes((int)(File.GetLastWriteTimeUtc(localPath) - new DateTime(1970, 1, 1)).TotalSeconds).CopyTo(done, 4);
                s.Write(done, 0, 8);
                var h = s.ReadExact(8);
                if (Id(h) == "FAIL") throw new AdbException(Fail(h));
                if (Id(h) != "OKAY") throw new AdbException("bad SEND reply " + Id(h));
            }
        }

        public void Pull(string remotePath, string localPath, long size, Action<long, long> progress) {
            Send("RECV", remotePath);
            string tmp = localPath + ".part";
            try {
                using (var f = File.Create(tmp)) {
                    long got = 0;
                    while (true) {
                        var h = s.ReadExact(8);
                        string id = Id(h);
                        if (id == "DONE") break;
                        if (id == "FAIL") throw new AdbException(Fail(h));
                        if (id != "DATA") throw new AdbException("bad RECV reply " + id);
                        var d = s.ReadExact(I32(h, 4));
                        f.Write(d, 0, d.Length);
                        got += d.Length; if (progress != null) progress(got, size);
                    }
                }
                if (File.Exists(localPath)) File.Delete(localPath);
                File.Move(tmp, localPath);
            } catch { try { File.Delete(tmp); } catch { } throw; }
        }

        public void Dispose() { try { Send("QUIT", new byte[0]); } catch { } s.Dispose(); }
    }
}
