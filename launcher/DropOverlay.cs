// SlightDroid launcher: drop overlay shown over the Android window while files are dragged in.
// Two zones: "Install app" (APKs) and "Copy to Android" (any file -> Android's Download folder).
// When it appears is decided by Session.cs (only over the visible Android screen, only for drags
// that start outside Android, and only if enabled in Settings).
// C# 5 / .NET Framework 4.x.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SlightDroid {
    public enum DropAction { Install, Copy }

    sealed class OverlayForm : Form {
        public event Action<string[], DropAction> FilesDropped;
        string[] files;
        bool hasApk;
        DropAction hover = DropAction.Install;
        readonly Font big, small;

        public OverlayForm() {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(18, 20, 32);
            Opacity = 0.9;
            AllowDrop = true;
            DoubleBuffered = true;
            big = new Font(SystemFonts.MessageBoxFont.FontFamily, 18f, FontStyle.Bold);
            small = new Font(SystemFonts.MessageBoxFont.FontFamily, 10.5f);
            DragEnter += (s, e) => { files = Files(e.Data); hasApk = files != null && files.Any(IsApk); Update(e); };
            DragOver += (s, e) => Update(e);
            DragLeave += (s, e) => Hide();
            DragDrop += (s, e) => {
                var f = Files(e.Data);
                if (f != null && FilesDropped != null) BeginInvoke(FilesDropped, new object[] { f, ZoneAt(e.X, e.Y) });
            };
        }

        static bool IsApk(string f) { return f.EndsWith(".apk", StringComparison.OrdinalIgnoreCase); }

        static string[] Files(IDataObject d) {
            return d != null && d.GetDataPresent(DataFormats.FileDrop) ? d.GetData(DataFormats.FileDrop) as string[] : null;
        }

        // without APKs there is only one zone: copy
        DropAction ZoneAt(int screenX, int screenY) {
            if (!hasApk) return DropAction.Copy;
            return PointToClient(new Point(screenX, screenY)).X < ClientSize.Width / 2 ? DropAction.Install : DropAction.Copy;
        }

        void Update(DragEventArgs e) {
            if (files == null) { e.Effect = DragDropEffects.None; return; }
            var z = ZoneAt(e.X, e.Y);
            e.Effect = DragDropEffects.Copy;
            if (z != hover) { hover = z; Invalidate(); }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams {
            get {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 /* WS_EX_NOACTIVATE */ | 0x00000080 /* WS_EX_TOOLWINDOW */;
                return cp;
            }
        }

        public void ShowAt(Rectangle screen) {
            files = null; hasApk = true; hover = DropAction.Install;
            Bounds = screen;
            Show();
            Native.SetWindowPos(Handle, (IntPtr)(-1) /* HWND_TOPMOST */, screen.X, screen.Y, screen.Width, screen.Height, 0x0010 /* SWP_NOACTIVATE */);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int pad = 18;
            var all = new Rectangle(pad, pad, ClientSize.Width - 2 * pad, ClientSize.Height - 2 * pad);
            if (hasApk) {
                int half = (all.Width - pad) / 2;
                Zone(g, new Rectangle(all.X, all.Y, half, all.Height), "Install app",
                    "Installs the .apk and opens it", hover == DropAction.Install);
                Zone(g, new Rectangle(all.X + half + pad, all.Y, half, all.Height), "Copy to Android",
                    "Saved to Download (shows in VLC, Files...)", hover == DropAction.Copy);
            } else {
                Zone(g, all, "Copy to Android", "Files are saved to Android's Download folder", true);
            }
        }

        void Zone(Graphics g, Rectangle r, string title, string sub, bool active) {
            Color accent = Color.FromArgb(56, 189, 248);
            using (var bg = new SolidBrush(active ? Color.FromArgb(40, 56, 189, 248) : Color.FromArgb(10, 255, 255, 255)))
                g.FillRectangle(bg, r);
            using (var pen = new Pen(active ? accent : Color.FromArgb(110, 120, 140), active ? 3f : 2f) { DashStyle = DashStyle.Dash })
                g.DrawRectangle(pen, r);
            var t = new Rectangle(r.X, r.Y + r.Height / 2 - 34, r.Width, 40);
            var s = new Rectangle(r.X, r.Y + r.Height / 2 + 8, r.Width, 26);
            TextRenderer.DrawText(g, title, big, t, active ? Color.White : Color.FromArgb(170, 180, 195), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            TextRenderer.DrawText(g, sub, small, s, Color.FromArgb(170, 180, 195), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        protected override void Dispose(bool disposing) { if (disposing) { big.Dispose(); small.Dispose(); } base.Dispose(disposing); }
    }

    static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h, string s);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int max);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);

        public static Rectangle ClientRectOnScreen(IntPtr h) {
            RECT r; if (!GetClientRect(h, out r)) return Rectangle.Empty;
            var p = new POINT { X = 0, Y = 0 }; ClientToScreen(h, ref p);
            return new Rectangle(p.X, p.Y, r.Right - r.Left, r.Bottom - r.Top);
        }

        // True if the screen point is on top-level window 'h' itself (not covered by another window).
        public static bool PointIsOn(IntPtr h, int x, int y) {
            IntPtr at = WindowFromPoint(new POINT { X = x, Y = y });
            return at != IntPtr.Zero && GetAncestor(at, 2 /* GA_ROOT */) == h;
        }

        // Physical pixels everywhere, so overlays and window sizes line up on scaled displays.
        public static void MakeDpiAware() {
            try { if (SetProcessDpiAwarenessContext((IntPtr)(-4) /* PER_MONITOR_AWARE_V2 */)) return; } catch { }
            try { SetProcessDPIAware(); } catch { }
        }
    }
}
