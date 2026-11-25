// SlightDroid launcher: start-up splash with a real percentage.
// The percentage follows boot milestones reported by Android over ADB, paced by how long the
// previous boot on this PC took (stored in %LOCALAPPDATA%\SlightDroid\boot-seconds.txt):
//   engine starting .......  0-10 %
//   Android kernel/init ...  10-50 %  (time based, until ADB answers)
//   Android services ......  50-90 %  (ADB up; time based until boot_completed)
//   finishing touches .....  90-99 %  (boot_completed, SlightDroid first-boot setup)
//   ready .................  100 %
// C# 5 / .NET Framework 4.x.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace SlightDroid {
    sealed class BootSplash : Form {
        readonly Label status, percent;
        readonly BrandBar bar;
        readonly float k;

        BootSplash(bool firstStart) {
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) k = g.DpiX / 96f;
            Text = "SlightDroid";
            Icon = AppIcon.Get(32);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = S(460, 300);
            BackColor = Color.FromArgb(17, 19, 31);
            DoubleBuffered = true;
            Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 10f);

            var logo = new PictureBox { Image = AppIcon.Get(256).ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom,
                Size = S(88, 88), Location = new Point((ClientSize.Width - S(88, 0).Width) / 2, S(0, 34).Height), BackColor = Color.Transparent };
            var title = new Label { Text = "SlightDroid", ForeColor = Color.White, BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 20f, FontStyle.Bold), Bounds = new Rectangle(0, S(0, 128).Height, ClientSize.Width, S(0, 40).Height) };
            status = new Label { Text = "Starting...", ForeColor = Color.FromArgb(170, 180, 200), BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleLeft,
                AutoEllipsis = true, Bounds = new Rectangle(S(32, 0).Width, S(0, 196).Height, ClientSize.Width - S(110, 0).Width, S(0, 24).Height) };
            percent = new Label { Text = "0%", ForeColor = Color.White, BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleRight,
                Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 11f, FontStyle.Bold),
                Bounds = new Rectangle(ClientSize.Width - S(92, 0).Width, S(0, 194).Height, S(60, 0).Width, S(0, 28).Height) };
            bar = new BrandBar {
                Bounds = new Rectangle(S(32, 0).Width, S(0, 228).Height, ClientSize.Width - S(64, 0).Width, S(0, 10).Height) };
            var hint = new Label { Text = firstStart ? "First start: setting up Android, this takes a little longer." : "Android apps, files and settings are kept between starts.", ForeColor = Color.FromArgb(110, 120, 140),
                BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleCenter, Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 8.5f),
                Bounds = new Rectangle(0, S(0, 256).Height, ClientSize.Width, S(0, 24).Height) };
            Controls.AddRange(new Control[] { logo, title, status, percent, bar, hint });
            MouseDown += (s, e) => { if (e.Button == MouseButtons.Left) { Native2.ReleaseCapture(); Native2.SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } };
        }

        Size S(int w, int h) { return new Size((int)(w * k), (int)(h * k)); }

        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            using (var pen = new Pen(Color.FromArgb(60, 70, 95))) e.Graphics.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
        }

        void Set(string text, int pct) {
            pct = Math.Max(0, Math.Min(100, pct));
            status.Text = text;
            percent.Text = pct + "%";
            if (pct > bar.Value) bar.Value = pct;
        }

        // ---- boot timing memory ----
        static string TimeFile(Vm vm) { return Path.Combine(vm.DataDir, "boot-seconds.txt"); }

        static double ExpectedSeconds(Vm vm) {
            try {
                double d;
                if (double.TryParse(File.ReadAllText(TimeFile(vm)).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d) && d > 5 && d < 600) return d;
            } catch { }
            return File.Exists(vm.DataDisk) ? 35 : 50;     // first start does extra setup
        }

        public static void Remember(Vm vm, double seconds) {
            try { File.WriteAllText(TimeFile(vm), seconds.ToString("0.0", CultureInfo.InvariantCulture)); } catch { }
        }

        // Shows the splash while Android boots. Returns true when SlightDroid is ready.
        public static bool Run(Vm vm, VmState st, TimeSpan timeout) {
            double expected = ExpectedSeconds(vm);
            bool firstStartFlag = !File.Exists(TimeFile(vm));
            bool ok = false; Exception err = null;
            using (var f = new BootSplash(firstStartFlag)) {
                f.Shown += (s, e) => new Thread(() => {
                    try { ok = Wait(vm, st, timeout, expected, (txt, p) => { try { f.BeginInvoke((Action)(() => f.Set(txt, p))); } catch { } }); }
                    catch (Exception ex) { err = ex; }
                    try { f.BeginInvoke((Action)(() => { if (ok) f.Set("Ready", 100); f.Close(); })); } catch { }
                }) { IsBackground = true }.Start();
                f.ShowDialog();
            }
            if (err != null) throw err;
            return ok;
        }

        static bool Wait(Vm vm, VmState st, TimeSpan timeout, double expected, Action<string, int> report) {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            bool adbUp = false, booted = false;
            double adbAt = 0;
            report("Starting the Android engine...", 3);
            while (sw.Elapsed < timeout) {
                if (vm.Running() == null) throw new Exception("The emulator engine stopped while Android was starting. See the logs in\n" + vm.LogDir);
                double t = sw.Elapsed.TotalSeconds;
                try {
                    using (var adb = Adb.Connect(st.AdbPort, 2500)) {
                        string r = adb.Shell("echo $(getprop debug.slightdroid.ready)/$(getprop sys.boot_completed)/$(getprop init.svc.bootanim)");
                        if (!adbUp) { adbUp = true; adbAt = t; }
                        var parts = r.Split('/');
                        if (parts.Length > 0 && parts[0] == "1") return true;
                        if (parts.Length > 1 && parts[1].Trim() == "1") {
                            booted = true;
                            // SlightDroid setup on every cold boot (a quick-boot resume keeps it): an emulator window never
                            // sleeps like a phone, and Android must not lock or dim it.
                            report("Almost ready...", 95);
                            try {
                                using (var big = Adb.Connect(st.AdbPort, 180000))   // long timeout: ~110 MB install
                                    vm.EnsureWebView(big, msg => report(msg, 96));
                            } catch (Exception e) { vm.Log("webview update failed: " + e.Message); }
                            adb.Shell("svc power stayon true; settings put system screen_off_timeout 2147483647; settings put global stay_on_while_plugged_in 7; locksettings set-disabled true; setprop debug.slightdroid.ready 1");
                            return true;
                        }
                    }
                } catch (Exception) { }

                int pct; string text;
                if (!adbUp) {
                    // kernel + Android init: 10..50 %, paced by ~45 % of the expected boot time
                    pct = 10 + (int)(40 * Math.Min(1.0, t / (expected * 0.45)));
                    text = t < 4 ? "Starting the Android engine..." : "Starting Android...";
                    // Watchdog: an early-boot freeze (engine alive, no progress) shows as no ADB and
                    // little guest memory touched. A slow PC still grows past this within ~30 s.
                    if (t > 75) {
                        long ws = 0;
                        try { ws = System.Diagnostics.Process.GetProcessById(st.Pid).WorkingSet64 >> 20; } catch { }
                        if (ws > 0 && ws < 400) throw new FrozenBootException();
                    }
                } else if (!booted) {
                    double span = Math.Max(5, expected - adbAt);
                    pct = 50 + (int)(40 * Math.Min(1.0, (t - adbAt) / span));
                    text = "Starting Android services...";
                } else {
                    pct = 92 + (int)Math.Min(7, (t - adbAt) / 2);
                    text = "Almost ready...";
                }
                report(text, Math.Min(pct, 99));
                Thread.Sleep(700);
            }
            return false;
        }
    }

    // Progress bar in the SlightDroid colours (violet -> sky), drawn ourselves.
    sealed class BrandBar : Control {
        int value;
        public int Value { get { return value; } set { this.value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        public BrandBar() { DoubleBuffered = true; SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var bg = new SolidBrush(Color.FromArgb(42, 46, 66))) g.FillRectangle(bg, ClientRectangle);
            int w = ClientSize.Width * value / 100;
            if (w > 0) using (var br = new LinearGradientBrush(new Rectangle(0, 0, Math.Max(1, ClientSize.Width), ClientSize.Height), Color.FromArgb(109, 40, 217), Color.FromArgb(14, 165, 233), 0f))
                g.FillRectangle(br, 0, 0, w, ClientSize.Height);
        }
    }

    sealed class FrozenBootException : Exception { public FrozenBootException() : base("Android froze while starting") { } }

    static class Native2 {
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ReleaseCapture();
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    }
}
