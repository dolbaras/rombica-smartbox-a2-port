#!/bin/bash
# Write a bootloader image to an already prepared boot card (see prepare_sd.sh) in a PC card reader:
# sectors 1.. only, partition table and FAT partition are kept. Verified by readback.
#
# usage: sudo ./write_bootloader.sh <device> <bootloader.img>
# Refuses to run unless <device> is a removable USB disk whose first partition starts at 8192.
set -euo pipefail
DEV="$1"; IMG="$2"
PART_START=8192
name=$(basename "$DEV")
[ -b "$DEV" ] || { echo "no such block device: $DEV"; exit 1; }
[ "$(cat /sys/block/$name/removable)" = 1 ] || { echo "$DEV is not removable, refusing"; exit 1; }
readlink -f /sys/block/$name | grep -q "/usb" || { echo "$DEV is not on USB, refusing"; exit 1; }
size=$(cat /sys/block/$name/size)
[ "$size" -lt $((64 * 1024 * 1024 * 2)) ] || { echo "$DEV is larger than 64 GiB, refusing"; exit 1; }
start=$(cat /sys/block/$name/${name}1/start 2>/dev/null || echo 0)
[ "$start" -ge $PART_START ] || { echo "$DEV: first partition at $start, run prepare_sd.sh first"; exit 1; }
blk=$(( ($(stat -c %s "$IMG") + 511) / 512 ))
[ $((blk + 1)) -lt "$start" ] || { echo "bootloader too big"; exit 1; }

echo "== $DEV: $(cat /sys/block/$name/device/model 2>/dev/null), $((size / 2048)) MiB, partition at $start"
dd if="$IMG" of="$DEV" bs=512 seek=1 conv=fsync,notrunc status=none
sync; echo 3 > /proc/sys/vm/drop_caches
cmp <(dd if="$DEV" bs=512 skip=1 count=$blk status=none | head -c "$(stat -c %s "$IMG")") "$IMG" \
    && echo "bootloader OK ($blk sectors)" || { echo "READBACK MISMATCH"; exit 1; }
