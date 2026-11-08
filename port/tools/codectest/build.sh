#!/bin/bash
# Build CodecTest.apk (developer tool) with the Android SDK used by port/apps/build_apps.sh.
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)"; SDK="${ANDROID_SDK:-$HOME/build/rombica-smartbox-a2/android-sdk}"
[ -x "$SDK/jdk17/bin/javac" ] && export JAVA_HOME="$SDK/jdk17" PATH="$SDK/jdk17/bin:$PATH"
BT="$SDK/build-tools/30.0.3"; AJ="$SDK/platforms/android-28/android.jar"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$BT/aapt2" compile --dir "$B/res" -o "$W/r.zip"
"$BT/aapt2" link -o "$W/a.apk" -I "$AJ" --manifest "$B/AndroidManifest.xml" --java "$W/gen" "$W/r.zip"
mkdir "$W/c" "$W/d"
mapfile -d '' S < <(find "$B/src" "$W/gen" -name '*.java' -print0)
javac -encoding UTF-8 -source 8 -target 8 -Xlint:-options -bootclasspath "$AJ" -d "$W/c" "${S[@]}"
mapfile -d '' C < <(find "$W/c" -name '*.class' -print0)
"$BT/d8" --release --min-api 28 --lib "$AJ" --output "$W/d" "${C[@]}"
(cd "$W/d" && zip -q -j "$W/a.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$W/a.apk" "$W/b.apk"
"$BT/apksigner" sign --ks "$B/../../apps/keys/rombica_apps.jks" --ks-pass pass:rombica-a2 \
    --out "$B/CodecTest.apk" "$W/b.apk"
rm -f "$B/CodecTest.apk.idsig"
ls -l "$B/CodecTest.apk"
