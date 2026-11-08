#!/bin/bash
# Install the Rombica SmartBox A2 Android 9 firmware image over USB from Linux (the same steps the
# Amlogic USB Burning Tool performs). Erases the whole eMMC (except factory keys) and writes every
# partition including the bootloader; each image is checked by the box against its sha1.
#
# The box must be connected to this PC with a USB A-A cable and be in one of these states:
#   * U-Boot USB burning mode: hold the reset button (inside the AV jack) while plugging power,
#     keep it pressed ~5 s. Works with the stock VPLT firmware and with this port.
#   * Amlogic BootROM (no valid bootloader): the script loads the image's bootloader into RAM.
#
# usage: install_firmware.sh <rombica_a2_p271_slimbox_9.20_atv.img>
source "$(dirname "$0")/env.sh"
IMG="$(realpath "$1")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
die() { echo "STOP: $*"; exit 1; }
b() { timeout 120 "$UPDATE" bulkcmd "$1" 2>&1 | grep -q success || die "bulkcmd failed: $1"; }
part() {   # part <name> <file>   (format from the image item, sha1 checked on the box)
    local fmt=normal out rc
    head -c 4 "$2" | xxd -p | grep -q '^3aff26ed$' && fmt=sparse
    echo "== $1 ($(stat -c %s "$2") bytes, $fmt)"
    out=$(timeout 1800 "$UPDATE" partition "$1" "$2" $fmt "${2%.PARTITION}.VERIFY" 2>&1); rc=$?
    [ $rc = 0 ] && ! echo "$out" | grep -qiE "err|fail" || { echo "$out" | tail -3; die "partition $1"; }
}

python3 "$TOOLS/../pack/extract_aml_image.py" "$IMG" "$W" >/dev/null || die "cannot read $IMG"
for f in DDR.USB UBOOT.USB meson1.dtb _aml_dtb.PARTITION bootloader.PARTITION; do
    [ -f "$W/$f" ] || die "$f missing in image"
done

echo "== waiting for the box (U-Boot burning mode or BootROM) ..."
state=""
for _ in $(seq 1 300); do
    # BootROM enumerates as "GX-CHIP"; never send U-Boot commands to it (it wedges until power-off)
    if lsusb | grep -q "1b8e:c003.*GX-CHIP"; then state=rom; break; fi
    if lsusb | grep -q "1b8e:c003" && timeout 5 "$UPDATE" bulkcmd "echo 12345" 2>&1 | grep -q success; then
        state=uboot; break
    fi
    sleep 1
done
[ -n "$state" ] || die "box not found on USB"
if [ "$state" = rom ]; then
    echo "== BootROM: loading the image bootloader into RAM"
    cat "$W/DDR.USB" "$W/UBOOT.USB" > "$W/bootloader_usb.img"
    "$TOOLS/ram_boot.sh" "$W/bootloader_usb.img" || die "RAM boot failed"
fi
b "echo 12345"

echo "== partition table (from the image DTB), erase flash"
out=$(timeout 60 "$UPDATE" mwrite "$W/meson1.dtb" mem dtb normal 2>&1) && ! echo "$out" | grep -qiE "err|fail" \
    || { echo "$out"; die "mwrite dtb"; }
b "disk_initial 1"
part _aml_dtb "$W/_aml_dtb.PARTITION"

while read -r f; do
    p=$(basename "$f" .PARTITION)
    case "$p" in _aml_dtb|bootloader) continue ;; esac
    part "$p" "$f"
done < <(ls "$W"/*.PARTITION)
part bootloader "$W/bootloader.PARTITION"

echo "== default environment, first boot"
b "env default -a"
b "setenv firstboot 1"
b "saveenv"
timeout 10 "$UPDATE" bulkcmd "reset" >/dev/null 2>&1
echo "INSTALL OK - the box reboots; the first start takes a few minutes"
