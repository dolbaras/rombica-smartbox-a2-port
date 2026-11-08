#!/bin/bash
# Build the MediaCodec probes and run one on the box over adb (no app needed, app_process):
#   McTest  ByteBuffer decoding: colour formats, output format, fps, latency, frames in flight
#   McSurf  decoding into a SurfaceTexture (as a Flutter texture is fed), one frame read back with GL
# usage: run_probe.sh McTest list
#        run_probe.sh McTest /data/local/tmp/mct/h264.mp4 OMX.amlogic.avc.decoder.awesome real 30 idx vendor.low-latency.enable=1
#        run_probe.sh McSurf /data/local/tmp/mct/hevc.mp4 OMX.amlogic.hevc.decoder.awesome 30 45
# test streams: ffmpeg -f lavfi -i testsrc2=s=1920x1080:r=30 -t 10 -c:v libx264 \
#   -x264-params bframes=0:keyint=300:sliced-threads=0 -pix_fmt yuv420p h264.mp4; adb push to /data/local/tmp/mct/
# env: ANDROID_SDK (default ~/build/rombica-smartbox-a2/android-sdk, build-tools 30.0.3, platform 28, jdk17)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK:-$HOME/build/rombica-smartbox-a2/android-sdk}"
AJ="$SDK/platforms/android-28/android.jar"
[ -x "$SDK/jdk17/bin/javac" ] && export PATH="$SDK/jdk17/bin:$PATH"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir "$W/cls" "$W/dex"
javac -nowarn -source 8 -target 8 -bootclasspath "$AJ" -classpath "$AJ" -d "$W/cls" "$HERE"/*.java 2>/dev/null
"$SDK/build-tools/30.0.3/d8" --release --min-api 28 --lib "$AJ" --output "$W/dex" "$W"/cls/*.class
adb shell mkdir -p /data/local/tmp/mct
adb push "$W/dex/classes.dex" /data/local/tmp/mct/ >/dev/null
adb shell "CLASSPATH=/data/local/tmp/mct/classes.dex app_process /system/bin $*"
