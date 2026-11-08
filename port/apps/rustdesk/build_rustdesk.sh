#!/bin/bash
# Build RustDesk for the Rombica A2 (armeabi-v7a) with hardware H.264/H.265 decoding
# through Android MediaCodec (see README.md and patches/).
#
# Tool versions follow RustDesk's own CI (.github/workflows/flutter-build.yml and
# bridge.yml of the tag). Everything big lives outside the project:
# env:   RD_BUILD     sources, toolchains, vcpkg, build output (default ~/build/rombica-smartbox-a2/rustdesk, ~25 GB)
#        ANDROID_SDK  Android SDK with cmdline-tools and jdk17 (default ~/build/rombica-smartbox-a2/android-sdk)
# needs: apt clang libclang-dev llvm-dev nasm ninja-build cmake pkg-config libgtk-3-dev, rustup
# out:   out/rustdesk-$VERSION-a2hw-armeabi-v7a.apk, signed with ../keys/rombica_apps.jks
set -e -o pipefail

VERSION=1.4.9
FLUTTER_VERSION=3.24.5
NDK_VERSION=r28c
VCPKG_COMMIT=120deac3062162151622ca4860575a33844ba10b
RUST_VERSION=1.75
CARGO_NDK_VERSION=3.1.2
CARGO_EXPAND_VERSION=1.0.95
BRIDGE_VERSION=1.80.1

HERE="$(cd "$(dirname "$0")" && pwd)"
RB="${RD_BUILD:-$HOME/build/rombica-smartbox-a2/rustdesk}"
SDK="${ANDROID_SDK:-$HOME/build/rombica-smartbox-a2/android-sdk}"
SRC="$RB/rustdesk"
KS="$HERE/../keys/rombica_apps.jks"
[ -f "$KS" ] || { echo "no signing key $KS: apps/build_apps.sh creates one"; exit 1; }
mkdir -p "$RB" "$HERE/out"

export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
export ANDROID_NDK_HOME="$RB/android-ndk-$NDK_VERSION" ANDROID_NDK_ROOT="$RB/android-ndk-$NDK_VERSION"
export VCPKG_ROOT="$RB/vcpkg"
export JAVA_HOME="$SDK/jdk17"
export PATH="$RB/flutter/bin:$HOME/.cargo/bin:$JAVA_HOME/bin:$PATH"

echo "== sources and toolchains"
[ -d "$SRC" ] || git clone -q --depth 1 --branch "$VERSION" --recursive --shallow-submodules \
    https://github.com/rustdesk/rustdesk.git "$SRC"
if [ ! -d "$RB/flutter" ]; then
    git clone -q --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$RB/flutter"
    git -C "$RB/flutter" apply "$SRC/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
    flutter config --no-analytics      # the SDK comes from ANDROID_HOME, not the global flutter config
fi
if [ ! -d "$ANDROID_NDK_HOME" ]; then
    curl -sSL -o "$RB/ndk.zip" "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip"
    unzip -q -d "$RB" "$RB/ndk.zip" && rm "$RB/ndk.zip"
fi
if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    git clone -q https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
    git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT"
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
fi
rustup toolchain install "$RUST_VERSION" --profile minimal -c rustfmt -t armv7-linux-androideabi
rustup override set "$RUST_VERSION" --path "$SRC"
has() { cargo install --list | grep -q "^$1 v$2:"; }
has cargo-ndk "$CARGO_NDK_VERSION" || cargo +"$RUST_VERSION" install cargo-ndk --version "$CARGO_NDK_VERSION" --locked
has cargo-expand "$CARGO_EXPAND_VERSION" || cargo +"$RUST_VERSION" install cargo-expand --version "$CARGO_EXPAND_VERSION" --locked
has flutter_rust_bridge_codegen "$BRIDGE_VERSION" ||
    cargo +"$RUST_VERSION" install flutter_rust_bridge_codegen --version "$BRIDGE_VERSION" --features uuid --locked
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" "platforms;android-34" "build-tools;34.0.0" >/dev/null

echo "== patches"
cd "$SRC"
for p in "$HERE"/patches/*.patch; do
    if git apply --check "$p" 2>/dev/null; then
        git apply "$p" && echo "applied $(basename "$p")"
    else
        git apply --reverse --check "$p" && echo "already applied $(basename "$p")"
    fi
done

echo "== vcpkg dependencies (ffmpeg, libvpx, aom, opus, ...)"
[ -d "$VCPKG_ROOT/installed/arm-android" ] || ./flutter/build_android_deps.sh armeabi-v7a

echo "== flutter <-> rust bridge"
(cd flutter && flutter pub get)
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
    --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h

echo "== librustdesk.so"
cargo ndk --platform 21 --target armv7-linux-androideabi build --locked --release \
    --features flutter,hwcodec,mediacodec
JNI=flutter/android/app/src/main/jniLibs/armeabi-v7a
mkdir -p "$JNI"
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/libc++_shared.so" "$JNI/"
cp target/armv7-linux-androideabi/release/liblibrustdesk.so "$JNI/librustdesk.so"

echo "== apk"
# java.util.Properties reads ISO-8859-1: escape the non-ASCII path as \uXXXX
python3 - "$KS" > flutter/android/key.properties <<'EOF'
import sys
esc = lambda s: ''.join(c if ord(c) < 128 else '\\u%04x' % ord(c) for c in s)
print('storeFile=' + esc(sys.argv[1]))
print('storePassword=rombica-a2\nkeyAlias=rombica\nkeyPassword=rombica-a2')
EOF
(cd flutter && flutter build apk --release --target-platform android-arm --split-per-abi)
OUT="$HERE/out/rustdesk-$VERSION-a2hw-armeabi-v7a.apk"
cp flutter/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk "$OUT"
sha256sum "$OUT"
