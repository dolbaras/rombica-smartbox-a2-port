#!/bin/bash
# Re-flash selected partitions from the port image, through U-Boot in USB burn mode (e.g. U-Boot
# from the SD card, entered by holding the AV-jack reset at power-on). Partition table is kept;
# the device checks each image against its sha1 (.VERIFY item). Resets the box at the end.
#
# usage: flash_parts.sh <rombica_a2_p271_slimbox_9.20_atv.img> <part> [part...]
#        e.g. flash_parts.sh ../out/rombica_a2_p271_slimbox_9.20_atv.img _aml_dtb vendor
source "$(dirname "$0")/env.sh"
IMG="$1"; shift
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
die() { echo "STOP: $*"; exit 1; }

python3 "$TOOLS/../pack/extract_aml_image.py" "$IMG" "$W" >/dev/null || die "extract"
timeout 10 "$UPDATE" bulkcmd "echo 12345" 2>&1 | grep -q success || die "no U-Boot in USB burn mode"
for p in "$@"; do
    f="$W/$p.PARTITION"; [ -f "$f" ] || die "no $p in image"
    fmt=normal; head -c 4 "$f" | xxd -p | grep -q '^3aff26ed$' && fmt=sparse
    echo "== $p ($(stat -c %s "$f") bytes, $fmt)"
    out=$(timeout 1800 "$UPDATE" partition "$p" "$f" $fmt "$W/$p.VERIFY" 2>&1); rc=$?
    echo "$out" | tail -2
    [ $rc = 0 ] && ! echo "$out" | grep -qiE "err|fail" || die "partition $p"
done
timeout 10 "$UPDATE" bulkcmd "reset" >/dev/null 2>&1
echo "done, box is resetting"
