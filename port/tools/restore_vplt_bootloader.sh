#!/bin/bash
# Restore the VPLT bootloader area (first 4 MiB of eMMC user area, boot0, boot1) byte-exact from
# backup, using a RAM-booted VPLT U-Boot. Use when the box sits in BootROM (lsusb shows
# 1b8e:c003 "GX-CHIP", id 2.4), e.g. after an erased or broken bootloader. Stops on first error.
# usage: restore_vplt_bootloader.sh
source "$(dirname "$0")/env.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
die() { echo "STOP: $*"; exit 1; }
b() { timeout 60 "$UPDATE" bulkcmd "$1" 2>&1 | grep -q success || die "bulkcmd failed: $1"; }

dd if="$BACKUP/emmc_first_876MB.img" of="$WORK/hw0.bin" bs=1M count=2 status=none
head -c 2097152 "$BACKUP/mmcblk0boot0.img" > "$WORK/hw1.bin"
head -c 2097152 "$BACKUP/mmcblk0boot1.img" > "$WORK/hw2.bin"

"$TOOLS/ram_boot.sh" "$STOCK/bootloader.PARTITION" || die "VPLT U-Boot did not start"

# 2 MiB (4096 blocks) per hardware partition; the bootloader occupies < 1 MiB of it
for n in 0 1 2; do
    timeout 60 "$UPDATE" write "$WORK/hw$n.bin" 0x1080000 2>&1 | grep -q "Transfer Complete" || die "upload hw$n"
    b "mmc dev 1 $n"
    b "mmc write 0x1080000 0x0 0x1000"
    b "mw.b 0x3000000 0xaa 0x200000"
    b "mmc read 0x3000000 0x0 0x1000"
    rm -f "$WORK/chk.bin"
    timeout 60 "$UPDATE" mread mem 0x3000000 normal 0x200000 "$WORK/chk.bin" >/dev/null 2>&1 || die "readback hw$n"
    cmp -s "$WORK/chk.bin" "$WORK/hw$n.bin" && echo "hwpart $n: identical to backup" || die "hwpart $n differs"
done
b "mmc dev 1 0"
echo "RESTORE OK - run: $UPDATE bulkcmd reset"
