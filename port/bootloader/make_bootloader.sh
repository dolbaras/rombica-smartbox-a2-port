#!/bin/bash
# Assemble the Rombica A2 bootloader (out/bootloader_v<port VERSION>.img):
#   BL2  stock VPLT  - LPDDR3 2x512MB init + board voltages (SlimBOX BL2 mis-detects the ranks)
#   BL30 stock VPLT  - SCP firmware (SlimBOX BL30 stops with "Wrong chip c0" on GXLX); its CPU
#                      DVFS table is replaced: up to 1512 MHz instead of 1200 (bl30_dvfs.py;
#                      CPU_DVFS="MHz:mV x6" for another table, CPU_DVFS=stock to keep VPLT's)
#   BL31 SlimBOX 9   - 2019 ATF; the 2017 VPLT BL31 cannot start secondary CPUs of a 32-bit
#                      kernel ("CPU1: failed to come online")
#   BL33 our p271 U-Boot, LZ4C-compressed like stock (a raw BL33 resets the board right after
#                      "BL31: GXL normal boot!" when booting from SD/eMMC; from USB it works)
#
# usage: [CPU_DVFS="100:910 ..."] make_bootloader.sh <u-boot.bin> <out_bootloader.img> [bl31_from_bootloader.img]
#        (3rd arg: take BL31 from another bootloader image, e.g. tools/stock_vplt/... for variant E)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UBOOT="$1"; OUT="$2"
# gxlimg (FIP packer, repk/gxlimg, pinned commit), built in GXLIMG_DIR
GD="${GXLIMG_DIR:-$HOME/build/rombica-smartbox-a2/gxlimg}"; G="$GD/gxlimg"
VPLT="$HERE/../tools/stock_vplt/bootloader.PARTITION"
BL31_SRC="${3:-$HERE/../tools/slimbox/bootloader.PARTITION}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

if [ ! -x "$G" ]; then
    if [ ! -d "$GD/.git" ]; then
        git init -q "$GD"
        git -C "$GD" fetch -q --depth 1 https://github.com/repk/gxlimg.git d7a8d33ef7d330a8dc77f3f53ab1e12b00a6ec8f
        git -C "$GD" checkout -q FETCH_HEAD
    fi
    make -C "$GD" >/dev/null
fi
mkdir "$W/vplt" "$W/bl31"
"$G" -t fip -e "$VPLT" "$W/vplt" >/dev/null           # -> bl2.sign bl30.enc bl31.enc bl33.enc
"$G" -t fip -e "$BL31_SRC" "$W/bl31" >/dev/null
python3 "$HERE/aml_lz4c.py" pack "$UBOOT" "$W/bl33.lz4c" --hash
"$G" -t bl3x -c "$W/bl33.lz4c" "$W/bl33.enc"
BL30="$W/vplt/bl30.enc"
# 1512 MHz at 1140 mV is the Amlogic reference step for this board (p271 dvfs_board.c, 1110+30 mV);
# 667 MHz goes to keep the entry count. Tested: 7-Zip 15 min (Armbian), md5 x4 10 min (Android),
# no errors, 71 C with heatsinks (throttling from 80 C).
CPU_DVFS="${CPU_DVFS:-100:910 250:910 500:910 1000:990 1200:1070 1512:1140}"
if [ "$CPU_DVFS" != stock ]; then
    python3 "$HERE/bl30_dvfs.py" "$G" "$BL30" "$W/bl30.enc" $CPU_DVFS; BL30="$W/bl30.enc"
fi
"$G" -t fip --bl2 "$W/vplt/bl2.sign" --bl30 "$BL30" --bl31 "$W/bl31/bl31.enc" \
     --bl33 "$W/bl33.enc" "$OUT" >/dev/null
cmp -n 49152 "$OUT" "$VPLT"                            # BL2 must stay byte-identical to stock
echo "$OUT: $(stat -c %s "$OUT") bytes"
