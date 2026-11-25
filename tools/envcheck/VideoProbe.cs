// SlightDroid envcheck: hardware video-decode probe.
// Compiled in memory by envcheck.ps1 via Add-Type (C# 5, .NET Framework). No dependencies.
//
// For every DXGI adapter it creates a D3D11 device, gets ID3D11VideoDevice and, for each
// codec, actually creates a decoder at 1920x1080 and 3840x2160. Creating the decoder is the
// functional test: drivers refuse resolutions/profiles their fixed-function block can't do.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class EmuDecodeResult {
    public string Adapter;
    public uint VendorId;
    public ulong DedicatedVideoMemory;
    public bool Software;
    public int FeatureLevel;                                     // D3D_FEATURE_LEVEL, 0 if no device
    public string Error = "";
    public List<string> Profiles = new List<string>();          // all profile GUIDs the driver lists
    public Dictionary<string, int> MaxHeight = new Dictionary<string, int>(); // codec -> 0 / 1080 / 2160
}

public static class EmuVideoProbe {
    // ---- DXGI ----
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DXGI_ADAPTER_DESC1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public uint LuidLow; public int LuidHigh; public uint Flags;
    }
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

    [DllImport("d3d11.dll")]
    static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags,
        int[] featureLevels, uint numLevels, uint sdkVersion, out IntPtr device, out int featureLevel, out IntPtr context);

    // ---- D3D11 video structs ----
    [StructLayout(LayoutKind.Sequential)]
    struct D3D11_VIDEO_DECODER_DESC { public Guid Guid; public uint SampleWidth, SampleHeight; public int OutputFormat; }

    [StructLayout(LayoutKind.Sequential)]
    struct D3D11_VIDEO_DECODER_CONFIG {
        public Guid guidConfigBitstreamEncryption, guidConfigMBcontrolEncryption, guidConfigResidDiffEncryption;
        public uint ConfigBitstreamRaw, ConfigMBcontrolRasterOrder, ConfigResidDiffHost, ConfigSpatialResid8,
            ConfigResid8Subtraction, ConfigSpatialHost8or9Clipping, ConfigSpatialResidInterleaved,
            ConfigIntraResidUnsigned, ConfigResidDiffAccelerator, ConfigHostInverseScan, ConfigSpecificIDCT,
            Config4GroupedCoefs;
        public ushort ConfigMinRenderTargetBuffCount, ConfigDecoderSpecific;
    }

    // ---- vtable delegates (all stdcall, first arg = this) ----
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int QI(IntPtr self, ref Guid iid, out IntPtr obj);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1(IntPtr self, uint idx, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc1(IntPtr self, out DXGI_ADAPTER_DESC1 desc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint GetProfileCount(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetProfile(IntPtr self, uint idx, out Guid g);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetConfigCount(IntPtr self, ref D3D11_VIDEO_DECODER_DESC d, out uint n);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetConfig(IntPtr self, ref D3D11_VIDEO_DECODER_DESC d, uint idx, out D3D11_VIDEO_DECODER_CONFIG c);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateDecoder(IntPtr self, ref D3D11_VIDEO_DECODER_DESC d, ref D3D11_VIDEO_DECODER_CONFIG c, out IntPtr dec);

    static T VFn<T>(IntPtr obj, int slot) where T : class {
        IntPtr vtbl = Marshal.ReadIntPtr(obj);
        IntPtr fn = Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer(fn, typeof(T)) as T;
    }

    const int DXGI_FORMAT_NV12 = 103, DXGI_FORMAT_P010 = 104;

    // Codec name -> (profile GUID, output format)
    public static readonly string[][] Codecs = {
        new[] { "H.264",        "1b81be68-a0c7-11d3-b984-00c04f2e73c5", "103" },
        new[] { "HEVC Main",    "5b11d51b-2f4c-4452-bcc3-09f2a1160cc0", "103" },
        new[] { "HEVC Main10",  "107af0e0-ef1a-4d19-aba8-67a163073d13", "104" },
        new[] { "VP9",          "463707f8-a1d0-4585-876d-83aa6d60b89e", "103" },
        new[] { "VP9 10-bit",   "a4c749ef-6ecf-48aa-8448-50a7a1165ff7", "104" },
        new[] { "AV1",          "b8be4ccb-cf53-46ba-8d59-d6b8a6da5d2a", "103" },
    };

    static bool TryDecoder(IntPtr vdev, Guid profile, int fmt, uint w, uint h) {
        var desc = new D3D11_VIDEO_DECODER_DESC { Guid = profile, SampleWidth = w, SampleHeight = h, OutputFormat = fmt };
        uint n;
        if (VFn<GetConfigCount>(vdev, 14)(vdev, ref desc, out n) < 0 || n == 0) return false;
        D3D11_VIDEO_DECODER_CONFIG cfg;
        if (VFn<GetConfig>(vdev, 15)(vdev, ref desc, 0, out cfg) < 0) return false;
        IntPtr dec;
        int hr = VFn<CreateDecoder>(vdev, 3)(vdev, ref desc, ref cfg, out dec);
        if (hr < 0 || dec == IntPtr.Zero) return false;
        Marshal.Release(dec);
        return true;
    }

    public static List<EmuDecodeResult> Probe() {
        var results = new List<EmuDecodeResult>();
        Guid iidFactory1 = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        Guid iidVideoDevice = new Guid("10EC4D5B-975A-4689-B9E4-D0AAC30FE333");
        IntPtr factory;
        if (CreateDXGIFactory1(ref iidFactory1, out factory) < 0) return results;
        try {
            for (uint i = 0; ; i++) {
                IntPtr adapter;
                // IDXGIFactory1::EnumAdapters1 = slot 12
                if (VFn<EnumAdapters1>(factory, 12)(factory, i, out adapter) < 0) break;
                var r = new EmuDecodeResult();
                IntPtr dev = IntPtr.Zero, ctx = IntPtr.Zero, vdev = IntPtr.Zero;
                try {
                    DXGI_ADAPTER_DESC1 d;
                    VFn<GetDesc1>(adapter, 10)(adapter, out d);   // IDXGIAdapter1::GetDesc1 = slot 10
                    r.Adapter = d.Description; r.VendorId = d.VendorId;
                    r.DedicatedVideoMemory = d.DedicatedVideoMemory.ToUInt64();
                    r.Software = (d.Flags & 2) != 0;                // DXGI_ADAPTER_FLAG_SOFTWARE
                    if (r.Software) { r.Error = "software adapter"; results.Add(r); continue; }
                    int[] levels = { 0xc100, 0xc000, 0xb100, 0xb000, 0xa100, 0xa000 };
                    int fl;
                    const uint VIDEO_SUPPORT = 0x800;               // D3D11_CREATE_DEVICE_VIDEO_SUPPORT
                    int hr = D3D11CreateDevice(adapter, 0 /* UNKNOWN: adapter given */, IntPtr.Zero, VIDEO_SUPPORT,
                        levels, (uint)levels.Length, 7, out dev, out fl, out ctx);
                    if (hr < 0) { r.Error = string.Format("D3D11CreateDevice hr=0x{0:X8}", hr); results.Add(r); continue; }
                    r.FeatureLevel = fl;
                    hr = VFn<QI>(dev, 0)(dev, ref iidVideoDevice, out vdev);
                    if (hr < 0) { r.Error = string.Format("no ID3D11VideoDevice hr=0x{0:X8}", hr); results.Add(r); continue; }

                    uint count = VFn<GetProfileCount>(vdev, 11)(vdev);
                    var have = new HashSet<Guid>();
                    for (uint p = 0; p < count; p++) {
                        Guid g;
                        if (VFn<GetProfile>(vdev, 12)(vdev, p, out g) >= 0) { have.Add(g); r.Profiles.Add(g.ToString()); }
                    }
                    foreach (var c in Codecs) {
                        var g = new Guid(c[1]); int fmt = int.Parse(c[2]);
                        int max = 0;
                        if (have.Contains(g)) {
                            if (TryDecoder(vdev, g, fmt, 1920, 1088)) max = 1080;
                            if (TryDecoder(vdev, g, fmt, 3840, 2160)) max = 2160;
                        }
                        r.MaxHeight[c[0]] = max;
                    }
                    results.Add(r);
                } catch (Exception e) {
                    r.Error = e.Message; results.Add(r);
                } finally {
                    if (vdev != IntPtr.Zero) Marshal.Release(vdev);
                    if (ctx != IntPtr.Zero) Marshal.Release(ctx);
                    if (dev != IntPtr.Zero) Marshal.Release(dev);
                    Marshal.Release(adapter);
                }
            }
        } finally { Marshal.Release(factory); }
        return results;
    }
}
