// SlightDroid launcher entry point.
//   SlightDroid.exe                     start Android (or bring the running window to the front)
//   SlightDroid.exe a.apk [b.apk ...]   install apps (also what happens when APKs are dropped on the icon)
//   SlightDroid.exe --install a.apk     same
//   SlightDroid.exe --files             Windows <-> Android file transfer window
//   SlightDroid.exe --settings          Settings window
//   SlightDroid.exe --stop              save and shut Android down
//   SlightDroid.exe --start-after PID   (internal) wait for PID to exit, then start (used to apply settings)
// C# 5 / .NET Framework 4.x, compiled with the csc.exe that ships with Windows.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("SlightDroid")]
[assembly: System.Reflection.AssemblyProduct("SlightDroid")]
[assembly: System.Reflection.AssemblyVersion("0.1.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.1.0.0")]

namespace SlightDroid {
    static class Program {
        const string Title = "SlightDroid";

        [STAThread]
        static int Main(string[] args) {
            Native.MakeDpiAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Vm vm;
            try { vm = new Vm(); } catch (Exception e) { Error("SlightDroid could not start:\n\n" + e.Message); return 1; }
            try {
                string a0 = args.Length > 0 ? args[0] : "";
                if (a0 == "--stop") { var st = vm.Running(); if (st != null) RunWithStatus("Saving your Android data...", s => { vm.Stop(st, 15000); return true; }); return 0; }
                if (a0 == "--settings") { SettingsForm.ShowFor(vm, false); return 0; }
                if (a0 == "--files") {
                    var st = vm.Running();
                    if (st == null) { Error("Start SlightDroid first, then open Files."); return 1; }
                    Application.Run(new FilesForm(vm, st)); return 0;
                }
                if (a0 == "--start-after" && args.Length > 1) {
                    int pid; if (int.TryParse(args[1], out pid)) try { Process.GetProcessById(pid).WaitForExit(60000); } catch { }
                    for (int i = 0; i < 40 && vm.Running() != null; i++) Thread.Sleep(500);
                    if (vm.GpuFellBack && (DateTime.Now - vm.GpuFallbackTime).TotalMinutes < 3)
                        new Thread(() => MessageBox.Show(
                            "Android's screen stopped responding with GPU acceleration on this PC (a graphics driver problem), " +
                            "so SlightDroid is restarting it with compatibility graphics. This is remembered; your apps and files are kept.\n\n" +
                            "To try GPU acceleration again: SlightDroid Settings > Graphics.", Title, MessageBoxButtons.OK, MessageBoxIcon.Information)).Start();
                    return StartOrFocus(vm);
                }
                var apks = args.Where(a => a != "--install").ToArray();
                if (apks.Length > 0) return Install(vm, apks);
                return StartOrFocus(vm);
            } catch (Exception e) {
                vm.Log("error: " + e);
                Error(e.Message);
                return 1;
            }
        }

        public static void Error(string msg) { MessageBox.Show(msg, Title, MessageBoxButtons.OK, MessageBoxIcon.Error); }

        // ---------------- start ----------------
        static int StartOrFocus(Vm vm) {
            var running = vm.Running();
            if (running != null) {
                Focus(running.Pid);
                // if no launcher is looking after this Android anymore, take over (tray, save on close...)
                bool free;
                using (var session = new Mutex(true, "Local\\SlightDroid.session" + vm.InstanceTag, out free)) {
                    if (free) Application.Run(new RunContext(vm, running, false));
                }
                return 0;
            }

            bool single;
            using (var mutex = new Mutex(true, "Local\\SlightDroid.launcher" + vm.InstanceTag, out single)) {
                if (!single) return 0;   // another launcher is starting it right now
                if (vm.Cfg.Accel == "whpx" && !Vm.WhpxAvailable()) {
                    Error("SlightDroid needs \"Windows Hypervisor Platform\", and it is not active on this PC.\n\n" +
                          "Run \"SlightDroid Check\" from the Start menu: it tells you exactly what to do " +
                          "(usually: enable the feature and restart, or turn on virtualization in the BIOS).");
                    return 2;
                }
                VmState st = null;
                RunWithStatus("Preparing Android storage...", s => { st = vm.Start(); return true; });
                bool free;
                using (var session = new Mutex(true, "Local\\SlightDroid.session" + vm.InstanceTag, out free)) {
                    // the session styles and fits the Android window while it boots (its timer runs
                    // inside the modal status window's message loop)
                    var ctx = new RunContext(vm, st, true);
                    var sw = Stopwatch.StartNew();
                    bool ready = false;
                    // Watchdog: an intermittent early-boot freeze is retried with a fresh engine
                    // (nothing is written to the data disk that early).
                    for (int attempt = 1; ; attempt++) {
                        try { ready = BootSplash.Run(vm, st, TimeSpan.FromMinutes(6)); break; }
                        catch (Exception e) {
                            if (e.GetType().Name != "FrozenBootException" || attempt >= 3) throw;
                            vm.Log("boot froze (attempt " + attempt + "), restarting the engine");
                            try { Process.GetProcessById(st.Pid).Kill(); Process.GetProcessById(st.Pid).WaitForExit(10000); } catch { }
                            ctx.ExitThread();
                            st = vm.Start();
                            ctx = new RunContext(vm, st, false);
                            ctx.HideUntilReady();
                        }
                    }
                    if (!ready && vm.Running() != null) Error("Android did not finish starting in 6 minutes. The window stays open; see the logs in\n" + vm.LogDir);
                    double bootSec = sw.Elapsed.TotalSeconds;
                    vm.Log(string.Format(System.Globalization.CultureInfo.InvariantCulture, "ready after {0:F1} s", bootSec));
                    if (ready) BootSplash.Remember(vm, bootSec);
                    ctx.FitWhenReady();
                    if (vm.Cfg.Window == "fullscreen") ctx.FullScreenWhenShown();       // fits, shows and focuses the Android window (also after a timeout)
                    if (ready) new Thread(() => vm.RecordMetrics(st, bootSec)) { IsBackground = true }.Start();
                    if (ready && vm.EffectiveGpu() == "virgl" && Environment.GetEnvironmentVariable("SLIGHTDROID_NOFALLBACK") == null) {
                        var watched = st;
                        new Thread(() => {
                            if (!vm.WatchForGpuHang(watched, TimeSpan.FromMinutes(3))) return;
                            // restart in compatibility graphics: a fresh launcher starts Android once this one has stopped it
                            Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--start-after " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
                            vm.Stop(watched, 15000);
                        }) { IsBackground = true }.Start();
                    }
                    if (vm.Running() != null) Application.Run(ctx);
                }
                try { Process.GetProcessById(st.Pid).WaitForExit(); } catch { }
                vm.Log("engine exited");
            }
            return 0;
        }

        // ---------------- install ----------------
        static int Install(Vm vm, string[] apks) {
            var missing = apks.Where(a => !File.Exists(a) && !Directory.Exists(a)).ToArray();
            if (missing.Length > 0) { Error("File not found:\n" + string.Join("\n", missing)); return 1; }
            var st = vm.Running();
            if (st == null) {
                Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = false });
                bool up = RunWithStatus("Starting SlightDroid...", status => {
                    var sw = Stopwatch.StartNew();
                    while (sw.Elapsed < TimeSpan.FromMinutes(1)) { st = vm.Running(); if (st != null) break; Thread.Sleep(500); }
                    return st != null && vm.WaitReady(st, TimeSpan.FromMinutes(6), status);
                });
                if (!up) { Error("Android did not start, so nothing was installed."); return 1; }
            }
            var notApk = apks.Where(a => !a.EndsWith(".apk", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (notApk.Length > 0) FilesForm.SendToAndroid(vm, st, notApk, "/sdcard/Download");   // other files dropped on the icon: copy
            var real = apks.Except(notApk).ToArray();
            return real.Length == 0 || InstallInto(vm, st, real) ? 0 : 1;
        }

        // Installs one or more APKs into the running VM, then opens the last newly installed app.
        // Used by "--install", by APKs dropped on the SlightDroid icon, the tray menu and the drop overlay.
        public static bool InstallInto(Vm vm, VmState st, string[] apks) {
            var failures = new System.Collections.Generic.List<string>();
            string launched = null;
            for (int i = 0; i < apks.Length; i++) {
                string apk = apks[i], name = Path.GetFileName(apk), result = null, pkgNew = null;
                string prefix = apks.Length > 1 ? string.Format("({0}/{1}) ", i + 1, apks.Length) : "";
                RunWithStatus(prefix + "Installing " + name, status => {
                    using (var adb = Adb.Connect(st.AdbPort, 120000)) {
                        var before = adb.Shell("pm list packages -3").Split('\n').Select(l => l.Trim()).ToList();
                        result = adb.InstallApk(apk, (sent, total) => status(string.Format("{0}Installing {1}... {2}%", prefix, name, sent * 100 / Math.Max(1, total))));
                        if (result.Contains("Success")) {
                            var pkg = adb.Shell("pm list packages -3").Split('\n').Select(l => l.Trim()).Except(before).FirstOrDefault();
                            if (pkg != null && pkg.StartsWith("package:")) pkgNew = pkg.Substring(8);
                        }
                    }
                    return true;
                });
                vm.Log("install " + name + ": " + result);
                if (result != null && result.Contains("Success")) { if (pkgNew != null) launched = pkgNew; continue; }
                string why = result ?? "no answer";
                if (why.Contains("NO_MATCHING_ABIS")) why += "\n(This app only contains ARM code. SlightDroid Lite runs x86 apps; ARM support comes later.)";
                if (why.Contains("OLDER_SDK") || why.Contains("MIN_SDK")) why += "\n(This app needs a newer Android version than SlightDroid Lite, Android 9.)";
                failures.Add(name + ": " + why);
            }
            if (launched != null) {
                try { using (var adb = Adb.Connect(st.AdbPort, 15000)) adb.Shell("monkey -p " + launched + " -c android.intent.category.LAUNCHER 1"); } catch { }
            }
            Focus(st.Pid);
            if (failures.Count > 0) { Error("Could not install:\n\n" + string.Join("\n\n", failures)); return false; }
            return true;
        }

        // ---------------- UI helpers ----------------
        // Shows a small status window while 'work' runs on a background thread.
        public static bool RunWithStatus(string title, Func<Action<string>, bool> work) {
            float k; using (var g = Graphics.FromHwnd(IntPtr.Zero)) k = g.DpiX / 96f;
            using (var f = new Form {
                Text = Title, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = true,
                StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size((int)(440 * k), (int)(100 * k)), ShowInTaskbar = true,
                Font = SystemFonts.MessageBoxFont, Icon = AppIcon.Get(32), AutoScaleMode = AutoScaleMode.None,
            }) {
                int logo = (int)(48 * k), x0 = (int)(16 * k) + logo + (int)(14 * k), w = f.ClientSize.Width - x0 - (int)(16 * k);
                var pic = new PictureBox { Image = AppIcon.Get(64).ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Left = (int)(16 * k), Top = (int)(24 * k), Width = logo, Height = logo };
                var label = new Label { Text = title, Left = x0, Top = (int)(22 * k), Width = w, Height = (int)(24 * k), AutoEllipsis = true };
                var bar = new ProgressBar { Style = ProgressBarStyle.Marquee, Left = x0, Top = (int)(56 * k), Width = w, Height = (int)(16 * k), MarqueeAnimationSpeed = 30 };
                f.Controls.Add(pic); f.Controls.Add(label); f.Controls.Add(bar);
                bool ok = false; Exception err = null;
                f.Shown += (s, e) => new Thread(() => {
                    try { ok = work(msg => { try { f.BeginInvoke((Action)(() => label.Text = msg)); } catch { } }); }
                    catch (Exception ex) { err = ex; }
                    try { f.BeginInvoke((Action)(() => f.Close())); } catch { }
                }) { IsBackground = true }.Start();
                f.ShowDialog();       // modal: also works inside the running session loop
                if (err != null) throw err;
                return ok;
            }
        }

        static void Focus(int pid) {
            try {
                var p = Process.GetProcessById(pid);
                for (int i = 0; i < 20 && p.MainWindowHandle == IntPtr.Zero; i++) { Thread.Sleep(250); p.Refresh(); }
                if (p.MainWindowHandle != IntPtr.Zero) { Native.ShowWindow(p.MainWindowHandle, 9 /* SW_RESTORE */); Native.SetForegroundWindow(p.MainWindowHandle); }
            } catch { }
        }
    }
}
