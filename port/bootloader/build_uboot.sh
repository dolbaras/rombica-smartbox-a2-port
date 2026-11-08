#!/bin/bash
# Build the p271 U-Boot (BL33) for Rombica A2 from source:
#   U-Boot  Amlogic U-Boot 2015.01 (libre-computer-project/amlogic-bootloader-uboot-repo-bl33,
#           pinned commit) + port/bootloader/patches (GXLX support, microSD boot menu, PC monitors,
#           MPLL load bits)
#   gcc     Linaro GCC 4.8-2013.11 aarch64-none-elf, the toolchain this U-Boot is written for
# The kbuild Makefile cannot handle spaces in paths, so everything is built in $B.
# $B/src is a git tree: the pinned commit with the patches as commits (to change U-Boot, commit
# there and regenerate port/bootloader/patches with git format-patch, as for the kernel).
#
# usage: build_uboot.sh <out_u-boot.bin> [extra KCFLAGS]
# env:   UBOOT_BUILD_DIR (default ~/build/rombica-smartbox-a2/uboot)
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(realpath -m "$1")"; EXTRA="${2:-}"
B="${UBOOT_BUILD_DIR:-$HOME/build/rombica-smartbox-a2/uboot}"
BASE=3488cde3405bd3e538e801489826c6a0fbe1b131
TC=gcc-linaro-aarch64-none-elf-4.8-2013.11_linux
mkdir -p "$B"; cd "$B"

if [ ! -d src/.git ]; then
    rm -rf src; git init -q src
    git -C src fetch -q --depth 1 \
        https://github.com/libre-computer-project/amlogic-bootloader-uboot-repo-bl33.git $BASE
    git -C src checkout -q FETCH_HEAD
fi
patches=("$PORT"/bootloader/patches/*.patch)
if [ "$(git -C src rev-parse HEAD)" = $BASE ]; then
    git -C src -c user.name=build -c user.email=build@localhost am -q "${patches[@]}"
fi
# the tree must be the pinned base + exactly our patches (also true for a developer's tree)
want=$(cat "${patches[@]}" | git patch-id --stable | cut -d" " -f1)
have=$(git -C src log -p --reverse $BASE..HEAD | git patch-id --stable | cut -d" " -f1)
[ "$want" = "$have" ] || { echo "U-Boot tree $B/src does not match port/bootloader/patches"; exit 1; }

if [ ! -x tc64/bin/aarch64-none-elf-gcc ]; then   # releases.linaro.org is gone; Armbian mirrors it
    for m in https://dl.armbian.com/_toolchain \
             https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/_toolchain; do
        curl -sfL --retry 3 -o $TC.tar.xz "$m/$TC.tar.xz" && break
    done
    echo "5fd777bee04a79435a0861efd473ec0e  $TC.tar.xz" | md5sum -c --quiet
    rm -rf tc64 $TC && tar xJf $TC.tar.xz && mv $TC tc64 && rm $TC.tar.xz
fi

# built from an export of the committed tree, without .git: the version string is ours
# (U-Boot 2015.01-rombica-a2-v<port/VERSION>), not the git commit of the tree
rm -rf tree && mkdir tree && git -C src archive HEAD | tar -x -C tree
cd tree
M=(O=build CROSS_COMPILE="$B/tc64/bin/aarch64-none-elf-" SYSTEMMODE=systemroot AVBMODE=noavb
   LOCALVERSION="-rombica-a2-v$(cat "$PORT/VERSION")")
make "${M[@]}" gxl_p271_v1_config >/dev/null
make "${M[@]}" KCFLAGS="$EXTRA" -j"$(nproc)" u-boot.bin > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
cp build/u-boot.bin "$OUT"
echo "built $OUT ($(stat -c %s "$OUT") bytes): $(strings -n 20 "$OUT" | grep -m1 '^U-Boot 2015')"
