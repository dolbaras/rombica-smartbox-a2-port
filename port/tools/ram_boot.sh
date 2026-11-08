#!/bin/bash
# Boot a full GXL bootloader image (BL2 at 0, FIP at 0xC000) into RAM through the BootROM
# (USB id 2.4). Nothing is written to eMMC.
# usage: ram_boot.sh [bootloader.img]      (default: stock VPLT bootloader)
source "$(dirname "$0")/env.sh"
IMG="${1:-$STOCK/bootloader.PARTITION}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
head -c 49152 "$IMG" > "$WORK/bl2.bin"
tail -c +49153 "$IMG" > "$WORK/fip.bin"
python3 "$TOOLS/rom_stage1.py" "$WORK/bl2.bin" "$DATAS" || exit 1
sleep 4
python3 "$TOOLS/bl2_stage2.py" "$WORK/bl2.bin" "$WORK/fip.bin" "$DATAS" || exit 1
echo "waiting for U-Boot USB burn mode..."
for _ in $(seq 1 30); do
    timeout 5 "$UPDATE" bulkcmd "echo ok" 2>&1 | grep -q success && { echo "U-Boot ready"; exit 0; }
    sleep 1
done
echo "U-Boot did not answer"; exit 1
