#!/bin/bash
# Build the Rombica A2 kernel and its vendor modules from source:
#   kernel         khadas/linux khadas-vims-pie (Amlogic Android P 4.9.113) + port/kernel/patches
#   media_modules  khadas/android_hardware_amlogic_media_modules khadas-vims-pie
#   mali           khadas/android_hardware_arm_gpu khadas-vim3-pie, utgard r8p0 (userspace r8p0)
#   dhd            khadas/android_hardware_wifi_broadcom_drivers_ap6xxx khadas-vims-pie (AP6181)
# All sources are pinned to the commits this port was tested with.
# Toolchain: Linaro GCC 6.3.1-2017.02 arm-linux-gnueabihf (the one SlimBOX's kernel was built with).
# The kbuild tree cannot live under a path with spaces, so everything is built in $KB.
#
# usage: build_kernel.sh <slimbox boot.img (template)> <out_dir>
#   out_dir/boot.img, out_dir/modules/*.ko, out_dir/firmware/video/*
# env: KB (default ~/build/rombica-smartbox-a2/kernel), JOBS, CMDLINE_APPEND (extra kernel args, testing only)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(realpath "$1")"; OUT="$(realpath -m "$2")"
KB="${KB:-$HOME/build/rombica-smartbox-a2/kernel}"; JOBS="${JOBS:-$(nproc)}"
TC=gcc-linaro-6.3.1-2017.02-x86_64_arm-linux-gnueabihf
export PATH="$KB/$TC/bin:$PATH"
export KBUILD_BUILD_USER=dolbaras KBUILD_BUILD_HOST=rombica-a2
M="make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$JOBS"
mkdir -p "$KB"; cd "$KB"

fetch() {  # fetch <dir> <khadas repo> <commit>
    [ -d "$1" ] && return
    git init -q "$1"
    git -C "$1" fetch -q --depth 1 "https://github.com/khadas/$2.git" "$3"
    git -C "$1" checkout -q FETCH_HEAD
}
LINUX_BASE=d71236547be9b86d527de0f62c2092ec032fd0fa
fetch linux linux $LINUX_BASE
fetch media_modules android_hardware_amlogic_media_modules 09d4d27072363931e4424f411ec4087a74d3c009
fetch gpu android_hardware_arm_gpu be29f1f274e3798d3ab2d7c489e47f8de20e8cf3
fetch wifi_ap6xxx android_hardware_wifi_broadcom_drivers_ap6xxx 2218a835e2604198ceb9d1c5dbd9f8ef0f92f72c
if [ ! -d "$TC" ]; then   # releases.linaro.org is gone; Armbian mirrors the original tarball
    for m in https://dl.armbian.com/_toolchain \
             https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/_toolchain; do
        curl -sfL --retry 3 -o $TC.tar.xz "$m/$TC.tar.xz" && break
    done
    echo "31d591c7bbd06ae31385bcdfd37ab702  $TC.tar.xz" | md5sum -c --quiet
    tar xJf $TC.tar.xz && rm $TC.tar.xz
fi

echo "== kernel patches"
patches=("$HERE"/patches/*.patch)
if [ "$(git -C linux rev-parse HEAD)" = $LINUX_BASE ]; then
    git -C linux -c user.name=build -c user.email=build@localhost am -q "${patches[@]}"
fi
# the tree must be the pinned base + exactly our patches (also true for a developer's tree)
want=$(cat "${patches[@]}" | git patch-id --stable | cut -d" " -f1)
have=$(git -C linux log -p --reverse $LINUX_BASE..HEAD | git patch-id --stable | cut -d" " -f1)
[ "$want" = "$have" ] || { echo "linux tree does not match port/kernel/patches"; exit 1; }

echo "== kernel"
# reproducible: build number 1, build time = date of the newest patch
export KBUILD_BUILD_VERSION=1
KBUILD_BUILD_TIMESTAMP="$(sed -n 's/^Date: //p' "${patches[-1]}")"; export KBUILD_BUILD_TIMESTAMP
export SOURCE_DATE_EPOCH="$(date -d "$KBUILD_BUILD_TIMESTAMP" +%s)"   # uImage header (mkboot.py)
mkdir -p out_k
cp "$HERE/rombica_a2.config" out_k/.config
rm -f out_k/include/generated/compile.h   # mkcompile_h keeps an old one if only the date differs
$M -C linux O=../out_k olddefconfig >/dev/null
$M -C linux O=../out_k zImage modules >build_kernel.log 2>&1 || { tail -30 build_kernel.log; exit 1; }

echo "== media modules"
rm -rf mm_build && cp -a media_modules/drivers mm_build
CONFIGS=$(sed -n '/^CONFIGS :=/,/^$/p' media_modules/Media.mk | grep -o 'CONFIG_[A-Z0-9_]*=m')
$M -C out_k M="$KB/mm_build" $CONFIGS EXTRA_CFLAGS+="-I$KB/mm_build/include" modules \
    >build_media.log 2>&1 || { tail -30 build_media.log; exit 1; }

echo "== mali (utgard r8p0)"
rm -rf mali_build && mkdir mali_build && cp -a gpu/utgard/r8p0/* gpu/utgard/platform mali_build/
sed -i 's/BUILD_DATE=$(shell date)/BUILD_DATE=$(KBUILD_BUILD_TIMESTAMP)/' mali_build/Kbuild  # reproducible
$M -C out_k M="$KB/mali_build" CONFIG_MALI400=m CONFIG_MALI450=m \
    EXTRA_CFLAGS="-DCONFIG_MALI400=m -DCONFIG_MALI450=m" CONFIG_AM_VDEC_H264_4K2K=y modules \
    >build_mali.log 2>&1 || { tail -30 build_mali.log; exit 1; }

echo "== dhd (AP6181)"
rm -rf dhd_build && cp -a wifi_ap6xxx/bcmdhd.100.10.315.x dhd_build
$M -C out_k M="$KB/dhd_build" CONFIG_BCMDHD_SDIO=y modules \
    >build_dhd.log 2>&1 || { tail -30 build_dhd.log; exit 1; }

echo "== collect"
# The modules SlimBOX loads (vendor init.amlogic.*.rc), except amvdec_vp9: the S905L2 has no VP9
# hardware (Amlogic's vvp9.c has the GXLX exclusion commented out) and tb_detect (closed source).
rm -rf "$OUT"; mkdir -p "$OUT/modules" "$OUT/firmware/video"
cp mali_build/mali.ko dhd_build/dhd.ko "$OUT/modules/"
for m in media_clock firmware decoder_common stream_input amvdec_avs amvdec_h264 amvdec_mh264 \
         amvdec_h264mvc amvdec_h265 amvdec_mjpeg amvdec_mmjpeg amvdec_mpeg12 amvdec_mmpeg12 \
         amvdec_mpeg4 amvdec_mmpeg4 amvdec_real amvdec_vc1 amvdec_avs2 encoder vpu; do
    cp "$(find mm_build -name "$m.ko")" "$OUT/modules/"
done
arm-linux-gnueabihf-strip --strip-debug "$OUT"/modules/*.ko
cp media_modules/firmware/* "$OUT/firmware/video/"
echo "$SOURCE_DATE_EPOCH" > "$OUT/SOURCE_DATE_EPOCH"          # build.sh packs recovery with it
python3 "$HERE/mkboot.py" "$TEMPLATE" out_k/arch/arm/boot/zImage "$OUT/boot.img" \
    ${CMDLINE_APPEND:+--cmdline-append "$CMDLINE_APPEND"}
echo "built: $OUT"
