// SlightDroid launcher: Settings window (performance, display, storage, drag & drop).
// Writes %LOCALAPPDATA%\SlightDroid\settings.ini; changes apply the next time Android starts.
// C# 5 / .NET Framework 4.x.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace SlightDroid {
    sealed class SettingsForm : Form {
        readonly Vm vm;
        readonly Config c;
        readonly NumericUpDown ram, cpus, storage, cw, ch;
        readonly ComboBox gpu, res, dpi, win;
        readonly CheckBox drop, ramAuto, cpuAuto;
        bool syncing;
        readonly Label preview;
        readonly long currentGB;
        float k = 1f;

        static readonly string[] ResValues = { "auto", "1280x720", "1600x900", "1920x1080", "1280x800", "720x1280", "1080x1920", "custom" };
        static readonly string[] ResNames = {
            "Auto (fits your screen, max 1280 x 720)", "1280 x 720 (HD, landscape)", "1600 x 900 (landscape)", "1920 x 1080 (Full HD, landscape)",
            "1280 x 800 (tablet)", "720 x 1280 (phone, portrait)", "1080 x 1920 (phone Full HD, portrait)", "Custom..." };
        static readonly int[] DpiValues = { 0, 120, 160, 213, 240, 280, 320, 400, 480 };
        static readonly string[] WinValues = { "fit", "actual", "fullscreen" };
        static readonly string[] WinNames = { "Fit to screen (recommended)", "Actual size (1 Android pixel = 1 screen pixel)", "Full screen" };

        SettingsForm(Vm vm) {
            this.vm = vm;
            c = Config.Load(vm.SettingsPath);
            using (var g = CreateGraphics()) k = g.DpiX / 96f;
            Text = "SlightDroid - Settings";
            Icon = AppIcon.Get(32);
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = S(520, 590);

            int y = 12;
            // ---- performance ----
            var perf = Group("Performance", ref y, 120);
            long hostMB = (long)(new Microsoft.VisualBasic.Devices.ComputerInfo().TotalPhysicalMemory >> 20);
            int maxRam = (int)Math.Min(Config.MaxRamMB, Math.Max(Config.MinRamMB, hostMB * 3 / 4 / 256 * 256));
            ram = Num(perf, "Android memory (MB)", 0, Config.MinRamMB, maxRam, Math.Min(c.EffectiveRamMB(), maxRam), 256, "");
            int maxCpu = Math.Max(1, Math.Min(8, Environment.ProcessorCount));
            cpus = Num(perf, "CPU cores", 1, 1, maxCpu, Math.Min(c.EffectiveCpus(), maxCpu), 1, "");
            // "Automatic" = chosen from this PC each start (RAM: 4 GB PC -> 1 GB ... 8 GB+ -> 2 GB)
            ramAuto = new CheckBox { Text = "Automatic (" + Config.AutoRamMB(hostMB) + " MB)", Checked = c.RamMB == 0,
                Left = S(290, 0).Width, Top = Row(0), AutoSize = true };
            cpuAuto = new CheckBox { Text = "Automatic (" + Config.AutoCpus() + " of " + Environment.ProcessorCount + " threads)", Checked = c.Cpus == 0,
                Left = S(290, 0).Width, Top = Row(1), AutoSize = true };
            perf.Controls.Add(ramAuto); perf.Controls.Add(cpuAuto);
            // Always editable: typing a value switches "Automatic" off; ticking it puts the automatic value back.
            ramAuto.CheckedChanged += (s, e) => { if (ramAuto.Checked) { syncing = true; ram.Value = Math.Min(maxRam, Config.AutoRamMB(hostMB)); syncing = false; } };
            cpuAuto.CheckedChanged += (s, e) => { if (cpuAuto.Checked) { syncing = true; cpus.Value = Math.Min(maxCpu, Config.AutoCpus()); syncing = false; } };
            ram.ValueChanged += (s, e) => { if (!syncing) ramAuto.Checked = false; };
            cpus.ValueChanged += (s, e) => { if (!syncing) cpuAuto.Checked = false; };
            gpu = Combo(perf, "Graphics", 2, new[] { "GPU accelerated (recommended)", "Compatibility (renders on the CPU, slower)" }, vm.EffectiveGpu() == "std" ? 1 : 0);

            // ---- display ----
            var disp = Group("Display", ref y, 186);
            int ri = Array.IndexOf(ResValues, c.Resolution);
            if (ri < 0) ri = Config.ParseRes(c.Resolution) != Size.Empty ? ResValues.Length - 1 : 0;
            res = Combo(disp, "Android resolution", 0, ResNames, ri);
            Size custom = Config.ParseRes(c.Resolution); if (custom == Size.Empty) custom = c.EffectiveResolution();   // show the size in use
            var lblC = new Label { Text = "Custom size", Left = S(14, 0).Width, Top = Row(1) + S(0, 4).Height, AutoSize = true };
            cw = new NumericUpDown { Minimum = 480, Maximum = 3840, Increment = 8, Value = custom.Width, Left = S(190, 0).Width, Top = Row(1), Width = S(90, 0).Width };
            var x = new Label { Text = "x", Left = S(286, 0).Width, Top = Row(1) + S(0, 4).Height, AutoSize = true };
            ch = new NumericUpDown { Minimum = 480, Maximum = 3840, Increment = 8, Value = custom.Height, Left = S(302, 0).Width, Top = Row(1), Width = S(90, 0).Width };
            disp.Controls.AddRange(new Control[] { lblC, cw, x, ch });
            var dpiNames = new string[DpiValues.Length];
            for (int i = 0; i < DpiValues.Length; i++) dpiNames[i] = DpiValues[i] == 0 ? "Auto" : DpiValues[i] + " dpi" + (DpiValues[i] == 160 ? " (tablet / desktop)" : DpiValues[i] == 320 ? " (phone 720p)" : DpiValues[i] == 480 ? " (phone 1080p)" : "");
            dpi = Combo(disp, "Density (text and icon size)", 2, dpiNames, Math.Max(0, Array.IndexOf(DpiValues, c.Dpi)));
            win = Combo(disp, "Window", 3, WinNames, Math.Max(0, Array.IndexOf(WinValues, c.Window)));
            preview = new Label { Left = S(14, 0).Width, Top = Row(4) + S(0, 4).Height, AutoSize = true, ForeColor = SystemColors.GrayText };
            disp.Controls.Add(preview);

            // ---- storage ----
            var stor = Group("Storage", ref y, 92);
            currentGB = vm.DataDiskVirtualBytes() >> 30;
            int minGB = (int)Math.Max(Config.MinStorageGB, currentGB);
            storage = Num(stor, "Android storage (GB)", 0, minGB, 2048, Math.Max(minGB, c.StorageGB), 10, "minimum " + minGB + " GB");
            string drive = Path.GetPathRoot(vm.DataDir);
            long freeGB = 0; try { freeGB = new DriveInfo(drive).AvailableFreeSpace >> 30; } catch { }
            stor.Controls.Add(new Label { Left = S(14, 0).Width, Top = Row(1) + S(0, 4).Height, AutoSize = true, MaximumSize = S(480, 0), ForeColor = SystemColors.GrayText,
                Text = "Uses real disk space only as Android fills it (" + drive + " has " + freeGB + " GB free). It can grow, not shrink." });

            // ---- drag & drop ----
            var dd = Group("Drag and drop", ref y, 64);
            drop = new CheckBox { Text = "Show drop zones when I drag files onto the Android window",
                Checked = c.DragDrop, Left = S(14, 0).Width, Top = S(0, 24).Height, Width = S(480, 0).Width, Height = S(0, 34).Height };
            // the engine window handles drag and drop itself now (APKs install, other files go to Download);
            // the checkbox stays in settings.ini for compatibility but is not shown
            drop.Visible = false;
            dd.Controls.Add(drop);
            dd.Controls.Add(new Label { Left = S(14, 0).Width, Top = S(0, 26).Height, AutoSize = true, MaximumSize = S(480, 0),
                Text = "Drag files onto the Android window: APK files install, other files are copied to Download. For folders and copying back to Windows, use Files (tray icon)." });

            var save = new Button { Text = "Save", Width = S(96, 0).Width, Height = S(0, 30).Height, Left = ClientSize.Width - S(214, 0).Width, Top = ClientSize.Height - S(0, 44).Height };
            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = save.Width, Height = save.Height, Left = ClientSize.Width - S(110, 0).Width, Top = save.Top };
            save.Click += (s, e) => Save();
            Controls.Add(save); Controls.Add(cancel);
            AcceptButton = save; CancelButton = cancel;

            EventHandler upd = (s, e) => UpdatePreview();
            res.SelectedIndexChanged += upd; dpi.SelectedIndexChanged += upd; cw.ValueChanged += upd; ch.ValueChanged += upd; win.SelectedIndexChanged += upd;
            EventHandler toCustom = (s, e) => { if (!syncing) res.SelectedIndex = ResValues.Length - 1; };
            cw.ValueChanged += toCustom; ch.ValueChanged += toCustom;
            // picking a preset shows its size in the boxes
            res.SelectedIndexChanged += (s, e) => {
                Size p = Config.ParseRes(ResValues[res.SelectedIndex]);
                if (p == Size.Empty && ResValues[res.SelectedIndex] == "auto") { var t = Collect(); t.Resolution = "auto"; p = t.EffectiveResolution(); }
                if (p != Size.Empty) { syncing = true; cw.Value = Math.Max(cw.Minimum, Math.Min(cw.Maximum, p.Width)); ch.Value = Math.Max(ch.Minimum, Math.Min(ch.Maximum, p.Height)); syncing = false; }
            };
            UpdatePreview();
        }

        Size S(int w, int h) { return new Size((int)(w * k), (int)(h * k)); }
        int Row(int i) { return S(0, 24 + i * 32).Height; }

        GroupBox Group(string title, ref int y, int h) {
            var g = new GroupBox { Text = title, Left = S(12, 0).Width, Top = S(0, y).Height, Width = ClientSize.Width - S(24, 0).Width, Height = S(0, h).Height };
            Controls.Add(g); y += h + 10; return g;
        }

        NumericUpDown Num(GroupBox g, string label, int row, int min, int max, int value, int step, string hint) {
            g.Controls.Add(new Label { Text = label, Left = S(14, 0).Width, Top = Row(row) + S(0, 4).Height, AutoSize = true });
            var n = new NumericUpDown { Minimum = min, Maximum = Math.Max(min, max), Increment = step, Value = Math.Max(min, Math.Min(Math.Max(min, max), value)),
                Left = S(190, 0).Width, Top = Row(row), Width = S(90, 0).Width };
            g.Controls.Add(n);
            g.Controls.Add(new Label { Text = hint, Left = S(290, 0).Width, Top = Row(row) + S(0, 4).Height, AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = S(200, 0) });
            return n;
        }

        ComboBox Combo(GroupBox g, string label, int row, string[] items, int index) {
            g.Controls.Add(new Label { Text = label, Left = S(14, 0).Width, Top = Row(row) + S(0, 4).Height, AutoSize = true });
            var cb = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Left = S(190, 0).Width, Top = Row(row), Width = g.Width - S(204, 0).Width };
            cb.Items.AddRange(items); cb.SelectedIndex = Math.Max(0, Math.Min(items.Length - 1, index));
            g.Controls.Add(cb);
            return cb;
        }

        Config Collect() {
            var n = Config.Load(vm.SettingsPath);
            n.RamMB = ramAuto.Checked ? 0 : (int)ram.Value; n.Cpus = cpuAuto.Checked ? 0 : (int)cpus.Value; n.Gpu = gpu.SelectedIndex == 1 ? "std" : "virgl";
            if (n.Gpu == "virgl") vm.ClearGpuFallback();   // explicitly chosen again: try GPU acceleration (it is watched again)
            string rv = ResValues[res.SelectedIndex];
            n.Resolution = rv == "custom" ? ((int)cw.Value & ~7) + "x" + ((int)ch.Value & ~7) : rv;
            n.Dpi = DpiValues[dpi.SelectedIndex];
            n.Window = WinValues[win.SelectedIndex];
            n.StorageGB = (int)storage.Value;
            n.DragDrop = drop.Checked;
            return n;
        }

        void UpdatePreview() {
            // the custom size boxes stay editable: typing a size selects "Custom" (handlers in the constructor)
            var n = Collect();
            Size r = n.EffectiveResolution();
            preview.Text = "Android will use " + Config.Describe(r) + " at " + n.EffectiveDpi() + " dpi" +
                (r.Height > r.Width ? " (portrait)" : "") + (r.Width * r.Height > 1280 * 720 ? ". Larger than 720p needs more CPU/GPU." : ".");
        }

        void Save() {
            var n = Collect();
            n.Save(vm.SettingsPath);
            vm.Cfg = n;
            vm.Log("settings saved: ram=" + n.RamMB + " cpus=" + n.Cpus + " gpu=" + n.Gpu + " res=" + n.Resolution + " dpi=" + n.Dpi + " window=" + n.Window + " storage=" + n.StorageGB + " dragdrop=" + n.DragDrop);
            DialogResult = DialogResult.OK;
            Close();
        }

        // Shows Settings. If Android is running, offers to restart it so the changes apply.
        public static void ShowFor(Vm vm, bool fromRunningSession) {
            using (var f = new SettingsForm(vm)) {
                if (f.ShowDialog() != DialogResult.OK) return;
            }
            var st = vm.Running();
            if (st == null) return;
            if (MessageBox.Show("Settings saved. Restart Android now to apply them?\n\nYour apps and files are kept.", "SlightDroid",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            // a fresh launcher starts Android again once this one has stopped it and exited
            Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--start-after " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
            Program.RunWithStatus("Restarting Android...", s => { vm.Stop(st, 15000); return true; });
            if (!fromRunningSession) Application.Exit();
        }
    }
}
