#!/bin/bash
# Try a kernel build on the box without touching the normal boot path (developer tool):
#   * <build>/boot.img is written to the RECOVERY partition (verified by readback),
#   * <build>/modules and <build>/firmware/video go to /vendor/lib/modules_rk and
#     /vendor/lib/firmware/video_rk; /vendor/etc/init/rombica_kernel_test.rc bind-mounts them over
#     the normal directories only when the kernel command line has androidboot.rombica_kernel=new,
#   * the box reboots to recovery = the test kernel. Any later power cycle boots the normal kernel.
# The boot.img must be built with
#   CMDLINE_APPEND="rootfstype=ext4 skip_initramfs ro rootwait androidboot.rombica_kernel=new"
# (U-Boot's recovery path adds rootfstype=ramfs and no skip_initramfs).
#
# usage: test_on_box.sh <build_kernel.sh out_dir>        env: ADB (default: adb)
set -euo pipefail
B="$(realpath "$1")"; ADB="${ADB:-adb}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/rombica_kernel_test.rc" <<'EOF'
# Test harness for a rebuilt kernel booted from the recovery partition (port/kernel/test_on_box.sh)
on early-init && property:ro.boot.rombica_kernel=new
    mount none /vendor/lib/modules_rk /vendor/lib/modules bind
    mount none /vendor/lib/firmware/video_rk /vendor/lib/firmware/video bind
EOF
$ADB root >/dev/null; sleep 2
$ADB shell 'rm -rf /data/local/tmp/kt && mkdir -p /data/local/tmp/kt'
$ADB push "$B/modules" "$B/firmware/video" "$W/rombica_kernel_test.rc" "$B/boot.img" \
    /data/local/tmp/kt/ >/dev/null
$ADB shell 'set -e; cd /data/local/tmp/kt
umount /vendor/lib/modules 2>/dev/null || true         # running a test kernel already
umount /vendor/lib/firmware/video 2>/dev/null || true
mount -o remount,rw /vendor
rm -rf /vendor/lib/modules_rk /vendor/lib/firmware/video_rk
cp -r modules /vendor/lib/modules_rk; cp -r video /vendor/lib/firmware/video_rk
cp rombica_kernel_test.rc /vendor/etc/init/
chown -R root:shell /vendor/lib/modules_rk /vendor/lib/firmware/video_rk
chown root:root /vendor/lib/modules_rk/* /vendor/lib/firmware/video_rk/*
chmod 755 /vendor/lib/modules_rk /vendor/lib/firmware/video_rk
chmod 644 /vendor/lib/modules_rk/* /vendor/lib/firmware/video_rk/* /vendor/etc/init/rombica_kernel_test.rc
chcon -R u:object_r:vendor_file:s0 /vendor/lib/modules_rk /vendor/lib/firmware/video_rk
chcon u:object_r:vendor_configs_file:s0 /vendor/etc/init/rombica_kernel_test.rc
sync; mount -o remount,ro /vendor
dd if=boot.img of=/dev/block/recovery bs=1048576 2>/dev/null; sync
n=$(stat -c %s boot.img)
[ "$(dd if=/dev/block/recovery bs=1048576 2>/dev/null | head -c $n | sha1sum)" = "$(sha1sum < boot.img)" ]
echo "recovery written and verified"
reboot recovery'
