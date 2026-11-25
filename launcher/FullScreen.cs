// SlightDroid launcher: full screen for the engine window (the Android Emulator window has no full-screen mode).
// On: the title bar and frame are removed, Android is scaled to fill the screen in its current orientation
// (centred, black bars from a backdrop window behind it), the engine's side toolbar is hidden, and the
// taskbar is covered. While on, Refit() keeps it centred when an app rotates the screen. Off: all restored.
// C# 5 / .NET Framework 4.x.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SlightDroid {
    sealed class FullScreen {
        Form backdrop;
        IntPtr main;
        Native.RECT saved;
        IntPtr savedStyle;
        Rectangle target;
        readonly List<IntPtr> hidden = new List<IntPtr>();

        public bool On { get { return backdrop != null; } }
        public IntPtr Backdrop { get { return backdrop != null ? backdrop.Handle : IntPtr.Zero; } }

        const int GWL_STYLE = -16;
        const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_SYSMENU = 0x00080000, WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000;
        const uint SWP_FRAMECHANGED = 0x0020, SWP_SHOWWINDOW = 0x0040, SWP_NOOWNERZORDER = 0x0200, SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1), HWND_NOTOPMOST = new IntPtr(-2);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

        public void Toggle(IntPtr window, int enginePid) {
            if (On) Exit(); else Enter(window, enginePid);
        }

        void Enter(IntPtr window, int enginePid) {
            if (window == IntPtr.Zero) return;
            main = window;
            if (Native.IsIconic(main)) Native.ShowWindow(main, 9);
            Native.GetWindowRect(main, out saved);
            savedStyle = GetWindowLongPtr(main, GWL_STYLE);
            Rectangle scr = Screen.FromHandle(main).Bounds;           // real pixels (the launcher is DPI-aware)
            Size android = ClientSize(main);                          // current orientation and aspect

            backdrop = new Form { FormBorderStyle = FormBorderStyle.None, BackColor = Color.Black, ShowInTaskbar = false, TopMost = true,
                                  StartPosition = FormStartPosition.Manual, Bounds = scr, Text = "SlightDroid full screen" };
            backdrop.Show();

            // the engine's other windows (side toolbar, extended controls) step aside
            hidden.Clear();
            EnumWindows((h, l) => {
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (pid == enginePid && h != main && Native.IsWindowVisible(h)) { hidden.Add(h); Native.ShowWindow(h, 0); }
                return true;
            }, IntPtr.Zero);

            long style = savedStyle.ToInt64() & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
            SetWindowLongPtr(main, GWL_STYLE, new IntPtr(style));
            Place(scr, android);
            Native.SetForegroundWindow(main);
        }

        static Size ClientSize(IntPtr h) {
            Native.RECT r; Native.GetClientRect(h, out r);
            return new Size(Math.Max(1, r.Right - r.Left), Math.Max(1, r.Bottom - r.Top));
        }

        void Place(Rectangle scr, Size aspect) {
            double k = Math.Min(scr.Width / (double)aspect.Width, scr.Height / (double)aspect.Height);
            int w = (int)(aspect.Width * k), h = (int)(aspect.Height * k);
            target = new Rectangle(scr.X + (scr.Width - w) / 2, scr.Y + (scr.Height - h) / 2, w, h);
            Native.SetWindowPos(main, HWND_TOPMOST, target.X, target.Y, target.Width, target.Height, SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
        }

        // Called about once a second while on: when Android rotates, the engine resizes its window by itself
        // (portrait <-> landscape); fit and centre it again.
        public void Refit() {
            if (!On) return;
            Native.RECT r; if (!Native.GetWindowRect(main, out r)) return;
            var now = new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            if (Math.Abs(now.X - target.X) <= 2 && Math.Abs(now.Y - target.Y) <= 2 && Math.Abs(now.Width - target.Width) <= 2 && Math.Abs(now.Height - target.Height) <= 2) return;
            Place(Screen.FromHandle(main).Bounds, now.Size);
        }

        public void Exit() {
            if (!On) return;
            SetWindowLongPtr(main, GWL_STYLE, savedStyle);
            Native.SetWindowPos(main, HWND_NOTOPMOST, saved.Left, saved.Top, saved.Right - saved.Left, saved.Bottom - saved.Top, SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
            foreach (var h in hidden) Native.ShowWindow(h, 8 /* SW_SHOWNA */);
            hidden.Clear();
            backdrop.Close(); backdrop.Dispose(); backdrop = null;
            Native.SetForegroundWindow(main);
        }
    }
}
