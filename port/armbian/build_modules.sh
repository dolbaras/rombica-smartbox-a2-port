#!/bin/bash
# Build the kernel modules the Rombica SmartBox A2 Armbian image adds to ophub's kernel 6.18.51:
#   brcmfmac            with brcmfmac-oob-irq-no-wake.patch (Wi-Fi interrupt line, see README)
#   leds-bicolor-gpio   the front LED (leds-bicolor/, DT node from make_dtb.sh)
# Cross-built on the PC against the kernel source ophub builds from (unifreq/linux-6.18.y, tag
# v6.18.51) with ophub's configuration (kernel/config-6.18.51-ophub, from the image's /boot) and
# Arm GNU Toolchain 15.2 (ophub uses 15.x; same vermagic, no module versioning in this kernel).
# Needs pahole (dwarves): the configuration has BTF on, which changes struct layouts.
#
# usage: build_modules.sh [out_dir]      (default: modules/6.18.51-ophub next to this script)
# env:   KB  work directory (default ~/build/rombica-smartbox-a2/armbian)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KVER=6.18.51-ophub
OUT="$(realpath -m "${1:-$HERE/modules/$KVER}")"
KB="${KB:-$HOME/build/rombica-smartbox-a2/armbian}"
TCV=arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu
TC="$KB/toolchain/$TCV/bin/aarch64-none-linux-gnu-"
K="$KB/linux-6.18.51"
command -v pahole >/dev/null || { echo "install pahole (dwarves)"; exit 1; }
mkdir -p "$KB/toolchain"
if [ ! -x "${TC}gcc" ]; then
    (cd "$KB/toolchain"
     curl -sfL --retry 3 -o $TCV.tar.xz \
       "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/$TCV.tar.xz"
     echo "9a685b335bd709d683a8c782253c37e8c36c10e6924e59e39d4769b02132eb43  $TCV.tar.xz" | sha256sum -c --quiet
     tar xJf $TCV.tar.xz && rm $TCV.tar.xz)
fi
if [ ! -d "$K" ]; then
    git init -q "$K"
    git -C "$K" fetch -q --depth 1 https://github.com/unifreq/linux-6.18.y.git refs/tags/v6.18.51
    git -C "$K" checkout -q FETCH_HEAD
fi
[ "$(git -C "$K" rev-parse HEAD)" = 5590f194896d493e8835702eb6c3e88d276d210b ]
M=(ARCH=arm64 CROSS_COMPILE="$TC" LOCALVERSION= -j"$(nproc)")
cp "$HERE/kernel/config-$KVER" "$K/.config"
echo "-ophub" > "$K/localversion-ophub"
make -C "$K" "${M[@]}" olddefconfig >/dev/null
make -C "$K" "${M[@]}" modules_prepare >/dev/null
[ "$(make -s -C "$K" "${M[@]}" kernelrelease)" = "$KVER" ]

W="$(mktemp -d)"; trap 'rm -rf "$W"; git -C "$K" checkout -q -- drivers/net/wireless/broadcom' EXIT
git -C "$K" apply "$HERE/brcmfmac-oob-irq-no-wake.patch"
# from the brcm80211 directory: its Makefile adds -DDEBUG (CONFIG_BRCMDBG) for brcmfmac
make -C "$K" "${M[@]}" M=drivers/net/wireless/broadcom/brcm80211 modules >/dev/null
cp -r "$HERE/leds-bicolor" "$W/leds"
make -C "$K" "${M[@]}" M="$W/leds" modules >/dev/null

rm -rf "$OUT"; mkdir -p "$OUT/brcmfmac" "$OUT/leds"
B="$K/drivers/net/wireless/broadcom/brcm80211/brcmfmac"
cp "$B"/brcmfmac.ko "$B"/*/brcmfmac-*.ko "$OUT/brcmfmac/"
cp "$W/leds/leds-bicolor-gpio.ko" "$OUT/leds/"
"${TC}strip" --strip-debug "$OUT"/*/*.ko
for m in "$OUT"/*/*.ko; do
    [ "$(modinfo -F vermagic "$m")" = "$KVER SMP preempt mod_unload aarch64" ] || { echo "$m: vermagic"; exit 1; }
done
ls -l "$OUT"/*/
