#!/bin/bash
# Update a running Rombica A2 Android over adb (developer tool; Android must be up, adb as root):
#   -b <bootloader.img>   bootloader: eMMC user area + boot0 + boot1 at 512 bytes, each read back
#   -k <build_kernel.sh out_dir>   boot.img into the boot partition (read back) and its modules
#                         into /vendor/lib/modules (the kernel test harness of test_on_box.sh is
#                         removed, so the next boot uses this kernel normally)
# Reboot afterwards (adb reboot).
# usage: adb_update.sh [-b bootloader.img] [-k kernel_out]      env: ADB (default: adb)
set -euo pipefail
ADB="${ADB:-adb}"; BL=""; KO=""
while getopts b:k: o; do case $o in b) BL="$(realpath "$OPTARG")" ;; k) KO="$(realpath "$OPTARG")" ;; *) exit 1 ;; esac; done
[ -n "$BL$KO" ] || { sed -n 2,9p "$0"; exit 1; }
$ADB root >/dev/null; sleep 2
$ADB shell 'rm -rf /data/local/tmp/upd && mkdir -p /data/local/tmp/upd'
if [ -n "$KO" ]; then
    $ADB remount >/dev/null
    $ADB push "$KO/boot.img" "$KO/modules" /data/local/tmp/upd/ >/dev/null
    $ADB shell 'set -e; cd /data/local/tmp/upd
for f in modules/*.ko; do n=${f##*/}; cp "$f" "/vendor/lib/modules/$n"
    chown root:root "/vendor/lib/modules/$n"; chmod 644 "/vendor/lib/modules/$n"
    chcon u:object_r:vendor_file:s0 "/vendor/lib/modules/$n"; done
rm -rf /vendor/lib/modules_rk /vendor/lib/firmware/video_rk /vendor/etc/init/rombica_kernel_test.rc
sync
dd if=boot.img of=/dev/block/boot bs=1048576 2>/dev/null; sync
n=$(stat -c %s boot.img)
[ "$(dd if=/dev/block/boot bs=1048576 2>/dev/null | head -c $n | md5sum)" = "$(md5sum < boot.img)" ]
echo "kernel: boot partition written and verified, $(ls modules | wc -l) modules installed"'
fi
if [ -n "$BL" ]; then
    $ADB push "$BL" /data/local/tmp/upd/bl.img >/dev/null
    $ADB shell 'set -e; cd /data/local/tmp/upd; n=$(stat -c %s bl.img); want=$(md5sum < bl.img)
for d in bootloader mmcblk0boot0 mmcblk0boot1; do f=/sys/block/$d/force_ro
    [ -e $f ] && echo 0 > $f; dd if=bl.img of=/dev/block/$d bs=512 seek=1 2>/dev/null; sync
    [ -e $f ] && echo 1 > $f; echo 3 > /proc/sys/vm/drop_caches
    [ "$(head -c $((n + 512)) /dev/block/$d | tail -c +513 | md5sum)" = "$want" ] || { echo "$d: MISMATCH"; exit 1; }
    echo "bootloader: $d written and verified"; done'
fi
$ADB shell 'rm -rf /data/local/tmp/upd'
echo "done; reboot with: $ADB reboot"
