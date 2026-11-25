# SlightDroid: plan for low-end PCs

Target: **4 GB RAM, Intel Pentium, integrated graphics, often an HDD or eMMC disk.**
The dev PC (Ryzen 7, 16 GB, RTX 4050) is only where we build. It is never the benchmark.

Status: approved 2026-11-18, with these decisions:
- **DECISION 1 (engine):** spike both (M1.5), then decide with numbers.
- **DECISION 2 (Lite guest):** Android 11 Go, falling back to Android 9 if it misses the budgets.
- **DECISION 3 (accelerator):** measure WHPX vs AEHD in the spike.
- **Delivery:** one offline `SlightDroid-Setup.exe` that you share and install on another PC.
  Nothing is installed on the dev PC (section 7).
- **Test hardware:** no real Pentium yet. Until there is one, dev-PC runs use proxy limits,
  and every number is labelled "proxy".

---

## 1. Reference hardware

"Intel Pentium" covers 15 years of very different chips, so we define tiers:

| Tier | Examples | iGPU | VM support | Video decode in hardware |
|---|---|---|---|---|
| **A: main target** | Pentium Silver N5000/N5030/N6000, Pentium Gold G5400/G6400/G7400 (2018+) | UHD 605/610/710 | VT-x + EPT | H.264 up to 4K, HEVC 8/10-bit 4K, VP9 4K. No AV1 (except Gold G7400 / Alder Lake-N) |
| **B: supported** | Pentium N3540/N3710, G3xxx/G4xxx (2013-2017) | HD Graphics | VT-x + EPT | H.264 1080p. HEVC/VP9 only on Skylake+ (G4400), and partly in software |
| **C: unsupported** | Pentium 4/D, Pentium E/G6xxx before 2010 | | no VT-x or no EPT | |

Typical host: 2 cores (some 2C/4T or 4C/4T), no AVX on most, Windows 10 22H2 or
Windows 11 Home, a 1366x768 or 1080p screen, a 5400 rpm HDD or 64 GB eMMC.

**The 4K rule:** 4K playback only works when the host iGPU decodes that codec in
hardware. A Pentium cannot decode 4K in software, whether inside a VM or not. SlightDroid will
detect this and tell the user instead of stuttering.

## 2. Budgets (on a Tier A Pentium, 4 GB)

| Item | Budget | Note |
|---|---|---|
| Windows 10 idle | ~1.6-2.0 GB | not ours, but it decides what is left |
| Guest RAM (Lite) | 1024 MB assigned, **≤ 700 MB resident at idle** | needs working balloon or free-page reporting on a Windows host (see risk R3) |
| Engine process, excluding guest RAM | ≤ 100 MB | |
| GPU driver + ANGLE | ≤ 50 MB | |
| Frontend | ≤ 30 MB | |
| **Host-side total, excluding guest** | **≤ 150 MB** | your requirement |
| Host CPU at idle (home screen) | ≤ 5 % | no polling; redraw only on damage |
| Cold boot | ≤ 40 s on SSD, ≤ 70 s on HDD | |
| Snapshot boot | ≤ 10 s on SSD, ≤ 15 s on HDD | 10 s on a 5400 rpm HDD may be physically impossible; we measure and report |
| Launcher / scrolling | 60 fps at 720p | |
| Casual 2D game | stable ≥ 30 fps | |
| Video 1080p30 H.264 | < 0.5 % dropped frames, host CPU ≤ 35 % | all tiers |
| Video 4K30 HEVC / VP9 | < 1 % dropped frames, host CPU ≤ 50 % | Tier A only |
| 50 MB APK install | ≤ 30 s | |

Every milestone from M2 on runs the same benchmark script, and a milestone fails if it
regresses a budget. Optimization is not saved for the end.

## 3. Key findings that change the architecture

1. **Upstream QEMU has no AEHD backend.** AEHD only runs with Google's Android Emulator
   (a QEMU fork). A 2023 patch series proposed AEHD for upstream QEMU, but I could not
   confirm it was merged. With upstream QEMU, "AEHD fallback" means porting that backend
   ourselves. (My M1 report printed `-accel aehd`; that flag doesn't exist upstream.)
2. **AEHD matters more on low-end PCs than on the dev PC.** Many Pentium machines run
   Windows 10 with no hypervisor active. With AEHD, the whole Windows host does not have to
   run as a Hyper-V root partition. Whether AEHD or WHPX is faster on a Pentium must be
   **measured**, not assumed.
3. **4K video needs host-side hardware decoding with zero-copy display.** One decoded 4K
   frame is 12 MB, so 30 fps is 360 MB/s. Copying that into guest RAM and back out
   through virtio-gpu would saturate a Pentium. Instead the compressed stream must go to the
   host, be decoded by the iGPU (D3D11 video decoding, DXVA), and stay on the GPU as a texture
   that the compositor draws directly. Upstream QEMU with virglrenderer has no such
   path on Windows; virgl's video decode uses VA-API, which is Linux-only.
   The Android Emulator already has host-side H.264/VP8/VP9 decode with output into host
   colour buffers. Its documented host backends are ffmpeg, VideoToolbox (macOS) and
   CUDA (NVIDIA). **A D3D11VA/DXVA backend for Intel iGPUs is not documented**, so we would
   have to add it.
4. **KSM does not exist on Windows hosts.** It's a Linux host feature, so I'm dropping it.
   With one instance it would save almost nothing anyway.
5. **Android 11 "Go" may suit 1 GB better than Android 9.** Google built Go for 1 GB phones:
   `ro.config.low_ram`, smaller heaps and caches, and a 32-bit userspace. It also raises
   app compatibility from API 28 to API 30. More 2026 apps need API 29+.

### DECISION 1: VM engine

| | A: upstream QEMU + Android-x86 / BlissOS (current plan) | **B: Android Emulator engine (AOSP QEMU fork) + AOSP-built images (recommended)** |
|---|---|---|
| WHPX | yes | yes |
| AEHD | no, must port | yes |
| GPU on Windows | virgl via SDL/ANGLE; limited | gfxstream + ANGLE (D3D11), mature on Windows |
| Host video decode | none on Windows → 4K impossible | H.264/VPx host decode exists; we add D3D11VA for Intel |
| Fast snapshot boot | eager `loadvm` (reads all RAM) | Quickboot snapshots, RAM loaded on demand (verify on Windows) |
| Guest images | prebuilt Android-x86 9 ISO, quick to start | must build AOSP ourselves (needs Linux/WSL2, ~250 GB disk, several hours per build) |
| Codebase | smaller, upstream | large; we strip its Qt UI and drive it from our frontend |
| License | GPL-2.0 | GPL-2.0 (QEMU parts) + Apache-2.0 (android-emu, gfxstream) |

Both are QEMU, so the "QEMU" rule holds either way. B is the only option that already
covers AEHD, Windows GPU acceleration and host video decode, and those are exactly the
new requirements. Its cost is the AOSP build pipeline. **Recommendation: a one-week
spike (M1.5) boots both on proxy constraints and decides with numbers.**

### DECISION 2: Lite guest

- **Recommended:** Android 11 Go configuration, x86 32-bit userspace, 1 GB.
- **Fallback:** Android 9 x86, 1 GB, if Android 11 Go misses the RAM or boot budget.
- **Standard** (Android 13 x86_64, 2 GB) stays, but only for 6 GB+ hosts. It moves after
  the video work, because it isn't the target.

### DECISION 3: accelerator order

Rule: use whichever of WHPX and AEHD wins the M1.5 benchmark on a Pentium when both are
available; if only one is available, use that. If the Windows hypervisor is already on
(VBS/Memory Integrity on Windows 11), only WHPX can be used.

## 4. Video pipeline (for VLC, MX Player, ExoPlayer-based apps)

```
Guest (Android)                               Host (Windows)
 VLC / player
   │ MediaCodec (hardware decoding, VLC's default)
   ▼
 Codec2 decoder "c2.slightdroid.{avc,hevc,vp9,av1}"
   │ compressed packets only (KB, not MB)
   ▼   virtio / goldfish pipe ─────────────────► decoder service in engine process
                                                   │ D3D11VA (iGPU fixed-function decode)
                                                   ▼
                                                 NV12 D3D11 texture
                                                   │ shared to ANGLE as EGLImage (no copy)
 gralloc buffer handle ◄── refers to ─────────── host colour buffer
 SurfaceFlinger composites ────────────────────► ANGLE/D3D11 draws, scales to window, presents
```

- No decoded pixel enters guest RAM, so the guest needs almost no extra memory or CPU for
  video. That is the only way 4K fits in 4 GB on a Pentium.
- **Fallbacks:** if the iGPU lacks the codec, decode in software in the host process
  (ffmpeg LGPL build, dav1d for AV1). This is faster than decoding inside the guest, with
  no VM-exit overhead and the full host instruction set. We target 1080p30, with 4K
  reported as unsupported.
- **Codec capability:** the guest advertises only the codec/resolution pairs that the host
  iGPU can really decode. Then VLC and other players choose correctly on their own, for
  example by picking a lower-resolution stream.
- **A/V sync:** audio clock is the master. Use the lowest-latency audio device the guest
  kernel supports; check virtio-snd vs emulated HDA at M7.
- **Out of scope:** DRM (Widevine L1) streaming apps. Their protected-path requirements
  can't be met in an emulator.
- **Legal flag:** H.264/HEVC are patent-encumbered. Decoding in the Windows GPU driver
  through DXVA uses the OS/driver's licence. Shipping ffmpeg's software HEVC decoder may
  raise patent questions in some countries. I'm not a lawyer, so this needs review before
  release.

## 5. Optimization techniques, by layer

**Host / engine**
- Guest RAM is reserved but committed lazily. Free guest pages are returned to Windows
  through balloon / free-page reporting, using `DiscardVirtualMemory` / `MEM_RESET`
  (verify whether QEMU does this on Windows; patch if not, risk R3).
- Redraw only on damage, so there is no 60 Hz loop while the screen is still. Cap the
  frame rate at the display rate, and offer a 30 fps cap in battery/low mode.
- Pin rendering to the iGPU, so hybrid laptops don't wake a dGPU.
- vCPU count: 2 by default, 1 on 2-thread hosts if benchmarks show it helps.
- Disk: a read-only compressed base image plus a qcow2 overlay. Measure compressed vs raw
  system images on HDD, where compression usually wins, and on SSD.
- Snapshot: drop guest caches and compact before saving, and skip zero pages.
- Frontend: native Win32 window through Rust (`windows` crate) or a slim C++ build, no Qt
  if we can avoid it: about 10-30 MB instead of 60+ MB.

**Guest**
- `ro.config.low_ram=true` and Go defaults: dalvik heapgrowthlimit 128m, lmkd tuned with
  PSI, zram at 50-75 % of RAM with lz4.
- Pre-compiled boot image, system apps compiled with `speed-profile` at build time, and
  `dex2oat` limited to 1 thread so installs don't freeze the UI.
- Remove: preinstalled apps, live wallpaper, telephony/NFC/print/backup/sync services,
  the bluetooth stack, location providers and most animations.
- Kernel: virtio-only drivers, tickless idle, the best clocksource the accelerator offers
  (avoid HPET exits), no debug options.
- Display density and resolution follow the window: 720p by default on Tier B, 1080p when
  the window is 1080p.

## 6. Testing without a Pentium

The dev PC can't be a Pentium. Plan:
1. **Proxy runs on the dev PC** (only for fast iteration, never for published numbers):
   the engine is pinned to 2 logical CPUs, a RAM-pressure tool leaves ~2 GB free, and the
   iGPU is forced. On this PC only WHPX can be tested, because VBS is on.
2. **Real numbers come from a real Tier A Pentium 4 GB machine.** README benchmarks will
   show only real-hardware numbers, each labelled with the exact CPU, RAM and disk.
3. Test media: open-licensed clips (Blender open movies, CC-BY) encoded by us in H.264,
   HEVC, VP9 and AV1 at 720p, 1080p and 4K, at 30 and 60 fps.

## 7. Delivery: a standalone installer (decided 2026-11-18)

SlightDroid ships as **one offline `SlightDroid-Setup.exe`**. You copy it to another PC and press
Install, like BlueStacks. **Nothing is installed on the dev PC.** Here we only download,
build and run portable test processes from inside the project folder: no Windows
features, no drivers and no registry changes.

**What Setup does on the target PC**
1. Welcome and licences (GPL notice with a source offer).
2. Runs the bundled envcheck silently and shows a one-screen summary. It stops with the
   matching guide on hard failures: no VT-x/EPT, 32-bit Windows, under ~3.5 GB RAM, no SSE4.2.
3. If no accelerator is enabled but WHPX can be: asks "SlightDroid needs Windows Hypervisor
   Platform. Enable it and restart?", then enables the feature and resumes after the
   reboot. It records that *it* turned WHPX on, so the uninstaller can offer to turn it off.
4. Copies the engine to `C:\Program Files\SlightDroid`. User data (disk overlay, snapshot,
   settings) goes to `%LOCALAPPDATA%\SlightDroid`.
5. Creates Start menu and desktop shortcuts, registers `.apk` files ("Open with SlightDroid"
   installs the app), and adds an uninstaller and a "SlightDroid diagnostics" shortcut.
6. First launch creates the qcow2 overlay, boots Android and saves a quick-boot snapshot.

**Diagnostics loop (no Pentium here):** the "SlightDroid diagnostics" shortcut collects envcheck JSON,
boot time, RAM, CPU and video-test results into one zip on the Desktop. You send it back,
and those become the real benchmark numbers.

**Constraints this creates**
- **Only redistributable parts can go in Setup.** Engine A (upstream QEMU, GPL) and the
  open guests (Android-x86, BlissOS FOSS) can ship today. Google's prebuilt emulator,
  system images and adb **cannot**. Shipping engine B means building the emulator and the
  Android images from AOSP source ourselves. So **installer v0.1 ships engine A**. Engine B
  becomes a later track, and only if the spike shows a large win (mainly for video).
- **Installer tool: NSIS 3.13**, portable zip, zlib licence. Inno Setup has no portable
  version and would have to be installed here. NSIS limits installer data to 2 GB, so the
  Lite payload target is **≤ 1.2 GB**. A bigger Standard profile would need a second data
  file next to Setup.
- **Code signing:** an unsigned Setup shows "Windows protected your PC" (SmartScreen) on
  the target PC (click More info > Run anyway). Removing that needs a paid code-signing
  certificate, which is your call before any public release.
- **adb inside the product:** Google's adb.exe can't be shipped. The launcher will speak
  the ADB protocol itself over local TCP (small, and no extra adb server process eating
  RAM), or we build adb from AOSP source.
- **Launcher before the real frontend:** a tiny native Windows launcher compiled with
  the C# compiler that is part of every Windows 10/11 (.NET Framework 4.8). Nothing extra
  to install on either PC. The full frontend (M7) stays native, per the architecture.

## 7b. Revised milestones

| # | Milestone | Exit criteria |
|---|---|---|
| 1 | Environment check | done (v0.2): tiers, accelerators, pagefile, disk type, hardware video-decode probe |
| 1.5 | Engine spike (portable, dev PC, proxy limits) | A and B boot with 1 GB guest RAM and 2 vCPUs; boot, idle RAM and idle CPU table; engine decision made with data |
| 2 | Lite boot, scripted, portable | Android boots from the project folder; ADB connects; proxy numbers recorded |
| 3 | **Installer v0.1 alpha** | `SlightDroid-Setup.exe` ≤ 1.2 GB: envcheck gate, WHPX enable + resume, shortcuts, launcher, `.apk` association, diagnostics zip, clean uninstall. You run it on the Pentium PC; **first real numbers** |
| 4 | APK install + launch | `.apk` double-click installs and launches; install-time budget met |
| 5 | GPU acceleration | launcher 60 fps at 720p; casual 2D game ≥ 30 fps stable |
| 6 | Video playback | VLC plays 1080p H.264 (Tier A/B) and 4K HEVC/VP9 (Tier A) within budget; unsupported formats reported |
| 7 | Frontend | native window, drag-and-drop APK, start/stop, settings; ≤ 30 MB |
| 8 | Input + audio | keyboard/mouse to touch, gamepad, rotation, audio, A/V sync |
| 9 | Snapshots, ARM translation (licensing decision), installer v1.0 | snapshot-boot budget met; signed installer if you get a certificate |
| 10 | Standard profile (Android 13, 6 GB+ hosts) | boots with the same benchmarks |
| 11 | Optimization pass | top 3 bottlenecks fixed from real-hardware profiles; full table published |

Every installer build after M3 is tested the same way: you run it on the target PC and
send back the diagnostics zip.

## 7c. Pinned inputs (tools/fetch/deps.json; fetched by tools/fetch/fetch-deps.ps1)

The table below was the first proposal. deps.json is now the source of truth. It adds NSIS
3.13 (installer builder) and 7-Zip 26.06 (msi, unpacked without installing, to extract the
ISOs and the QEMU installer). Each entry is marked ship / dev / spike.

| # | File | Source | Size | Licence / use |
|---|---|---|---|---|
| 1 | `qemu-w64-setup-20260811.exe` (engine A) | qemu.weilnetz.de/w64 | 197 MB | GPL-2.0 |
| 2 | `Bliss-v14.10.3-x86_64-OFFICIAL-foss-20241012.iso` (Android 11, engine A) | SourceForge blissos-x86 | 2.0 GB | Apache-2.0 / GPL-2.0 |
| 3 | `android-x86-9.0-r2.iso` (Android 9 x86, Lite fallback) | SourceForge android-x86 | 761 MB | Apache-2.0 / GPL-2.0 |
| 4 | `emulator-windows_x64-16740729.zip` (Android Emulator 37.2.13 stable, engine B) | dl.google.com | 434 MB | Android SDK licence: spike only, not shippable |
| 5 | `x86_64-30_r11.zip` (Android 11 AOSP image, engine B) | dl.google.com | 645 MB | Android SDK licence: spike only; shipped images come from our own AOSP build |
| 6 | `platform-tools_r37.0.3-win.zip` (adb) | dl.google.com | 7.8 MB | Android SDK licence: dev use |

Total about 4.0 GB. Google no longer publishes a 32-bit x86 Android 11 image, so engine B
is tested with x86_64 and the 32-bit Go build comes from AOSP later. AEHD can't be tested
on the dev PC (VBS is on), so WHPX vs AEHD needs the real Pentium.

## 8. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | AOSP build needs a big Linux machine; the dev PC has 16 GB RAM | WSL2 with large swap, or a rented Linux build VM (your call, costs money) |
| R2 | No AV1 hardware decode on most Pentiums | host software decode with dav1d at ≤ 1080p; tell the user |
| R3 | Balloon / free-page reporting may not return memory on a Windows host | measure in M1.5; patch the engine to use `DiscardVirtualMemory` |
| R4 | HDD boot time | on-demand snapshot loading; compressed images |
| R5 | ARM translation can't be bundled (licence) | see LICENSES.md; decide at M8 |
| R6 | 2-thread Pentium: vCPUs and host compete | 1 vs 2 vCPU benchmark; host decode keeps video off guest vCPUs |
| R7 | Windows 10 is out of support but common on these PCs | support Windows 10 22H2 and 11; test both |
