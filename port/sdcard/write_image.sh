#!/bin/bash
# Write a whole disk image (e.g. Armbian .img, .img.gz or .img.xz) to a card/flash drive in a PC reader and
# verify it by reading it back.
#
# usage: sudo ./write_image.sh <device> <image.img|image.img.gz|image.img.xz>
# Refuses to run unless <device> is a removable USB disk bigger than the image.
set -euo pipefail
DEV="$1"; IMG="$2"
name=$(basename "$DEV")
[ -b "$DEV" ] || { echo "no such block device: $DEV"; exit 1; }
[ "$(cat /sys/block/$name/removable)" = 1 ] || { echo "$DEV is not removable, refusing"; exit 1; }
readlink -f /sys/block/$name | grep -q "/usb" || { echo "$DEV is not on USB, refusing"; exit 1; }
[ "$(cat /sys/block/$name/ro)" = 0 ] || { echo "$DEV is write-protected (lock switch or card)"; exit 1; }
case "$IMG" in *.gz) size=$(gzip -l "$IMG" | awk 'NR==2{print $2}'); cat="gzip -dc" ;;
                *.xz) size=$(xz --robot -l "$IMG" | awk '$1=="totals"{print $5}'); cat="xz -dcT0" ;;
                *)    size=$(stat -c %s "$IMG"); cat="cat" ;; esac
dev_bytes=$(( $(cat /sys/block/$name/size) * 512 ))
[ "$size" -le "$dev_bytes" ] || { echo "image ($size) larger than $DEV ($dev_bytes)"; exit 1; }
echo "$DEV: $(cat /sys/block/$name/device/model 2>/dev/null) $((dev_bytes / 1000000000)) GB, image $((size / 1048576)) MiB"
for p in /sys/block/$name/$name*; do
    [ -e "$p" ] && umount "/dev/$(basename "$p")" 2>/dev/null || true
done
want=$($cat "$IMG" | sha1sum | cut -d" " -f1)
$cat "$IMG" | dd of="$DEV" bs=4M iflag=fullblock oflag=direct status=progress
sync
echo 3 > /proc/sys/vm/drop_caches
have=$(head -c "$size" "$DEV" | sha1sum | cut -d" " -f1)
if [ "$want" = "$have" ]; then echo "WRITE OK, verified ($want)"; else echo "VERIFY FAILED: $want != $have"; exit 1; fi
