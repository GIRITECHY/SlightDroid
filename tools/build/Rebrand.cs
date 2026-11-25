// SlightDroid build helper: rebrands an exe's Windows resources (used for the QEMU engine binary).
//   - replaces all icons with SlightDroid.ico
//   - replaces the version info (Task Manager / Properties show "SlightDroid engine (based on QEMU ...)")
//   - replaces the application manifest (DPI aware, so Windows does not bitmap-stretch the window)
// Only resources change; the code is untouched (the GPL source offer still covers it).
// C# 5, compiled in memory by trim-qemu.ps1 via Add-Type. Uses kernel32 resource APIs only.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class Rebrand {
    const int RT_ICON = 3, RT_GROUP_ICON = 14, RT_VERSION = 16, RT_MANIFEST = 24;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool EndUpdateResource(IntPtr h, bool discard);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string file, IntPtr f, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr h);
    delegate bool EnumNameProc(IntPtr mod, IntPtr type, IntPtr name, IntPtr param);
    delegate bool EnumLangProc(IntPtr mod, IntPtr type, IntPtr name, ushort lang, IntPtr param);
    [DllImport("kernel32.dll")] static extern bool EnumResourceNames(IntPtr mod, IntPtr type, EnumNameProc cb, IntPtr p);
    [DllImport("kernel32.dll")] static extern bool EnumResourceLanguages(IntPtr mod, IntPtr type, IntPtr name, EnumLangProc cb, IntPtr p);

    struct Res { public int Type; public IntPtr Name; public string NameStr; public ushort Lang; }

    // existing resources of the given types (names can be strings or integer ids)
    static List<Res> Existing(string file, int[] types) {
        var list = new List<Res>();
        IntPtr mod = LoadLibraryEx(file, IntPtr.Zero, 0x2 /* LOAD_LIBRARY_AS_DATAFILE */);
        if (mod == IntPtr.Zero) throw new Exception("cannot open " + file);
        try {
            foreach (int t in types) {
                EnumResourceNames(mod, (IntPtr)t, (m, ty, name, p) => {
                    bool isId = ((long)name >> 16) == 0;
                    string ns = isId ? null : Marshal.PtrToStringUni(name);
                    IntPtr nameCopy = name;
                    EnumResourceLanguages(m, ty, name, (m2, t2, n2, lang, p2) => {
                        list.Add(new Res { Type = t, Name = isId ? nameCopy : IntPtr.Zero, NameStr = ns, Lang = lang });
                        return true;
                    }, IntPtr.Zero);
                    return true;
                }, IntPtr.Zero);
            }
        } finally { FreeLibrary(mod); }
        return list;
    }

    static void Check(bool ok, string what) { if (!ok) throw new Exception(what + " failed, error " + Marshal.GetLastWin32Error()); }

    public static void Apply(string exe, string ico, Dictionary<string, string> strings, string fileVersion, string manifest) {
        var old = Existing(exe, new[] { RT_ICON, RT_GROUP_ICON, RT_VERSION, RT_MANIFEST });
        IntPtr h = BeginUpdateResource(exe, false);
        Check(h != IntPtr.Zero, "BeginUpdateResource");
        bool done = false;
        try {
            foreach (var r in old) {                                   // delete the old ones
                IntPtr name = r.NameStr != null ? Marshal.StringToHGlobalUni(r.NameStr) : r.Name;
                try { Check(UpdateResource(h, (IntPtr)r.Type, name, r.Lang, null, 0), "delete resource"); }
                finally { if (r.NameStr != null) Marshal.FreeHGlobal(name); }
            }
            // icons: .ico file -> RT_ICON entries + one RT_GROUP_ICON (id 1)
            byte[] f = File.ReadAllBytes(ico);
            int count = BitConverter.ToUInt16(f, 4);
            var grp = new MemoryStream(); var gw = new BinaryWriter(grp);
            gw.Write((ushort)0); gw.Write((ushort)1); gw.Write((ushort)count);
            for (int i = 0; i < count; i++) {
                int o = 6 + 16 * i;
                int size = BitConverter.ToInt32(f, o + 8), off = BitConverter.ToInt32(f, o + 12);
                var img = new byte[size]; Buffer.BlockCopy(f, off, img, 0, size);
                Check(UpdateResource(h, (IntPtr)RT_ICON, (IntPtr)(i + 1), 1033, img, (uint)size), "add icon");
                gw.Write(f, o, 12);                                     // w, h, colors, reserved, planes, bitcount, bytes
                gw.Write((ushort)(i + 1));                              // resource id instead of file offset
            }
            var g = grp.ToArray();
            Check(UpdateResource(h, (IntPtr)RT_GROUP_ICON, (IntPtr)1, 1033, g, (uint)g.Length), "add icon group");
            var ver = VersionInfo(fileVersion, strings);
            Check(UpdateResource(h, (IntPtr)RT_VERSION, (IntPtr)1, 1033, ver, (uint)ver.Length), "add version");
            var man = Encoding.UTF8.GetBytes(manifest);
            Check(UpdateResource(h, (IntPtr)RT_MANIFEST, (IntPtr)1, 1033, man, (uint)man.Length), "add manifest");
            done = true;
        } finally { Check(EndUpdateResource(h, !done), "EndUpdateResource"); }
    }

    // ---- VS_VERSIONINFO builder ----
    static void Pad(BinaryWriter w) { while (w.BaseStream.Position % 4 != 0) w.Write((byte)0); }

    // node = WORD len, WORD valueLen, WORD type, WCHAR key[], pad, value, pad, children
    static byte[] Node(string key, byte[] value, bool text, int valueLen, params byte[][] children) {
        var ms = new MemoryStream(); var w = new BinaryWriter(ms);
        w.Write((ushort)0); w.Write((ushort)valueLen); w.Write((ushort)(text ? 1 : 0));
        w.Write(Encoding.Unicode.GetBytes(key + "\0")); Pad(w);
        if (value != null) { w.Write(value); Pad(w); }
        foreach (var c in children) { w.Write(c); Pad(w); }
        var b = ms.ToArray();
        BitConverter.GetBytes((ushort)b.Length).CopyTo(b, 0);
        return b;
    }

    static byte[] VersionInfo(string version, Dictionary<string, string> strings) {
        var parts = (version + ".0.0.0").Split('.');
        uint ms = (uint.Parse(parts[0]) << 16) | uint.Parse(parts[1]), ls = (uint.Parse(parts[2]) << 16) | uint.Parse(parts[3]);
        var fixedInfo = new MemoryStream(); var fw = new BinaryWriter(fixedInfo);
        fw.Write(0xFEEF04BDu); fw.Write(0x00010000u); fw.Write(ms); fw.Write(ls); fw.Write(ms); fw.Write(ls);
        fw.Write(0x3Fu); fw.Write(0u); fw.Write(0x40004u /* VOS_NT_WINDOWS32 */); fw.Write(1u /* VFT_APP */); fw.Write(0u); fw.Write(0u); fw.Write(0u);
        var strs = new List<byte[]>();
        foreach (var kv in strings) {
            var val = Encoding.Unicode.GetBytes(kv.Value + "\0");
            strs.Add(Node(kv.Key, val, true, kv.Value.Length + 1));
        }
        var table = Node("040904b0", null, true, 0, strs.ToArray());
        var sfi = Node("StringFileInfo", null, true, 0, table);
        var trans = Node("Translation", BitConverter.GetBytes(0x04b00409u), false, 4);
        var vfi = Node("VarFileInfo", null, true, 0, trans);
        return Node("VS_VERSION_INFO", fixedInfo.ToArray(), false, 52, sfi, vfi);
    }
}
