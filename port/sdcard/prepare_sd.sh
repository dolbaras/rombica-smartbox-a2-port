#!/bin/bash
# Prepare a microSD card as an Amlogic GXL boot card:
#   sector 0      MBR with one FAT32 partition starting at sector 8192 (4 MiB)
#   sectors 1..   bootloader image (BL2 + FIP), read by the BootROM from sector 1
#
# usage: sudo ./prepare_sd.sh <device> <bootloader.img>
# Refuses to run unless <device> is a removable USB disk of the expected size.
set -euo pipefail

DEV="$1"; IMG="$2"
EXPECTED_SECTORS=7864320          # this card: 3.75 GiB
PART_START=8192

name=$(basename "$DEV")
[ -b "$DEV" ] || { echo "no such block device: $DEV"; exit 1; }
[ "$(cat /sys/block/$name/removable)" = 1 ] || { echo "$DEV is not removable, refusing"; exit 1; }
[ "$(cat /sys/block/$name/size)" = "$EXPECTED_SECTORS" ] || { echo "$DEV size mismatch, refusing"; exit 1; }
readlink -f /sys/block/$name | grep -q "/usb" || { echo "$DEV is not on USB, refusing"; exit 1; }
if findmnt -rno SOURCE / | grep -q "$DEV"; then echo "$DEV holds /, refusing"; exit 1; fi

img_sectors=$(( ($(stat -c %s "$IMG") + 511) / 512 ))
[ $((img_sectors + 1)) -lt $PART_START ] || { echo "bootloader too big"; exit 1; }

echo "== $DEV: $(cat /sys/block/$name/device/vendor 2>/dev/null) $(cat /sys/block/$name/device/model 2>/dev/null), $(( EXPECTED_SECTORS / 2048 )) MiB"
for p in "${DEV}"?*; do umount "$p" 2>/dev/null || true; done

echo "== partition table"
printf 'label: dos\nstart=%s, type=c\n' "$PART_START" | sfdisk --wipe always --wipe-partitions always "$DEV"
partprobe "$DEV" 2>/dev/null || true; sleep 1

echo "== FAT32 filesystem"
mkfs.vfat -F 32 -n SBOOT "${DEV}1"

echo "== bootloader -> sectors 1..$img_sectors"
dd if="$IMG" of="$DEV" bs=512 seek=1 conv=fsync,notrunc status=none
sync

echo "== verify"
dd if="$DEV" bs=512 skip=1 count="$img_sectors" status=none | head -c "$(stat -c %s "$IMG")" | cmp - "$IMG" \
    && echo "bootloader OK" || { echo "BOOTLOADER VERIFY FAILED"; exit 1; }
sfdisk -d "$DEV" | grep start=
echo "done"
