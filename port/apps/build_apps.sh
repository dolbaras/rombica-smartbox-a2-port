#!/bin/bash
# Build the Rombica A2 vendor apps without Gradle (Android SDK build-tools 30.0.3, platform 28):
#   RombicaIndicator.apk      front LED settings + port version/changelog (ru.rombica.indicator)
#   RombicaTvSettings.apk     static resource overlay for TvSettings: Bluetooth entry -> Indicator,
#                             "project slimBOXtv" screen: port version/changelog entry, no SlimBOX patches
#
# usage: build_apps.sh <TvSettings.apk from the SlimBOX system image> <out_dir>
# env:   ANDROID_SDK (default ~/build/rombica-smartbox-a2/android-sdk); a JDK in $ANDROID_SDK/jdk17 is used if present
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TVS="$(realpath "$1")"; OUT="$(realpath -m "$2")"
SDK="${ANDROID_SDK:-$HOME/build/rombica-smartbox-a2/android-sdk}"
[ -x "$SDK/jdk17/bin/javac" ] && export JAVA_HOME="$SDK/jdk17" PATH="$SDK/jdk17/bin:$PATH"
BT="$SDK/build-tools/30.0.3"; AJ="$SDK/platforms/android-28/android.jar"
KS="$HERE/keys/rombica_apps.jks"; KSPASS="pass:rombica-a2"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"

if [ ! -f "$KS" ]; then          # own signing key, created once and kept in the project
    mkdir -p "$HERE/keys"
    keytool -genkeypair -keystore "$KS" -storepass rombica-a2 -keypass rombica-a2 -alias rombica \
        -keyalg RSA -keysize 2048 -validity 36500 \
        -dname "CN=Rombica SmartBox A2 port, O=Dolbaras" >/dev/null 2>&1
fi
sign() {  # sign <unsigned.apk> <out.apk>
    "$BT/zipalign" -f -p 4 "$1" "$1.aligned"
    "$BT/apksigner" sign --ks "$KS" --ks-pass "$KSPASS" --out "$2" "$1.aligned"
}

echo "== Indicator app"
A="$HERE/indicator"
"$BT/aapt2" compile --dir "$A/res" -o "$W/ind_res.zip"
"$BT/aapt2" link -o "$W/ind.apk" -I "$AJ" --manifest "$A/AndroidManifest.xml" \
    --java "$W/gen" "$W/ind_res.zip"
mkdir -p "$W/classes" "$W/dex" "$W/stubs"
# compile-time stubs of the device's droidlogic.jar (not packaged, see indicator/stubs)
mapfile -d '' STUBS < <(find "$A/stubs" -name '*.java' -print0)
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$AJ" -d "$W/stubs" -Xlint:-options "${STUBS[@]}"
mapfile -d '' SRCS < <(find "$A/src" "$W/gen" -name '*.java' -print0)
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$AJ" -classpath "$AJ:$W/stubs" \
    -d "$W/classes" -Xlint:-options "${SRCS[@]}"
mapfile -d '' CLS < <(find "$W/classes" -name '*.class' -print0)
"$BT/d8" --release --min-api 28 --lib "$AJ" --output "$W/dex" "${CLS[@]}"
# fixed time and no extra attributes: the same sources give the same APK
(cd "$W/dex" && touch -t 198001010000 classes.dex && TZ=UTC zip -q -X -j "$W/ind.apk" classes.dex)
sign "$W/ind.apk" "$OUT/RombicaIndicator.apk"

echo "== TvSettings overlay"
O="$HERE/tvsettings_overlay"
"$BT/aapt2" compile --dir "$O/res" -o "$W/ovl_res.zip"
# package id 0x7e: references like @com.android.tv.settings:drawable/x compile to TvSettings' ids
"$BT/aapt2" link -o "$W/ovl.apk" -I "$AJ" -I "$TVS" --package-id 0x7e --allow-reserved-package-id \
    --manifest "$O/AndroidManifest.xml" "$W/ovl_res.zip"
sign "$W/ovl.apk" "$OUT/RombicaTvSettings.apk"
ls -l "$OUT"/*.apk
