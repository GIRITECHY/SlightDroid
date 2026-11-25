// SlightDroid launcher: user settings (%LOCALAPPDATA%\SlightDroid\settings.ini) and display math.
// C# 5 / .NET Framework 4.x.
using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Windows.Forms;

namespace SlightDroid {
    public sealed class Config {
        public const int MinStorageGB = 50;

        public int RamMB = 0, Cpus = 0;         // 0 = auto: chosen from this PC (EffectiveRamMB / EffectiveCpus)
        public string Gpu = "virgl";            // virgl (GPU accelerated) | std (compatibility, no 3D)
        public string Accel = "whpx";
        public int StorageGB = MinStorageGB;    // virtual size of the Android data disk (grows, never shrinks)
        public string Resolution = "auto";      // auto | WxH
        public int Dpi = 0;                     // 0 = auto
        public string Window = "fit";           // fit | actual | fullscreen
        public bool DragDrop = true;            // drop overlay on the Android window

        public static Config Load(string path) {
            var c = new Config();
            if (!File.Exists(path)) { c.Save(path); return c; }
            foreach (var raw in File.ReadAllLines(path)) {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || !line.Contains("=")) continue;
                var k = line.Substring(0, line.IndexOf('=')).Trim().ToLowerInvariant();
                var v = line.Substring(line.IndexOf('=') + 1).Trim();
                int n;
                switch (k) {
                    case "ram_mb": c.RamMB = int.TryParse(v, out n) ? Math.Max(MinRamMB, Math.Min(MaxRamMB, n)) : 0; break;
                    case "cpus": c.Cpus = int.TryParse(v, out n) ? Math.Max(1, Math.Min(8, n)) : 0; break;
                    case "gpu": c.Gpu = v == "std" ? "std" : "virgl"; break;
                    case "accel": c.Accel = v; break;
                    case "storage_gb": if (int.TryParse(v, out n)) c.StorageGB = Math.Max(MinStorageGB, Math.Min(2048, n)); break;
                    case "resolution": c.Resolution = ParseRes(v) != Size.Empty ? v.ToLowerInvariant() : "auto"; break;
                    case "dpi": if (int.TryParse(v, out n)) c.Dpi = (n >= 100 && n <= 640) ? n : 0; break;
                    case "window": c.Window = (v == "actual" || v == "fullscreen") ? v : "fit"; break;
                    case "drag_drop": c.DragDrop = v != "off" && v != "0" && v != "false"; break;
                }
            }
            return c;
        }

        public void Save(string path) {
            File.WriteAllText(path,
                "# SlightDroid settings. Use the Settings window (SlightDroid > Settings) or edit here;\r\n" +
                "# changes apply the next time Android starts.\r\n" +
                "ram_mb=" + (RamMB > 0 ? RamMB.ToString() : "auto") + "\r\n" +
                "cpus=" + (Cpus > 0 ? Cpus.ToString() : "auto") + "\r\n" +
                "gpu=" + Gpu + "\r\n" +
                "accel=" + Accel + "\r\n" +
                "storage_gb=" + StorageGB + "\r\n" +
                "resolution=" + Resolution + "\r\n" +
                "dpi=" + Dpi + "\r\n" +
                "window=" + Window + "\r\n" +
                "drag_drop=" + (DragDrop ? "on" : "off") + "\r\n");
        }

        // Android 11 (64-bit) image: 1 GB is the practical minimum, more than 4 GB brings apps nothing.
        public const int MinRamMB = 1024, MaxRamMB = 4096;
        // What the engine itself needs on top of Android's memory (graphics translator, UI, buffers; measured
        // ~0.9 GB with a 2 GB Android on the dev PC) and what Windows keeps free for itself.
        const int EngineOverheadMB = 700, WindowsHeadroomMB = 512;

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        class MEMORYSTATUSEX { public uint dwLength = 64, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual; }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([System.Runtime.InteropServices.In, System.Runtime.InteropServices.Out] MEMORYSTATUSEX m);

        public static long HostRamMB() { var m = new MEMORYSTATUSEX(); return GlobalMemoryStatusEx(m) ? (long)(m.ullTotalPhys >> 20) : 4096; }
        public static long HostAvailMB() { var m = new MEMORYSTATUSEX(); return GlobalMemoryStatusEx(m) ? (long)(m.ullAvailPhys >> 20) : 2048; }

        // auto: share the PC with Windows. Android gets what is free right now minus the engine's own needs and
        // a reserve for Windows, but never more than half of the PC's memory. Examples: 4 GB PC with 2.5 GB free
        // -> 1280 MB; 8 GB PC with 5 GB free -> 3840 MB; 16 GB PC -> 4096 MB. Never below 1024 MB.
        public static int AutoRamMB(long hostMB) {
            long r = Math.Min(hostMB / 2, HostAvailMB() - WindowsHeadroomMB - EngineOverheadMB);
            r = Math.Max(MinRamMB, Math.Min(MaxRamMB, r));
            return (int)(r / 256 * 256);
        }

        // auto: half of the PC's processor threads (Windows keeps the other half), at least 2, at most 8
        public static int AutoCpus() { return Math.Max(2, Math.Min(8, Environment.ProcessorCount / 2)); }

        public int EffectiveRamMB() { return RamMB > 0 ? RamMB : AutoRamMB(HostRamMB()); }
        public int EffectiveCpus() { return Cpus > 0 ? Cpus : AutoCpus(); }

        // A real graphics card/chip (not the "Microsoft Basic Display Adapter" fallback driver): then GPU
        // acceleration is used, otherwise Android renders on the CPU.
        static bool? hwGpu;
        public static bool HasHardwareGpu() {
            if (hwGpu.HasValue) return hwGpu.Value;
            bool any = false;
            try {
                using (var q = new System.Management.ManagementObjectSearcher("SELECT Name, PNPDeviceID FROM Win32_VideoController"))
                    foreach (System.Management.ManagementObject o in q.Get()) {
                        string n = Convert.ToString(o["Name"]) ?? "", id = Convert.ToString(o["PNPDeviceID"]) ?? "";
                        if (n.IndexOf("Basic Display", StringComparison.OrdinalIgnoreCase) < 0 && n.IndexOf("Basic Render", StringComparison.OrdinalIgnoreCase) < 0 && id.StartsWith("PCI\\", StringComparison.OrdinalIgnoreCase)) any = true;
                    }
            } catch { any = true; }   // can't tell: try the GPU (the engine falls back by itself if it has to)
            hwGpu = any; return any;
        }
        public static Size ParseRes(string v) {
            if (v == null) return Size.Empty;
            var p = v.ToLowerInvariant().Split('x');
            int w, h;
            if (p.Length == 2 && int.TryParse(p[0], out w) && int.TryParse(p[1], out h) && w >= 480 && h >= 480 && w <= 3840 && h <= 3840)
                return new Size(w & ~7, h & ~7);   // multiples of 8 keep the GPU path happy
            return Size.Empty;
        }

        // Space the Android window may use on the primary screen, in physical pixels
        // (the launcher is DPI-aware): 92 % of the work area minus a title bar.
        public static Size AvailableClient() {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            return new Size((int)(wa.Width * 0.92), (int)(wa.Height * 0.92) - 40);
        }

        // Android display resolution actually used.
        // auto: landscape, with the same shape as the monitor (so full screen fills it edge to edge), as large as
        // fits the window space but at most 800 lines with a GPU (1080 made WebView video players stutter, tested
        // 2026-11-19 with NetMirror; choose more in Settings for sharpness) or 720 lines when Android renders on
        // the CPU (fluid). Multiples of 8 keep the graphics path happy.
        public Size EffectiveResolution() {
            Size s = ParseRes(Resolution);
            if (s != Size.Empty) return s;
            Rectangle scr = Screen.PrimaryScreen.Bounds;
            double aspect = Math.Max(1.25, Math.Min(2.4, scr.Width / (double)Math.Max(1, scr.Height)));
            Size avail = AvailableClient();
            int maxH = HasHardwareGpu() && Gpu != "std" ? 800 : 720;   // 800 lines: video in apps (WebView players) stays smooth; up to 1080 in Settings
            int h = (int)Math.Min(maxH, Math.Min(avail.Height, avail.Width / aspect));
            h = Math.Max(540, h) & ~7;
            int w = ((int)(h * aspect)) & ~7;
            return new Size(w, h);
        }
        // Android density (dpi) actually used. auto: phones (portrait) get a 360 dp wide layout,
        // landscape screens a tablet-style layout.
        public int EffectiveDpi() {
            if (Dpi > 0) return Dpi;
            Size s = EffectiveResolution();
            int shortSide = Math.Min(s.Width, s.Height);
            if (s.Height > s.Width) return Math.Max(160, shortSide * 160 / 360);
            if (shortSide <= 800) return 160;
            if (shortSide <= 1080) return 213;
            return 240;
        }

        public static string Describe(Size s) { return s.Width + " x " + s.Height; }

        public static string Inv(double d) { return d.ToString("0.0", CultureInfo.InvariantCulture); }
    }
}
