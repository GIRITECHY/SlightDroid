# Dependency licenses

Rule for this project: bundle only components we may legally redistribute. Every row below
must be re-verified against the actual source/binary we ship before release (M8).
"Verify" means: not yet checked against the exact version we will use.

| Component | Used for | License | Redistributable? | Notes |
|---|---|---|---|---|
| SlightDroid source (this repo) | launcher, tools, installer script | MIT (see LICENSE) | yes | no third-party binaries, APKs or Android images are committed (see .gitignore) |
| QEMU | VM engine | GPL-2.0 (parts LGPL-2.1 / BSD / MIT) | yes, with source | must ship or offer the exact corresponding source with binaries. SlightDroid ships `qemu-system-x86_64w.exe` renamed to `SlightDroid-engine.exe` with replaced Windows resources only (icon, version text "based on QEMU", DPI manifest; code unchanged) |
| WHPX (`WinHvPlatform.dll`) | accelerator | Windows component | not shipped | user enables the Windows feature; we only call it |
| AEHD | fallback accelerator | GPL-2.0 (derived from KVM), verify | yes, with source; driver is Google-signed | we would ship Google's signed release unmodified; no custom driver in this phase |
| Android-x86 9 (Lite base) | guest OS | Apache-2.0 (AOSP userspace), GPL-2.0 (kernel), others | yes, with GPL source for kernel/GPL parts | verify per-project licences in the tree |
| BlissOS / Android-Generic 11/13 (Standard base) | guest OS | Apache-2.0 + GPL-2.0 kernel, verify | yes, with GPL source | strip GApps; check bundled firmware blobs |
| virglrenderer | GPU accel | MIT | yes | Windows host support is limited (see risks) |
| gfxstream | GPU accel | Apache-2.0 / MIT, verify | yes | |
| ANGLE | GL to D3D11 | BSD-3-Clause | yes | |
| adb (AOSP platform/packages/modules/adb) | install path | Apache-2.0 if built from source | yes if built from AOSP | Google's prebuilt *platform-tools* zip is under the Android SDK licence; prefer building from source |
| **libhoudini** (Intel) | ARM translation | proprietary, no public redistribution licence | **NO** | cannot be bundled |
| **libndk_translation** (Google) | ARM translation | proprietary, extracted from Google images | **NO** | cannot be bundled |
| Google Play Services / GApps | optional | proprietary, needs GMS licence | **NO** | microG (Apache-2.0) is the redistributable option |
| Google Android Emulator prebuilt + SDK system images | **current engine (since 2026-11-19)** | Android SDK License (the emulator's own source is Apache-2.0, its bundled Qt is LGPL-3.0, its QEMU core GPL-2.0) | **NO** as downloaded | **The v0.1.0 alpha installer bundles these. Do not distribute it.** To ship: build the emulator from AOSP source and use a self-built or otherwise redistributable Android 11 image. |
| Google platform-tools (adb.exe) | bundled with the engine (its drag & drop install uses adb) | Android SDK License | **NO** | ship adb built from AOSP source instead |
| Bromite SystemWebView 108.0.5359.156 (x86_64) | WebView update installed into Android at first start | GPL-3.0 (Bromite patches) + BSD-3-Clause (Chromium) + Chromium third-party licences | yes, with source offer | unmaintained since 2022 (no security updates). SlightDroid changes only the package name and re-signs it (`tools/build/rename-webview.py`); notice in `licenses/WebView-Bromite.txt` of the payload |
| AOSP test keys (testkey, platform) | signing the WebView update | Apache-2.0, published in AOSP `build/target/product/security` | not committed here | public keys used by AOSP developer builds; only `testkey` is used for shipping builds |
| NSIS 3.13 | builds SlightDroid-Setup.exe | zlib/libpng | n/a (build tool); produced installers are free to distribute | NSIS stub code is inside Setup.exe, which zlib allows |
| 7-Zip 26.06 | dev: extract ISOs / QEMU installer | LGPL-2.1 + unRAR restriction | not shipped | |
| .NET Framework 4.8 (C# compiler `csc.exe`) | v0.1 launcher | part of Windows | not shipped (already on every Win10/11) | |
| Qt (if chosen for frontend) | frontend | LGPL-3.0 (or commercial) | yes, dynamic linking + relinking allowed | |
| Rust toolchain/crates (if chosen) | frontend | mostly MIT / Apache-2.0 | yes | audit each crate |

## Known licensing blocker (milestone 8)

Neither ARM translation layer can be bundled. Options to decide later:
1. Do not bundle; provide an opt-in "fetch from your own source" step that the user runs
   (the approach some Android-x86 distributions use). We would ship only the integration
   script, not the binaries.
2. Ship x86-only, and tell the user when an APK has only ARM native libs.
