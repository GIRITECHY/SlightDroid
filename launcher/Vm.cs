// SlightDroid launcher: VM lifecycle. Keep the QEMU arguments in sync with tools/build/run-lite.ps1.
// C# 5 / .NET Framework 4.x.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace SlightDroid {
    public sealed class VmState {
        public int Pid, AdbPort, QmpPort, EvPort;   // EvPort: second QMP socket the launcher listens on for events
        public DateTime Started;

        public static VmState Read(string path) {
            try {
                var d = File.ReadAllLines(path).Where(l => l.Contains("=")).ToDictionary(l => l.Split('=')[0], l => l.Substring(l.IndexOf('=') + 1));
                return new VmState {
                    Pid = int.Parse(d["pid"]), AdbPort = int.Parse(d["adb"]), QmpPort = int.Parse(d["qmp"]),
                    EvPort = d.ContainsKey("ev") ? int.Parse(d["ev"]) : 0,
                    Started = DateTime.Parse(d["started"], null, System.Globalization.DateTimeStyles.RoundtripKind) };
            } catch { return null; }
        }

        public void Write(string path) {
            File.WriteAllText(path, "pid=" + Pid + "\nadb=" + AdbPort + "\nqmp=" + QmpPort + "\nev=" + EvPort + "\nstarted=" + Started.ToString("o") + "\n");
        }
    }

    public sealed class Vm {
        public readonly string InstallDir, DataDir, LogDir, SettingsPath;
        public Config Cfg;
        readonly string statePath;

        public Vm() {
            InstallDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            // SLIGHTDROID_DATA overrides the data folder (used for portable test runs on the dev PC)
            DataDir = Environment.GetEnvironmentVariable("SLIGHTDROID_DATA");
            if (string.IsNullOrEmpty(DataDir))
                DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SlightDroid");
            Directory.CreateDirectory(DataDir);
            LogDir = Path.Combine(DataDir, "logs");
            Directory.CreateDirectory(LogDir);
            SettingsPath = Path.Combine(DataDir, "settings.ini");
            Cfg = Config.Load(SettingsPath);
            statePath = Path.Combine(DataDir, "vm.state");
        }

        // single-instance lock suffix: empty for the normal data folder, unique for a SLIGHTDROID_DATA test folder
        public string InstanceTag { get { return string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SLIGHTDROID_DATA")) ? "" : "." + (DataDir.ToLowerInvariant().GetHashCode() & 0x7fffffff); } }

        // Engine: Google's Android Emulator (Apache 2.0) + Android 11 x86_64 system image, laid out like an SDK:
        //   <install>\sdk\emulator\emulator.exe, \sdk\platform-tools\adb.exe, \sdk\system-images\android-30\default\x86_64
        // Per-user state (virtual device, quick-boot snapshot, data partition) lives in <data>\avd\SlightDroid.avd.
        public const string AvdName = "SlightDroid";
        string Sdk { get { return Path.Combine(InstallDir, "sdk"); } }
        string EmulatorExe { get { return Path.Combine(Sdk, "emulator", "emulator.exe"); } }
        public string AvdDir { get { return Path.Combine(DataDir, "avd", AvdName + ".avd"); } }
        public string DataDisk { get { return Path.Combine(AvdDir, "userdata-qemu.img"); } }

        public void Log(string msg) {
            try { File.AppendAllText(Path.Combine(LogDir, "launcher.log"), DateTime.Now.ToString("s") + " " + msg + "\r\n"); } catch { }
        }

        // ---------- state ----------
        public VmState Running() {
            var st = VmState.Read(statePath);
            if (st == null) return null;
            try {
                var p = Process.GetProcessById(st.Pid);
                if (p.HasExited || !p.ProcessName.StartsWith("qemu-system", StringComparison.OrdinalIgnoreCase)) return null;
                return st;
            } catch { return null; }
        }

        // ---------- accelerator check (same API path the engine uses) ----------
        [DllImport("WinHvPlatform.dll")] static extern int WHvGetCapability(int code, out ulong buf, uint size, out uint written);

        public static bool WhpxAvailable() {
            try { ulong v; uint w; return WHvGetCapability(0, out v, 8, out w) == 0 && (v & 1) == 1; }
            catch { return false; }   // DLL missing: feature not enabled
        }

        static bool PortFree(int port) {
            try { var l = new TcpListener(IPAddress.Loopback, port); l.Start(); l.Stop(); return true; } catch { return false; }
        }

        // The engine takes an even console port P in 5554..5682 and uses P+1 for ADB.
        static int FreeConsolePort() {
            for (int p = 5554; p <= 5682; p += 2) if (PortFree(p) && PortFree(p + 1)) return p;
            throw new Exception("No free local port for the Android engine (5554-5683 are all in use).");
        }

        static string Q(string path) { return "\"" + path + "\""; }

        // Size of the Android data partition (sparse file: only used space takes disk space).
        public long DataDiskVirtualBytes() {
            try { return File.Exists(DataDisk) ? new FileInfo(DataDisk).Length : 0; } catch { return 0; }
        }

        // Writes the virtual device from the current settings (every start, so Settings changes apply).
        void WriteAvd() {
            Directory.CreateDirectory(AvdDir);
            Directory.CreateDirectory(Path.Combine(DataDir, "home"));
            File.WriteAllText(Path.Combine(DataDir, "avd", AvdName + ".ini"),
                "avd.ini.encoding=UTF-8\r\npath=" + AvdDir + "\r\ntarget=android-30\r\n");
            Size res = Cfg.EffectiveResolution();
            var c = new StringBuilder();
            c.Append("avd.ini.encoding=UTF-8\r\nAvdId=" + AvdName + "\r\navd.ini.displayname=SlightDroid\r\n");
            c.Append("PlayStore.enabled=false\r\nabi.type=x86_64\r\nhw.cpu.arch=x86_64\r\ntag.id=default\r\n");
            c.Append("image.sysdir.1=system-images\\android-30\\default\\x86_64\\\r\n");
            c.Append("hw.cpu.ncore=" + Cfg.EffectiveCpus() + "\r\nhw.ramSize=" + Cfg.EffectiveRamMB() + "\r\n");
            c.Append("vm.heapSize=" + (Cfg.EffectiveRamMB() >= 2048 ? 512 : 256) + "\r\n");
            c.Append("hw.lcd.width=" + res.Width + "\r\nhw.lcd.height=" + res.Height + "\r\nhw.lcd.density=" + Cfg.EffectiveDpi() + "\r\n");
            c.Append("hw.initialOrientation=" + (res.Width >= res.Height ? "landscape" : "portrait") + "\r\n");
            c.Append("hw.keyboard=yes\r\nhw.mainKeys=no\r\nhw.dPad=no\r\nhw.trackBall=no\r\nhw.camera.back=none\r\nhw.camera.front=none\r\n");
            c.Append("hw.gps=yes\r\nhw.audioInput=no\r\nhw.audioOutput=yes\r\nhw.sensors.proximity=no\r\n");
            c.Append("hw.gpu.enabled=yes\r\nhw.gpu.mode=" + EngineGpuMode() + "\r\n");
            c.Append("disk.dataPartition.size=" + Cfg.StorageGB + "G\r\n");
            c.Append("fastboot.forceColdBoot=no\r\nfastboot.forceFastBoot=yes\r\nshowDeviceFrame=no\r\nskin.dynamic=yes\r\n");
            File.WriteAllText(Path.Combine(AvdDir, "config.ini"), c.ToString());
            WriteWindowPlacement(res);
        }

        // The engine window is sized in Windows "logical" pixels (display scaling), Android's screen in real
        // pixels: without a scale the window can be larger than the screen. Placement is written when the
        // Android resolution changes (or the first time); afterwards the engine remembers the user's own resize.
        [DllImport("user32.dll")] static extern uint GetDpiForSystem();
        void WriteWindowPlacement(Size res) {
            string ini = Path.Combine(AvdDir, "emulator-user.ini"), mark = Path.Combine(AvdDir, "slightdroid-window.txt");
            string key = res.Width + "x" + res.Height + "@" + System.Windows.Forms.Screen.PrimaryScreen.WorkingArea.Size + "/" + Cfg.Window;
            if (File.Exists(ini) && File.Exists(mark) && File.ReadAllText(mark).Trim() == key) return;
            double k = 1.0; try { k = GetDpiForSystem() / 96.0; } catch { }
            Rectangle wa = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;            // real pixels (the launcher is DPI-aware)
            double toolbar = 70 * k, title = 40 * k;                    // engine side toolbar + title bar
            double scale = Math.Min((wa.Width * 0.94 - toolbar) / res.Width, (wa.Height * 0.94 - title) / res.Height);
            // fit: as large as the screen allows (up to 1.5x); actual: 1 Android pixel = 1 screen pixel (shrunk only if it does not fit)
            scale = Math.Max(0.25, Math.Min(Cfg.Window == "actual" ? 1.0 : 1.5, scale));
            scale /= k;                                                  // engine scale is in logical pixels
            int w = (int)(res.Width * scale * k + toolbar), h = (int)(res.Height * scale * k + title);
            int x = (int)((wa.X + (wa.Width - w) / 2) / k), y = (int)((wa.Y + (wa.Height - h) / 2) / k);
            File.WriteAllText(ini, "window.x = " + Math.Max(0, x) + "\r\nwindow.y = " + Math.Max(0, y) + "\r\n" +
                "window.scale = " + scale.ToString("0.000000", System.Globalization.CultureInfo.InvariantCulture) + "\r\n" +
                "resizable.config.id = -1\r\nposture = 0\r\n");
            File.WriteAllText(mark, key);
            Log("window placement: scale " + Config.Inv(scale * 100) + " % (display scaling " + Config.Inv(k * 100) + " %)");
        }

        void EngineEnv(ProcessStartInfo psi) {
            psi.EnvironmentVariables["ANDROID_SDK_ROOT"] = Sdk;
            psi.EnvironmentVariables["ANDROID_HOME"] = Sdk;
            psi.EnvironmentVariables["ANDROID_AVD_HOME"] = Path.Combine(DataDir, "avd");
            psi.EnvironmentVariables["ANDROID_EMULATOR_HOME"] = Path.Combine(DataDir, "home");
        }

        // ---------- start ----------
        public VmState Start() {
            WriteAvd();
            int port = FreeConsolePort();
            var a = new List<string> {
                "-avd", AvdName, "-port", port.ToString(),
                "-no-metrics",                 // no usage statistics to Google
                "-no-boot-anim", "-gpu", EngineGpuMode(),
                // GLES only (lighter; Vulkan drivers are the less tested path on old PCs), and no per-command checksum on the
                // graphics pipe: with it, WebView video (e.g. NetMirror) held ~8 % of frames 58+ ms; without, 0.4 % (2026-11-19)
                "-feature", "-Vulkan,-GLPipeChecksum",
            };
            string extra = Environment.GetEnvironmentVariable("SLIGHTDROID_ENGINE_ARGS");   // dev experiments
            if (!string.IsNullOrEmpty(extra)) a.AddRange(extra.Split(' '));
            var psi = new ProcessStartInfo(EmulatorExe, string.Join(" ", a)) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(EmulatorExe),
                RedirectStandardError = true, RedirectStandardOutput = true,
            };
            EngineEnv(psi);
            Log("start: " + psi.FileName + " " + psi.Arguments + "  (ram " + Cfg.EffectiveRamMB() + " MB, " + Cfg.EffectiveCpus() + " cpus, " + Config.Describe(Cfg.EffectiveResolution()) + " @" + Cfg.EffectiveDpi() + " dpi)");
            var p = Process.Start(psi);
            var err = new StringBuilder();
            string elog = Path.Combine(LogDir, "engine.log");
            DataReceivedEventHandler h = (s, e) => {
                if (e.Data == null) return;
                if (e.Data.Contains("ERROR") || e.Data.Contains("FATAL") || e.Data.Contains("PANIC")) lock (err) err.AppendLine(e.Data);
                try { File.AppendAllText(elog, e.Data + "\r\n"); } catch { }
            };
            p.ErrorDataReceived += h; p.OutputDataReceived += h;
            p.BeginErrorReadLine(); p.BeginOutputReadLine();
            // emulator.exe starts the real engine (qemu-system-x86_64.exe) as a child process; that one owns the window
            int engine = 0;
            for (int i = 0; i < 120 && engine == 0; i++) {
                if (p.HasExited) {
                    string msg; lock (err) msg = err.ToString().Trim();
                    throw new Exception("The Android engine stopped right away.\n\n" + (msg.Length > 0 ? msg : "exit code " + p.ExitCode) + "\n\nSee " + elog);
                }
                engine = ChildEngine(p.Id);
                if (engine == 0) Thread.Sleep(250);
            }
            if (engine == 0) throw new Exception("The Android engine did not start. See " + elog);
            var st = new VmState { Pid = engine, AdbPort = port + 1, QmpPort = port, Started = DateTime.Now };
            st.Write(statePath);
            return st;
        }

        static int ChildEngine(int parent) {
            try {
                using (var q = new System.Management.ManagementObjectSearcher(
                    "SELECT ProcessId FROM Win32_Process WHERE ParentProcessId=" + parent + " AND Name LIKE 'qemu-system%'"))
                    foreach (System.Management.ManagementObject o in q.Get()) return Convert.ToInt32(o["ProcessId"]);
            } catch { }
            return 0;
        }

        // ---------- WebView ----------
        // Android 11's own WebView (83, 2020) plays in-app video (NetMirror and other web-based players) with
        // twice the CPU; SlightDroid ships Bromite's WebView 108 (open source), renamed to com.android.webview and
        // signed with the image's AOSP test key so it installs as a normal update (tools/build/rename-webview.py).
        public const long WebViewVersionCode = 1671415670;
        public string WebViewApk { get { return Path.Combine(InstallDir, "apps", "webview.apk"); } }

        public void EnsureWebView(Adb adb, Action<string> status) {
            if (!File.Exists(WebViewApk)) return;
            var m = Regex.Match(adb.Shell("dumpsys package com.android.webview | grep -m1 versionCode"), @"versionCode=(\d+)");
            long have = m.Success ? long.Parse(m.Groups[1].Value) : 0;
            if (have >= WebViewVersionCode) return;
            status("Updating Android's web engine (one time)...");
            string r = adb.InstallApk(WebViewApk, (sent, total) => status(string.Format("Updating Android's web engine (one time)... {0}%", sent * 100 / Math.Max(1, total))));
            Log("webview update " + have + " -> " + WebViewVersionCode + ": " + (r ?? "").Trim());
        }

        // ---------- readiness ----------
        public bool WaitReady(VmState st, TimeSpan timeout, Action<string> status) {
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed < timeout) {
                if (Running() == null) throw new Exception("The emulator window was closed or the engine stopped.");
                try {
                    using (var adb = Adb.Connect(st.AdbPort, 3000)) {
                        if (adb.Shell("getprop debug.slightdroid.ready") == "1") return true;
                        status("Starting Android... (" + (int)sw.Elapsed.TotalSeconds + " s)");
                    }
                } catch (Exception) {
                    status("Booting... (" + (int)sw.Elapsed.TotalSeconds + " s)");
                }
                Thread.Sleep(1000);
            }
            return false;
        }

        // ---------- QMP ----------
        public static void Qmp(int port, params string[] commands) {
            using (var c = new TcpClient("127.0.0.1", port)) {
                c.ReceiveTimeout = 10000;
                var s = c.GetStream(); var r = new StreamReader(s); var w = new StreamWriter(s) { AutoFlush = true };
                r.ReadLine();
                w.WriteLine("{\"execute\":\"qmp_capabilities\"}"); ReadReturn(r);
                foreach (var cmd in commands) { w.WriteLine(cmd); ReadReturn(r); }
            }
        }

        static void ReadReturn(StreamReader r) {
            string line;
            while ((line = r.ReadLine()) != null) if (line.Contains("\"return\"") || line.Contains("\"error\"")) return;
        }

        // ---------- stop: ask the engine to quit (it saves the quick-boot snapshot, so the next start resumes) ----------
        public void Stop(VmState st, int graceMs) {
            try { Console(st.QmpPort, "kill"); } catch (Exception e) { Log("stop: console: " + e.Message); }
            WaitOrKill(st, graceMs, "stop");
        }

        // Engine console (telnet-style, localhost only); needs the token the engine writes for this user.
        public string Console(int port, string command) {
            string token = "";
            foreach (var t in new[] { Path.Combine(DataDir, "home", ".emulator_console_auth_token"),
                                      Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".emulator_console_auth_token") })
                if (File.Exists(t)) { token = File.ReadAllText(t).Trim(); break; }
            using (var c = new TcpClient("127.0.0.1", port)) {
                c.ReceiveTimeout = 10000;
                var s = c.GetStream(); var w = new StreamWriter(s) { AutoFlush = true, NewLine = "\r\n" };
                var buf = new byte[8192]; var sb = new StringBuilder();
                Func<string> readOk = () => {
                    var sw = Stopwatch.StartNew();
                    while (sw.ElapsedMilliseconds < 10000) {
                        int n = s.Read(buf, 0, buf.Length); if (n <= 0) break;
                        sb.Append(Encoding.ASCII.GetString(buf, 0, n));
                        string t = sb.ToString(); if (t.Contains("OK\r\n") || t.Contains("KO")) break;
                    }
                    string r = sb.ToString(); sb.Clear(); return r;
                };
                readOk();
                if (token.Length > 0) { w.WriteLine("auth " + token); readOk(); }
                w.WriteLine(command);
                try { return readOk(); } catch { return ""; }   // "kill" closes the connection
            }
        }
        // ---------- GPU hang fallback ----------
        // On some hosts (seen on a hybrid NVIDIA/AMD laptop) GPU acceleration (virgl through ANGLE) hangs
        // Android's UI shortly after boot: SystemUI and the home screen block in hwui waiting for their GPU
        // render thread and Android reports them "Not Responding". Compatibility graphics works there, so
        // SlightDroid detects the hang, remembers compatibility graphics for this PC (gpu-fallback.txt) and
        // restarts. Choosing "GPU accelerated" again in Settings clears it.
        string GpuFallbackPath { get { return Path.Combine(DataDir, "gpu-fallback.txt"); } }
        public bool GpuFellBack { get { return File.Exists(GpuFallbackPath); } }
        public DateTime GpuFallbackTime { get { return GpuFellBack ? File.GetLastWriteTime(GpuFallbackPath) : DateTime.MinValue; } }
        public string EffectiveGpu() { return Cfg.Gpu == "std" || GpuFellBack || !Config.HasHardwareGpu() ? "std" : "virgl"; }
        // engine names: GPU accelerated = host GPU (OpenGL ES translated on the PC's GPU); compatibility = software renderer
        public string EngineGpuMode() { string o = Environment.GetEnvironmentVariable("SLIGHTDROID_GPUMODE"); if (!string.IsNullOrEmpty(o)) return o;   // dev experiments
            return EffectiveGpu() == "std" ? "swiftshader_indirect" : "host"; }
        public void ClearGpuFallback() { try { File.Delete(GpuFallbackPath); } catch { } }

        // Watches a GPU-accelerated session for that hang during 'window'. True = hang found (and remembered).
        public bool WatchForGpuHang(VmState st, TimeSpan window) {
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed < window) {
                Thread.Sleep(5000);
                if (Running() == null) return false;
                try {
                    using (var adb = Adb.Connect(st.AdbPort, 10000)) {
                        string focus = adb.Shell("dumpsys window | grep -m1 mCurrentFocus");
                        if (!focus.Contains("Not Responding") || !(focus.Contains("com.android.systemui") || focus.Contains("launcher3"))) continue;
                        // confirm from the ANR traces that the UI thread waits on its GPU render thread
                        string trace = adb.Shell("su root sh -c 'grep -l DrawFrameTask::postAndWait /data/anr/* 2>/dev/null | head -1; echo rc=$?'");
                        bool rootOk = trace.Contains("rc=");
                        if (rootOk && !trace.Contains("/data/anr/")) continue;   // a different kind of ANR: not ours to handle
                        string why = DateTime.Now.ToString("s") + " GPU render hang: " + focus.Trim() + (rootOk ? " (trace: " + trace.Split('\n')[0].Trim() + ")" : "");
                        File.WriteAllText(GpuFallbackPath, why + "\r\n");
                        Log("switching to compatibility graphics: " + why);
                        return true;
                    }
                } catch (Exception) { }
            }
            return false;
        }

        public void WaitOrKill(VmState st, int graceMs, string what) {
            try {
                var p = Process.GetProcessById(st.Pid);
                if (p.WaitForExit(graceMs)) Log(what + ": synced and quit");
                else { p.Kill(); Log(what + ": forced after " + graceMs + " ms"); }
            } catch { }
        }

        // ---------- metrics (written for the diagnostics zip) ----------
        public void RecordMetrics(VmState st, double bootSec) {
            try {
                var p = Process.GetProcessById(st.Pid);
                Thread.Sleep(30000);                                   // let it settle
                p.Refresh(); var cpu0 = p.TotalProcessorTime; var t0 = DateTime.Now;
                Thread.Sleep(20000);
                p.Refresh();
                double idlePct = 100.0 * (p.TotalProcessorTime - cpu0).TotalSeconds / (DateTime.Now - t0).TotalSeconds / Environment.ProcessorCount;
                string meminfo = "", df = "";
                using (var adb = Adb.Connect(st.AdbPort, 5000)) { meminfo = adb.Shell("head -3 /proc/meminfo"); df = adb.Shell("df -h /data | tail -1"); }
                Size res = Cfg.EffectiveResolution();
                var line = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "{0:s}\tboot_s={1:F1}\tqemu_workingset_mb={2}\tqemu_private_mb={3}\tqemu_idle_cpu_pct_of_host={4:F2}\tlogical_cpus={5}\tram_mb={6}\tcpus={7}\tgpu={8}\tres={9}x{10}\tdpi={11}\tdata={12}\tguest_meminfo={13}\r\n",
                    DateTime.Now, bootSec, p.WorkingSet64 >> 20, p.PrivateMemorySize64 >> 20, idlePct,
                    Environment.ProcessorCount, Cfg.EffectiveRamMB(), Cfg.EffectiveCpus(), EffectiveGpu(), res.Width, res.Height, Cfg.EffectiveDpi(),
                    df.Replace("\n", " "), meminfo.Replace("\n", " | ").Replace("\r", ""));
                File.AppendAllText(Path.Combine(LogDir, "metrics.tsv"), line);
            } catch (Exception e) { Log("metrics failed: " + e.Message); }
        }
    }
}
