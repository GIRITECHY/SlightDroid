#!/system/bin/sh
# SlightDroid post-fs-data hook (runs as root from init.slightdroid.rc, every boot, idempotent).
# Init WAITS for this script, so keep it fast: anything slow belongs in bootcomplete.sh.

# 1) Storage: the launcher grows the virtual data disk to the size chosen in Settings
#    (minimum 50 GB). Grow the mounted ext4 filesystem to fill it (online, takes a moment
#    only right after a size change; otherwise it is a no-op).
/system/bin/resize2fs /dev/block/vdb > /dev/kmsg 2>&1

# 2) Data safety: write changed data to the virtual disk within ~1-3 s instead of 5-30 s,
#    so even a crash or power cut loses almost nothing. (A normal close in SlightDroid syncs fully.)
echo 100 > /proc/sys/vm/dirty_writeback_centisecs
echo 200 > /proc/sys/vm/dirty_expire_centisecs
mount -o remount,commit=3 /data

# 3) Wi-Fi: pre-save the virtual Wi-Fi network (open SSID "VirtWifi" provided by Android-x86's
#    virt_wifi wrapper around the virtio NIC). Only if Android has no Wi-Fi config yet.
if [ ! -e /data/misc/wifi/WifiConfigStore.xml ]; then
    mkdir -p /data/misc/wifi
    chown wifi:wifi /data/misc/wifi
    chmod 0770 /data/misc/wifi
    cp /slightdroid/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml
    chown system:system /data/misc/wifi/WifiConfigStore.xml
    chmod 0600 /data/misc/wifi/WifiConfigStore.xml
    chcon u:object_r:wifi_data_file:s0 /data/misc/wifi /data/misc/wifi/WifiConfigStore.xml
fi
