// Reads the import table (normal + delay-load) of a PE32/PE32+ file. Used by trim-qemu.ps1
// to find which DLLs qemu-system-x86_64 actually needs. No dependencies.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class PeImports {
    public static List<string> Read(string path) {
        var result = new List<string>();
        byte[] b = File.ReadAllBytes(path);
        int pe = BitConverter.ToInt32(b, 0x3C);
        if (BitConverter.ToUInt32(b, pe) != 0x00004550) throw new Exception("not a PE file: " + path);
        int numSections = BitConverter.ToUInt16(b, pe + 6);
        int optSize = BitConverter.ToUInt16(b, pe + 20);
        int opt = pe + 24;
        bool pe32plus = BitConverter.ToUInt16(b, opt) == 0x20b;
        int dirs = opt + (pe32plus ? 112 : 96);
        int sect = opt + optSize;

        Func<uint, int> rvaToOff = rva => {
            for (int i = 0; i < numSections; i++) {
                int s = sect + i * 40;
                uint va = BitConverter.ToUInt32(b, s + 12), vsz = BitConverter.ToUInt32(b, s + 8);
                uint raw = BitConverter.ToUInt32(b, s + 20), rsz = BitConverter.ToUInt32(b, s + 16);
                if (rva >= va && rva < va + Math.Max(vsz, rsz)) return (int)(rva - va + raw);
            }
            return -1;
        };
        Func<int, string> cstr = off => {
            int e = off; while (e < b.Length && b[e] != 0) e++;
            return Encoding.ASCII.GetString(b, off, e - off);
        };

        // Directory 1 = import table (20-byte descriptors, name RVA at +12)
        uint impRva = BitConverter.ToUInt32(b, dirs + 1 * 8);
        if (impRva != 0) {
            int off = rvaToOff(impRva);
            for (; off >= 0; off += 20) {
                uint nameRva = BitConverter.ToUInt32(b, off + 12);
                if (nameRva == 0) break;
                int n = rvaToOff(nameRva); if (n >= 0) result.Add(cstr(n));
            }
        }
        // Directory 13 = delay-load imports (32-byte descriptors, name RVA at +4)
        uint dlRva = BitConverter.ToUInt32(b, dirs + 13 * 8);
        if (dlRva != 0) {
            int off = rvaToOff(dlRva);
            for (; off >= 0; off += 32) {
                uint nameRva = BitConverter.ToUInt32(b, off + 4);
                if (nameRva == 0) break;
                int n = rvaToOff(nameRva); if (n >= 0) result.Add(cstr(n));
            }
        }
        return result;
    }
}
