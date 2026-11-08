#!/bin/bash
# Build the SlimBOX 9 firmware for Rombica SmartBox A2 (S905L2, board p271, LPDDR3, AP6181).
#
# usage: [BOOTLOADER=tested_bootloader.img] build.sh <slimbox_s905x_ap6212.img> <vplt_stock.img> <out.img>
#        works with both SlimBOX 9.20 builds: s905x_wifi_ap6212_atv_9_20 and ..._aosp_9_20
# needs: python3 with the `fdt` package, debugfs, e2fsck, simg2img, img2simg, zopfli, git, curl, java
#        (smali/baksmali 2.5.2 are downloaded to toolchains/smali and checked);
#        for the vendor apps (apps/build_apps.sh) Android SDK build-tools 30.0.3 + platform 28, JDK
# The kernel and its modules are built from source (kernel/build_kernel.sh, in ~/build/rombica-smartbox-a2/kernel).
set -euo pipefail

PORT="$(cd "$(dirname "$0")" && pwd)"
SLIMBOX_IMG="$1"; VPLT_IMG="$2"; OUT_IMG="$3"
export PYTHONPATH="$PORT/tools/pylib${PYTHONPATH:+:$PYTHONPATH}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
VERSION="$(cat "$PORT/VERSION")"
BASE="$(basename "$SLIMBOX_IMG" .img)"
case "$BASE" in *_aosp_*) VARIANT=AOSP ;; *) VARIANT=ATV ;; esac   # SlimBOX ATV or AOSP userspace

echo "== extract"
python3 "$PORT/pack/extract_aml_image.py" "$SLIMBOX_IMG" "$WORK/sb" >/dev/null
python3 "$PORT/pack/extract_aml_image.py" "$VPLT_IMG" "$WORK/vplt" >/dev/null

echo "== bootloader: stock VPLT BL2/BL30/BL31 + p271 U-Boot (LZ4C) as BL33"
# (the SlimBOX BL2, even with VPLT DDR settings patched in, mis-detects the LPDDR3 ranks on this board)
cmp "$WORK/vplt/bootloader.PARTITION" "$PORT/tools/stock_vplt/bootloader.PARTITION"
if [ -n "${BOOTLOADER:-}" ]; then                                 # pin an already tested image
  cmp -n 49152 "$BOOTLOADER" "$PORT/tools/stock_vplt/bootloader.PARTITION"
  cp "$BOOTLOADER" "$WORK/bootloader.img"
else
  "$PORT/bootloader/build_uboot.sh" "$WORK/u-boot.bin"
  "$PORT/bootloader/make_bootloader.sh" "$WORK/u-boot.bin" "$WORK/bootloader.img"
fi
head -c 49152 "$WORK/bootloader.img" > "$WORK/DDR.USB"            # BL2, for the USB burning tool
tail -c +49153 "$WORK/bootloader.img" > "$WORK/UBOOT.USB"         # FIP
cmp <(tail -c +513 "$WORK/sb/aml_sdc_burn.UBOOT") "$WORK/sb/bootloader.PARTITION"
{ head -c 512 "$WORK/sb/aml_sdc_burn.UBOOT"; cat "$WORK/bootloader.img"; } > "$WORK/aml_sdc_burn.UBOOT"

echo "== kernel (boot + recovery) and vendor modules"
"$PORT/kernel/build_kernel.sh" "$WORK/sb/boot.PARTITION" "$WORK/kernel"
SOURCE_DATE_EPOCH="$(cat "$WORK/kernel/SOURCE_DATE_EPOCH")" \
python3 "$PORT/kernel/mkboot.py" "$WORK/sb/recovery.PARTITION" \
  "${KB:-$HOME/build/rombica-smartbox-a2/kernel}/out_k/arch/arm/boot/zImage" "$WORK/recovery.img"
mkdir -p "$WORK/kvendor/lib/modules" "$WORK/kvendor/lib/firmware/video"
cp "$WORK"/kernel/modules/*.ko "$WORK/kvendor/lib/modules/"
cp "$WORK"/kernel/firmware/video/* "$WORK/kvendor/lib/firmware/video/"
touch "$WORK/kvendor/lib/modules/.replace" "$WORK/kvendor/lib/firmware/video/.replace"

echo "== device tree"
python3 "$PORT/dts/make_p271_dtb.py" "$WORK/sb/_aml_dtb.PARTITION" "$WORK/vplt/_aml_dtb.PARTITION" "$WORK"

echo "== vendor apps: Indicator (front LED, port info) + TvSettings overlay (Indicator, port info)"
simg2img "$WORK/sb/system.PARTITION" "$WORK/system.ext4"
debugfs -R "dump /system/priv-app/TvSettings/TvSettings.apk $WORK/TvSettings.apk" "$WORK/system.ext4" 2>/dev/null
debugfs -R "dump /system/lib/libinputflinger.so $WORK/libinputflinger.so" "$WORK/system.ext4" 2>/dev/null
[ -s "$WORK/TvSettings.apk" ] || { echo "TvSettings.apk not found in the SlimBOX system image"; exit 1; }
"$PORT/apps/build_apps.sh" "$WORK/TvSettings.apk" "$WORK/apps_out"
mkdir -p "$WORK/apps/app/RombicaIndicator" "$WORK/apps/overlay"
cp "$WORK/apps_out/RombicaIndicator.apk" "$WORK/apps/app/RombicaIndicator/"
cp "$WORK/apps_out/RombicaTvSettings.apk" "$WORK/apps/overlay/"

echo "== port identity: SlimBOX $VARIANT, v$VERSION"
mkdir -p "$WORK/props"
sed -e "s/@VARIANT@/$VARIANT/g" -e "s/@VERSION@/$VERSION/g" -e "s/@BASE@/$BASE/g" \
    "$PORT/vendor/default.prop.append.in" > "$WORK/props/default.prop.append"

echo "== vendor overlay"
simg2img "$WORK/sb/vendor.PARTITION" "$WORK/vendor.ext4"
# hwcomposer: mouse pointer fix, VESA (PC monitor) modes, UI size for monitors (new code)
mkdir -p "$WORK/apps/lib/hw" "$WORK/apps/bin"
debugfs -R "dump /lib/hw/hwcomposer.amlogic.so $WORK/hwcomposer.amlogic.so" "$WORK/vendor.ext4" 2>/dev/null
python3 "$PORT/vendor/make_hwc_cursor.py" "$WORK/hwcomposer.amlogic.so" "$WORK/hwc_cursor.so"
python3 "$PORT/vendor/make_hwc_modes.py" "$WORK/hwc_cursor.so" "$WORK/hwc_modes.so"
python3 "$PORT/vendor/native/build.py" "$PORT/vendor/native/hwc" "$WORK/hwc_modes.so" \
  "$WORK/apps/lib/hw/hwcomposer.amlogic.so"
# smali/baksmali 2.5.2 for the changes of SlimBOX's Java code (checked downloads)
SMALI_DIR="$PORT/toolchains/smali"
for j in smali-2.5.2.jar:9544299578b16f771d8aa8eaefe0d3718ca03478c16f3c356f2fcf1366bfb116 \
         baksmali-2.5.2.jar:d3116248cce4f82ec5a31eb7f95ee75daff42ddf6eed0ab573973dc53fbad2e5; do
  f="$SMALI_DIR/${j%%:*}"
  [ -s "$f" ] || { mkdir -p "$SMALI_DIR"; curl -sfL --retry 3 -o "$f" \
    "https://bitbucket.org/JesusFreke/smali/downloads/${j%%:*}"; }
  echo "${j##*:}  $f" | sha256sum -c --quiet
done
# droidlogic.jar: the display resolution property in the form the framework reads
mkdir -p "$WORK/apps/framework"
debugfs -R "dump /framework/droidlogic.jar $WORK/droidlogic.jar" "$WORK/vendor.ext4" 2>/dev/null
SMALI_DIR="$SMALI_DIR" python3 "$PORT/vendor/make_droidlogic_jar.py" "$WORK/droidlogic.jar" \
  "$WORK/apps/framework/droidlogic.jar"
# systemcontrol: output mode and OSD position for PC monitors (new code)
debugfs -R "dump /bin/systemcontrol $WORK/systemcontrol" "$WORK/vendor.ext4" 2>/dev/null
python3 "$PORT/vendor/native/build.py" "$PORT/vendor/native/systemcontrol" "$WORK/systemcontrol" \
  "$WORK/apps/bin/systemcontrol"
# build.prop: device identity, OpenGL ES version, Amlogic app optimization off (in place)
debugfs -R "dump /build.prop $WORK/vendor_build.prop" "$WORK/vendor.ext4" 2>/dev/null
python3 "$PORT/vendor/edit_props.py" "$WORK/vendor_build.prop" "$PORT/vendor/vendor_build.prop.in" \
  "$WORK/props/build.prop"
"$PORT/vendor/apply_overlay.sh" "$WORK/vendor.ext4" "$PORT/vendor/overlay" "$WORK/apps" "$WORK/kvendor" \
  "$WORK/props"
e2fsck -fn "$WORK/vendor.ext4" >/dev/null
img2simg "$WORK/vendor.ext4" "$WORK/vendor.simg"

echo "== system: input library, Settings, TvSettings"
# right mouse button: SlimBOX sends BACK, the port a right click (make_rclick_lib.py; BACK on the
# right button is the kernel's part, hid right_button_back, switched live); keyboard "like on a
# PC" in the remote desktop mode (new code, native/inputflinger)
mkdir -p "$WORK/sys/system/lib"
python3 "$PORT/vendor/make_rclick_lib.py" "$WORK/libinputflinger.so" "$WORK/libinputflinger_rclick.so"
python3 "$PORT/vendor/native/build.py" "$PORT/vendor/native/inputflinger" \
  "$WORK/libinputflinger_rclick.so" "$WORK/sys/system/lib/libinputflinger.so"
# phone Settings ("Advanced settings"): no "Connected devices" screen without Bluetooth (it
# crashes there). Both apps keep SlimBOX's signature (system/apkpatch.py); their precompiled code
# (oat/) no longer matches, Android compiles them again
debugfs -R "dump /system/priv-app/Settings/Settings.apk $WORK/Settings.apk" "$WORK/system.ext4" 2>/dev/null
mkdir -p "$WORK/sys/system/priv-app/Settings/oat/arm" "$WORK/sys/system/priv-app/TvSettings/oat/arm"
SMALI_DIR="$SMALI_DIR" python3 "$PORT/system/make_settings_nobt.py" "$WORK/Settings.apk" \
  "$WORK/sys/system/priv-app/Settings/Settings.apk"
# TvSettings: PC monitor resolutions in Display -> Screen resolution
SMALI_DIR="$SMALI_DIR" python3 "$PORT/system/make_tvsettings_vesa.py" "$WORK/TvSettings.apk" \
  "$WORK/sys/system/priv-app/TvSettings/TvSettings.apk"
# build.prop: build name and device identity (in place)
debugfs -R "dump /system/build.prop $WORK/system_build.prop" "$WORK/system.ext4" 2>/dev/null
python3 "$PORT/vendor/edit_props.py" "$WORK/system_build.prop" "$PORT/system/system_build.prop.in" \
  "$WORK/sys/system/build.prop" VARIANT="$VARIANT" VERSION="$VERSION"
touch "$WORK/sys/system/priv-app/Settings/oat/arm/.replace" \
  "$WORK/sys/system/priv-app/TvSettings/oat/arm/.replace"
"$PORT/vendor/apply_overlay.sh" "$WORK/system.ext4" "$WORK/sys"
e2fsck -fn "$WORK/system.ext4" >/dev/null
img2simg "$WORK/system.ext4" "$WORK/system.simg"
rm -f "$WORK/system.ext4"

echo "== product: Autostart app"
# SlimBOX's Autostart app crashed at every boot (settings read before the user unlock); it keeps
# SlimBOX's signature (system/apkpatch.py), its oat/ is removed (no longer matches)
simg2img "$WORK/sb/product.PARTITION" "$WORK/product.ext4"
debugfs -R "dump /app/AutostartApp/AutostartApp.apk $WORK/AutostartApp.apk" "$WORK/product.ext4" 2>/dev/null
mkdir -p "$WORK/prod/app/AutostartApp/oat/arm"
SMALI_DIR="$SMALI_DIR" python3 "$PORT/system/make_autostart_locked_boot.py" "$WORK/AutostartApp.apk" \
  "$WORK/prod/app/AutostartApp/AutostartApp.apk"
touch "$WORK/prod/app/AutostartApp/oat/arm/.replace"
"$PORT/vendor/apply_overlay.sh" "$WORK/product.ext4" "$WORK/prod"
e2fsck -fn "$WORK/product.ext4" >/dev/null
img2simg "$WORK/product.ext4" "$WORK/product.simg"
rm -f "$WORK/product.ext4"

echo "== pack"
python3 "$PORT/pack/repack_aml_image.py" "$SLIMBOX_IMG" "$OUT_IMG" \
  "USB:DDR=$WORK/DDR.USB" \
  "USB:UBOOT=$WORK/UBOOT.USB" \
  "PARTITION:bootloader=$WORK/bootloader.img" \
  "PARTITION:boot=$WORK/kernel/boot.img" \
  "PARTITION:recovery=$WORK/recovery.img" \
  "UBOOT:aml_sdc_burn=$WORK/aml_sdc_burn.UBOOT" \
  "PARTITION:_aml_dtb=$WORK/_aml_dtb.img" \
  "PARTITION:vendor=$WORK/vendor.simg:sparse" \
  "PARTITION:system=$WORK/system.simg:sparse" \
  "PARTITION:product=$WORK/product.simg:sparse"
