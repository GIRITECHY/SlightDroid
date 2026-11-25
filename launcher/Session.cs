// SlightDroid launcher: everything that runs while Android is up (one per VM).
//  - names the Android window "SlightDroid", gives it the SlightDroid icon, fits it to the screen
//  - closing it (X button or Alt+F4) saves first: QEMU runs with window-close=off, and low-level
//    input hooks catch the X click / Alt+F4 on the Android window -> sync Android -> quit QEMU
//  - Windows shutting down / logging off: same save path
//  - drag & drop overlay (DropOverlay.cs), tray icon with Install / Files / Settings / Stop
// C# 5 / .NET Framework 4.x.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace SlightDroid {
    sealed class RunContext : ApplicationContext {
        readonly Vm vm;
        readonly VmState st;
        readonly Process qemu;
        readonly System.Windows.Forms.Timer timer;
        readonly OverlayForm overlay;
        readonly NotifyIcon tray;
        readonly Form host;                 // invisible: owns dialogs and marshals to the UI thread
        IntPtr hwnd = IntPtr.Zero;
        bool styled, busy, saving;
        int tick;
        Rectangle closeBtn = Rectangle.Empty;   // screen rect of the Android window's X button
        bool closeDown;
        bool fitPending;                       // set when Android is ready: the window is then fitted once
        bool hiddenUntilReady;                 // fresh start: Android window hidden until ready
        FilesForm files;
        readonly FullScreen full = new FullScreen();
        bool fullWhenShown;                    // Settings > Window = Full screen: switch once the window is up
        public void FullScreenWhenShown() { fullWhenShown = true; }

        bool androidReady;                     // full screen only once Android is up (changing the window during boot can upset the engine)
        void ToggleFullScreen() { if (hwnd == IntPtr.Zero || !androidReady) return; full.Toggle(hwnd, st.Pid); vm.Log("full screen " + (full.On ? "on" : "off")); }

        public RunContext(Vm vm, VmState st, bool justStarted) {
            this.vm = vm; this.st = st;
            // The engine's own window (Google emulator, Qt) handles drag & drop (APK install / copy to Download), the side
            // toolbar and closing with a quick-boot save itself, so SlightDroid only names it and adds the tray.
            hiddenUntilReady = false;
            androidReady = !justStarted;           // attaching to an Android that is already up
            qemu = Process.GetProcessById(st.Pid);
            qemu.EnableRaisingEvents = true;
            host = new Form { ShowInTaskbar = false, Opacity = 0, FormBorderStyle = FormBorderStyle.None, Size = new Size(1, 1) };
            var hh = host.Handle;
            overlay = new OverlayForm();
            var oh = overlay.Handle;
            overlay.FilesDropped += (f, act) => Ui(() => HandleFiles(f, act));
            qemu.Exited += (s, e) => Ui(ExitThread);

            tray = new NotifyIcon { Icon = AppIcon.Get(16), Text = "SlightDroid", Visible = true, ContextMenuStrip = Menu() };
            tray.DoubleClick += (s, e) => ShowAndroid();
            if (justStarted) tray.ShowBalloonTip(4000, "SlightDroid is running",
                "Right-click this icon to install apps, move files between Windows and Android, or change settings.", ToolTipIcon.Info);

            Microsoft.Win32.SystemEvents.SessionEnding += OnSessionEnding;
            hookMouse = MouseHook; hookKey = KeyHook;
            // keyboard hook only for SlightDroid's own keys (F11 / Ctrl+Alt+F full screen) while the Android window is in
            // front; no mouse hook: the engine window saves on close by itself
            keyHook = SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, hookKey, GetModuleHandle(null), 0);

            timer = new System.Windows.Forms.Timer { Interval = 100 };
            timer.Tick += (s, e) => Tick();
            timer.Start();
            if (qemu.HasExited) ExitThread();
        }

        void Ui(Action a) { try { if (!host.IsDisposed) host.BeginInvoke(a); } catch { } }

        protected override void ExitThreadCore() {
            timer.Stop();
            try { full.Exit(); } catch { }
            if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
            if (keyHook != IntPtr.Zero) UnhookWindowsHookEx(keyHook);
            Microsoft.Win32.SystemEvents.SessionEnding -= OnSessionEnding;
            tray.Visible = false; tray.Dispose();
            overlay.Close();
            if (files != null && !files.IsDisposed) files.Close();
            host.Close();
            base.ExitThreadCore();
        }

        // ---------------- tray ----------------
        ContextMenuStrip Menu() {
            var m = new ContextMenuStrip();
            m.Items.Add("Show Android", null, (s, e) => ShowAndroid());
            m.Items.Add("Full screen on/off    F11", null, (s, e) => ToggleFullScreen());
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Install app (APK)...", null, (s, e) => PickApks());
            m.Items.Add("Files: Windows <-> Android...", null, (s, e) => ShowFiles());
            m.Items.Add("Settings...", null, (s, e) => SettingsForm.ShowFor(vm, true));
            m.Items.Add(new ToolStripSeparator());
            var keys = new ToolStripMenuItem("Keyboard shortcuts (in the Android window)");
            foreach (var k in Shortcuts) keys.DropDownItems.Add(new ToolStripMenuItem(k) { Enabled = false });            m.Items.Add(keys);
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Stop SlightDroid", null, (s, e) => SaveAndQuit("tray"));
            return m;
        }

        // Shortcuts of the engine window (Android Emulator); the side toolbar has buttons for the same actions.
        public static readonly string[] Shortcuts = {
            "Full screen on/off:  F11  (or Ctrl + Alt + F)", "Home:  Ctrl + H", "Back:  Ctrl + Backspace  (or Esc)", "Recent apps:  Ctrl + O", "Power / lock screen:  Ctrl + P",
            "Volume up / down:  Ctrl + =  /  Ctrl + -", "Rotate left / right:  Ctrl + Left  /  Ctrl + Right",
            "Screenshot:  Ctrl + S", "More controls (location, battery, settings...):  Ctrl + Shift + S",
            "Install an app or copy files: drag them onto the Android window", "Close (saves, next start resumes):  X button" };

        void ShowAndroid() { if (hwnd != IntPtr.Zero) { Native.ShowWindow(hwnd, 9); Native.SetForegroundWindow(hwnd); } }

        void PickApks() {
            using (var d = new OpenFileDialog { Title = "Install app in SlightDroid", Filter = "Android apps (*.apk)|*.apk", Multiselect = true }) {
                if (d.ShowDialog(host) == DialogResult.OK) HandleFiles(d.FileNames, DropAction.Install);
            }
        }

        void ShowFiles() {
            if (files == null || files.IsDisposed) files = new FilesForm(vm, st);
            files.Show(); files.Activate();
        }

        void HandleFiles(string[] list, DropAction act) {
            overlay.Hide();
            if (busy) return;
            busy = true;
            try {
                if (act == DropAction.Install) {
                    var apks = list.Where(f => f.EndsWith(".apk", StringComparison.OrdinalIgnoreCase)).ToArray();
                    var other = list.Except(apks).ToArray();
                    if (apks.Length > 0) Program.InstallInto(vm, st, apks);
                    if (other.Length > 0) FilesForm.SendToAndroid(vm, st, other, "/sdcard/Download");
                } else {
                    FilesForm.SendToAndroid(vm, st, list, "/sdcard/Download");
                }
            } catch (Exception e) { vm.Log("drop: " + e); Program.Error(e.Message); }
            finally { busy = false; }
        }

        // ---------------- window + drop watcher ----------------
        void Tick() {
            tick++;
            if (hwnd == IntPtr.Zero || tick % 10 == 0) {           // find / refresh the Android window every second
                try { qemu.Refresh(); var h = qemu.MainWindowHandle; if (h != IntPtr.Zero) hwnd = h; } catch { }
                if (hwnd != IntPtr.Zero) {
                    StyleWindow(); full.Refit();
                    if (fullWhenShown && Native.IsWindowVisible(hwnd)) { fullWhenShown = false; ToggleFullScreen(); }
                    if (fitPending) {
                        fitPending = false;
                        if (vm.Cfg.Window != "fullscreen" && Environment.GetEnvironmentVariable("SLIGHTDROID_NOFIT") == null) FitWindow(vm.Cfg.Window == "actual");
                        if (hiddenUntilReady) { hiddenUntilReady = false; Native.ShowWindow(hwnd, 5 /* SW_SHOW */); Native.SetForegroundWindow(hwnd); }
                    } else if (hiddenUntilReady && Native.IsWindowVisible(hwnd)) Native.ShowWindow(hwnd, 0 /* SW_HIDE */);
                }
            }
            if (hwnd == IntPtr.Zero || busy || saving) return;
            if (!vm.Cfg.DragDrop) { if (overlay.Visible) overlay.Hide(); return; }

            int vk = Native.GetSystemMetrics(23 /* SM_SWAPBUTTON */) != 0 ? 0x02 : 0x01;
            bool button = (Native.GetAsyncKeyState(vk) & 0x8000) != 0;
            if (!button) { if (overlay.Visible) overlay.Hide(); return; }
            if (overlay.Visible) return;                            // keep it while the drag continues
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return;     // minimized: never
            IntPtr fg = Native.GetForegroundWindow();
            if (fg == hwnd || fg == overlay.Handle) return;         // a swipe/tap inside Android
            Native.POINT p; Native.GetCursorPos(out p);
            Rectangle screen = Native.ClientRectOnScreen(hwnd);
            // only where the Android screen is really visible (not covered by Explorer etc.)
            if (screen.Width > 0 && screen.Contains(p.X, p.Y) && Native.PointIsOn(hwnd, p.X, p.Y)) overlay.ShowAt(screen);
        }

        void StyleWindow() {
            var sb = new StringBuilder(256); Native.GetWindowText(hwnd, sb, 256);
            if (sb.ToString() != "SlightDroid") Native.SetWindowText(hwnd, "SlightDroid");
            if (styled) return;
            styled = true;
            Native.SendMessage(hwnd, 0x0080 /* WM_SETICON */, (IntPtr)1, AppIcon.Get(32).Handle);
            Native.SendMessage(hwnd, 0x0080, (IntPtr)0, AppIcon.Get(16).Handle);
            // While Android boots the window would only show firmware/boot text: keep it hidden
            // (the "Starting SlightDroid" window is shown instead) and reveal it, fitted, when ready.
            if (hiddenUntilReady) Native.ShowWindow(hwnd, 0 /* SW_HIDE */);
        }

        // Called when Android is ready. Fitting only then (once) avoids a resize loop during boot:
        // a window resize makes QEMU tell the guest a new display size, the boot console switches
        // mode and QEMU resizes the window back... After boot Android keeps its resolution and
        // the window simply scales. The user can resize freely afterwards.
        public void FitWhenReady() { androidReady = true; }   // engine window sizes itself; marks Android as ready

        // used after a watchdog restart: behave like a fresh start (window hidden until ready)
        public void HideUntilReady() { hiddenUntilReady = Environment.GetEnvironmentVariable("SLIGHTDROID_NOHIDE") == null; }

        // Sizes the Android window: "fit" = as large as fits the screen (keeping the aspect ratio,
        // at most 1.5x), "actual" = one Android pixel per screen pixel (shrunk if it does not fit).
        void FitWindow(bool actual) {
            Native.RECT wr, cr;
            if (!Native.GetWindowRect(hwnd, out wr) || !Native.GetClientRect(hwnd, out cr)) return;
            int frameW = (wr.Right - wr.Left) - (cr.Right - cr.Left), frameH = (wr.Bottom - wr.Top) - (cr.Bottom - cr.Top);
            Size res = vm.Cfg.EffectiveResolution();
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            double maxW = wa.Width * 0.96 - frameW, maxH = wa.Height * 0.96 - frameH;
            double fit = Math.Min(maxW / res.Width, maxH / res.Height);
            double scale = actual ? Math.Min(1.0, fit) : Math.Min(1.5, fit);
            int w = (int)(res.Width * scale) + frameW, h = (int)(res.Height * scale) + frameH;
            Native.SetWindowPos(hwnd, IntPtr.Zero, wa.X + (wa.Width - w) / 2, wa.Y + (wa.Height - h) / 2, w, h, 0x0014 /* NOZORDER|NOACTIVATE */);
            vm.Log("window " + (actual ? "actual" : "fit") + ": Android " + Config.Describe(res) + " shown at " + Config.Inv(scale * 100) + " %");
        }

        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out Native.RECT r, int size);

        void UpdateCloseButton() {
            Native.RECT r, wr;
            if (DwmGetWindowAttribute(hwnd, 5 /* DWMWA_CAPTION_BUTTON_BOUNDS */, out r, Marshal.SizeOf(typeof(Native.RECT))) != 0) return;
            if (!Native.GetWindowRect(hwnd, out wr)) return;
            int bw = r.Right - r.Left, bh = r.Bottom - r.Top;
            if (bw <= 0 || bh <= 0) return;
            int closeW = bw / 3;                                     // min, max, close: the close button is the last third
            closeBtn = new Rectangle(wr.Left + r.Right - closeW, wr.Top + r.Top, closeW, bh);
        }

        // ---------------- save on close ----------------
        void OnSessionEnding(object s, Microsoft.Win32.SessionEndingEventArgs e) { SaveNow("windows " + e.Reason); }

        // Flush Android's writes to the virtual disk, then quit QEMU cleanly (it also flushes the disk).
        void SaveNow(string why) {
            if (saving) return;
            saving = true;
            vm.Log("closing (" + why + ")");
            vm.Stop(st, 15000);
        }

        void SaveAndQuit(string why) {
            if (saving) return;
            overlay.Hide();
            Program.RunWithStatus("Saving your Android data...", status => { SaveNow(why); return true; });
        }

        delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
        HookProc hookMouse, hookKey;          // kept as fields so the GC does not collect them
        IntPtr mouseHook, keyHook;
        [StructLayout(LayoutKind.Sequential)] struct MSLL { public Native.POINT pt; public uint data, flags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct KBLL { public uint vk, scan, flags, time; public IntPtr extra; }
        [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr mod, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

        // Must return fast: only compares the click with the cached X-button rectangle.
        IntPtr MouseHook(int code, IntPtr w, IntPtr l) {
            if (code >= 0 && !saving && closeBtn.Width > 0) {
                int msg = w.ToInt32();
                if (msg == 0x0201 || msg == 0x0202) {                 // WM_LBUTTONDOWN / UP
                    var m = (MSLL)Marshal.PtrToStructure(l, typeof(MSLL));
                    bool on = closeBtn.Contains(m.pt.X, m.pt.Y) && Native.GetForegroundWindow() == hwnd;
                    if (msg == 0x0201) closeDown = on;
                    else if (closeDown && on) { closeDown = false; Ui(() => SaveAndQuit("X button")); }
                    else closeDown = false;
                }
            }
            return CallNextHookEx(mouseHook, code, w, l);
        }

        IntPtr KeyHook(int code, IntPtr w, IntPtr l) {
            int msg = w.ToInt32();
            if (code >= 0 && (msg == 0x0100 || msg == 0x0104) /* WM_KEYDOWN / WM_SYSKEYDOWN */) {
                var k = (KBLL)Marshal.PtrToStructure(l, typeof(KBLL));
                IntPtr fg = Native.GetForegroundWindow();
                bool ours = fg != IntPtr.Zero && (fg == hwnd || fg == full.Backdrop);
                bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0, alt = (k.flags & 0x20) != 0;
                if (ours && (k.vk == 0x7A /* F11 */ || (k.vk == 0x46 /* F */ && ctrl && alt))) {
                    Ui(ToggleFullScreen);
                    return (IntPtr)1;      // handled: Android does not see it
                }
            }
            return CallNextHookEx(keyHook, code, w, l);
        }
    }

    // The SlightDroid logo, embedded in the exe (SlightDroid.ico).
    static class AppIcon {
        static readonly System.Collections.Generic.Dictionary<int, Icon> cache = new System.Collections.Generic.Dictionary<int, Icon>();
        public static Icon Get(int size) {
            lock (cache) {
                Icon i;
                if (cache.TryGetValue(size, out i)) return i;
                try {
                    using (var s = typeof(AppIcon).Assembly.GetManifestResourceStream("SlightDroid.ico")) i = new Icon(s, size, size);
                } catch { i = SystemIcons.Application; }
                cache[size] = i;
                return i;
            }
        }
    }
}
