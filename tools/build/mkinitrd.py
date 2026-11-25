#!/usr/bin/env python3
"""Build SlightDroid's Lite initrd from the Android-x86 initrd.

Reads the original gzip'd cpio (newc) directly so every entry keeps its mode, owner,
symlink target and device numbers, then:
  * patches /init so that with SLIGHTDROID=1 on the kernel command line it
      - unpacks the Android ramdisk from /slightdroid/ramdisk.img (bundled in this initrd)
      - mounts the system image read-only straight from a block device
        (SLIGHTDROID_SYSTEM=vda) instead of squashfs + loop + loop
      - appends /slightdroid/slightdroid.prop to default.prop and imports /init.slightdroid.rc
  * adds /slightdroid/* (ramdisk.img and the files from guest/lite/overlay)

Without SLIGHTDROID=1 the init behaves exactly like the original.

usage: mkinitrd.py <orig initrd.img> <android ramdisk.img> <overlay dir> <out initrd.img>
"""
import gzip
import io
import os
import sys

MAGIC = b"070701"


def read_newc(data):
    entries, off = [], 0
    while True:
        if data[off:off + 6] != MAGIC:
            raise ValueError(f"bad cpio magic at {off}")
        f = [int(data[off + 6 + i * 8: off + 14 + i * 8], 16) for i in range(13)]
        ino, mode, uid, gid, nlink, mtime, size, dmaj, dmin, rmaj, rmin, namesize, _chk = f
        name_off = off + 110
        name = data[name_off:name_off + namesize - 1].decode()
        off = (name_off + namesize + 3) & ~3
        body = data[off:off + size]
        off = (off + size + 3) & ~3
        if name == "TRAILER!!!":
            return entries
        entries.append(dict(name=name, mode=mode, uid=uid, gid=gid, nlink=nlink, mtime=mtime,
                            dmaj=dmaj, dmin=dmin, rmaj=rmaj, rmin=rmin, body=body))


def write_newc(entries):
    out = io.BytesIO()

    def put(e, ino):
        name = e["name"].encode() + b"\0"
        hdr = "%s%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X" % (
            "070701", ino, e["mode"], e["uid"], e["gid"], e["nlink"], e["mtime"], len(e["body"]),
            e["dmaj"], e["dmin"], e["rmaj"], e["rmin"], len(name), 0)
        out.write(hdr.encode() + name)
        out.write(b"\0" * ((4 - out.tell() % 4) % 4))
        out.write(e["body"])
        out.write(b"\0" * ((4 - out.tell() % 4) % 4))

    for i, e in enumerate(entries, 1):
        put(e, i)
    put(dict(name="TRAILER!!!", mode=0, uid=0, gid=0, nlink=1, mtime=0,
             dmaj=0, dmin=0, rmaj=0, rmin=0, body=b""), 0)
    return out.getvalue()


SCAN_ORIG = """while :; do
\tfor device in ${ROOT:-/dev/[hmnsv][dmrv][0-9a-z]*}; do
\t\tcheck_root $device && break 2
\t\tmountpoint -q /mnt && umount /mnt
\tdone
\tsleep 1
\techo -n .
done
"""

SCAN_SLIGHTDROID = """if [ -n "$SLIGHTDROID" ]; then
\t# SlightDroid: ramdisk from this initrd, system straight from a read-only virtio disk
\tzcat /slightdroid/ramdisk.img | cpio -id > /dev/null
\tn=0
\twhile [ ! -b /dev/${SLIGHTDROID_SYSTEM:-vda} -a $n -lt 100 ]; do usleep 100000; n=$((n+1)); mdev -s; done
\tmount -o ro,noatime /dev/${SLIGHTDROID_SYSTEM:-vda} system || debug_shell slightdroid-no-system
\tmkdir -p mnt /mnt/slightdroid
\tSRC=slightdroid
\techo " SlightDroid system on /dev/${SLIGHTDROID_SYSTEM:-vda}"
\t# SLIGHTDROID_LOG=1: keep kernel and Android init messages on the console (debugging)
\t[ -n "$SLIGHTDROID_LOG" ] && echo 7 4 1 7 > /proc/sys/kernel/printk
else
""" + SCAN_ORIG + "fi\n"

PROP_ANCHOR = '[ "$SETUPWIZARD" = "0" ] && echo "ro.setupwizard.mode=DISABLED" >> default.prop\n'
PROP_SLIGHTDROID = """if [ -n "$SLIGHTDROID" ]; then
\t# Android-x86's init.sh picks the graphics HAL by reading /proc/fb once; if the virtio GPU
\t# driver has not registered yet it picks none and SurfaceFlinger crash-loops ("failed to get
\t# hwcomposer service"). Do not race it: SlightDroid always has a virtio GPU, so state the HALs
\t# here (ro.* props set in default.prop win; init.sh cannot change them later).
\t# (Loading virtio_gpu early in the initrd instead broke first boots: QEMU then rejected
\t# the display buffer, "virgl_cmd_set_scanout: illegal resource".)
\tif [ "$HWACCEL" != "0" ]; then
\t\techo "ro.hardware.gralloc=gbm" >> default.prop
\t\techo "ro.hardware.hwcomposer=drm" >> default.prop
\t\t[ -n "$video" ] && echo "debug.drm.mode.force=$video" >> default.prop
\tfi
\tcat /slightdroid/slightdroid.prop >> default.prop
\tmkdir -p slightdroid
\tcp /slightdroid/postfs.sh /slightdroid/bootcomplete.sh /slightdroid/WifiConfigStore.xml slightdroid/
\tcp /slightdroid/init.slightdroid.rc .
\techo "import /init.slightdroid.rc" >> init.rc
fi
"""


def main():
    orig, ramdisk, overlay, out = sys.argv[1:5]
    with open(orig, "rb") as f:
        entries = read_newc(gzip.decompress(f.read()))

    init = next(e for e in entries if e["name"] == "init")
    text = init["body"].decode()
    for needle in (SCAN_ORIG, PROP_ANCHOR):
        if text.count(needle) != 1:
            raise SystemExit(f"init does not contain the expected block exactly once:\n{needle}")
    text = text.replace(SCAN_ORIG, SCAN_SLIGHTDROID).replace(PROP_ANCHOR, PROP_SLIGHTDROID + PROP_ANCHOR)
    init["body"] = text.encode()

    mtime = init["mtime"]

    def add(name, body, mode):
        entries.append(dict(name=name, mode=mode, uid=0, gid=0, nlink=1, mtime=mtime,
                            dmaj=0, dmin=0, rmaj=0, rmin=0, body=body))

    add("slightdroid", b"", 0o040755)
    with open(ramdisk, "rb") as f:
        add("slightdroid/ramdisk.img", f.read(), 0o100644)
    for fn in sorted(os.listdir(overlay)):
        with open(os.path.join(overlay, fn), "rb") as f:
            body = f.read().replace(b"\r\n", b"\n")
        add("slightdroid/" + fn, body, 0o100755 if fn.endswith(".sh") else 0o100644)

    with open(out, "wb") as f:
        f.write(gzip.compress(write_newc(entries), compresslevel=9, mtime=0))
    print(f"{out}: {len(entries)} entries, {os.path.getsize(out) / 1048576:.1f} MB")


if __name__ == "__main__":
    main()
