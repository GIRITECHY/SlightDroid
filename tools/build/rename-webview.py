"""Turns a Bromite SystemWebView APK (package org.bromite.webview) into an update for the AOSP WebView
(package com.android.webview) of SlightDroid's Android 11 image.

Both names are 19 characters, so the name is swapped in place in the compiled manifest and the resource
table (UTF-16 and UTF-8 string forms) without moving any data. classes*.dex is left alone (changing dex
strings would break its sorted string table and checksums). Old signatures are dropped; the result must be
zip-aligned (zipalign -p) and signed with the image's AOSP test key afterwards.

usage: python -I rename-webview.py <in.apk> <out-unsigned.apk>
"""
import sys
import zipfile

OLD, NEW = "org.bromite.webview", "com.android.webview"
assert len(OLD) == len(NEW)


def swap(data: bytes) -> tuple[bytes, int]:
    n = 0
    for enc in ("utf-16-le", "utf-8"):
        o, w = OLD.encode(enc), NEW.encode(enc)
        n += data.count(o)
        data = data.replace(o, w)
    return data, n


def main(src: str, dst: str) -> None:
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            name = info.filename
            if name.startswith("META-INF/") and (name.endswith((".SF", ".RSA", ".EC", ".DSA")) or name == "META-INF/MANIFEST.MF"):
                continue                                  # old signature
            data = zin.read(name)
            if name in ("AndroidManifest.xml", "resources.arsc"):
                data, n = swap(data)
                print(f"{name}: {n} occurrence(s) renamed")
            out = zipfile.ZipInfo(name, date_time=info.date_time)
            out.compress_type = info.compress_type        # keep stored entries stored (native libs, arsc)
            out.external_attr = info.external_attr
            zout.writestr(out, data)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
