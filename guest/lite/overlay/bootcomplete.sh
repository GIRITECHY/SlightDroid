#!/system/bin/sh
# SlightDroid boot-completed hook (runs as root, in the background, from init.slightdroid.rc; every
# boot; idempotent). Quick steps first, then "ready", then slow housekeeping.

state=/data/misc/slightdroid
mkdir -p $state
log() { echo "SlightDroid: $*" > /dev/kmsg; }

# First boot of a fresh data disk
if [ ! -e $state/firstboot-done ] && [ ! -e $state/wifi-enabled-once ]; then
    # SlightDroid's image has no setup wizard (the Google one was removed), so mark the device as
    # set up ourselves; otherwise Home and notifications stay restricted.
    settings put global device_provisioned 1
    settings put secure user_setup_complete 1
    svc wifi enable                      # joins the pre-saved VirtWifi network
    touch $state/firstboot-done
    log "first boot setup done"
fi

# An emulator window must never "sleep" like a phone: Android-x86 otherwise blanks the screen
# after the timeout and suspends the whole guest (black window, no network/ADB until woken).
svc power stayon true
settings put system screen_off_timeout 2147483647
echo slightdroid > /sys/power/wake_lock

setprop slightdroid.ready 1

# Memory: this kernel has no zram, so give Android a swap file on the data disk (half the
# guest RAM, 256-1024 MB). Android then pages out idle memory instead of killing the app you
# are using (e.g. a video app with a WebView player). Created once, in the background.
# DISABLED 2026-11-19: on a 2 GB guest, creating/enabling the swap file right after boot froze
# Android (seen on the dev PC install). Off until it is understood; debloat alone frees ~180 MB.
[ -n "$SLIGHTDROID_SWAP" ] || exit 0
mem_kb=$(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo)
swap_mb=$((mem_kb / 2048))
[ $swap_mb -lt 256 ] && swap_mb=256
[ $swap_mb -gt 1024 ] && swap_mb=1024
swapf=/data/slightdroid.swap
want=$((swap_mb * 1048576))
have=0
[ -f $swapf ] && have=$(wc -c < $swapf)
if [ "$have" != "$want" ]; then
    swapoff $swapf 2>/dev/null
    rm -f $swapf
    dd if=/dev/zero of=$swapf bs=1048576 count=$swap_mb 2>/dev/null && chmod 600 $swapf && mkswap $swapf > /dev/null
    log "swap file created: $swap_mb MB"
fi
swapon $swapf 2> /dev/kmsg
echo 60 > /proc/sys/vm/swappiness
rm -f /data/swapfile                     # left over from early test builds
