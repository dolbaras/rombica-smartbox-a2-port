#!/bin/bash
# Run CodecTest over media files already on the box: every file with the system's default decoder
# and with each other decoder that claims its MIME type.
# usage: run_codectest.sh <dir on the box, e.g. /sdcard/codec>      env: ADB (default "adb")
ADB=${ADB:-adb}
DIR="$1"
$ADB logcat -c
$ADB shell am start -W -n ru.rombica.codectest/.TestActivity --es list 1 >/dev/null
sleep 2
codecs=$($ADB logcat -d -s CODECTEST | sed -n 's/.*CODEC \([^ ]*\) \(.*\)/\2 \1/p' | tr -d '\r')
run() {   # run <file> [codec]
    $ADB logcat -c
    $ADB shell am start -W -n ru.rombica.codectest/.TestActivity --es file "$1" ${2:+--es codec "$2"} >/dev/null
    for _ in $(seq 1 70); do
        r=$($ADB logcat -d -s CODECTEST | grep -m1 RESULT) && break
        sleep 1
    done
    echo "${r#*RESULT }" | tr -d '\r'
    $ADB shell am force-stop ru.rombica.codectest
    sleep 1
}
for f in $($ADB shell ls "$DIR" | tr -d '\r'); do
    run "$DIR/$f"
    mime=$($ADB logcat -d -s CODECTEST | grep -m1 RESULT | grep -o 'mime=[^ ]*' | cut -d= -f2 | tr -d '\r')
    [ -n "$mime" ] || continue
    for c in $(echo "$codecs" | awk -v m="$mime" '$1==m {print $2}'); do
        case "$c" in *.secure) continue ;; esac
        run "$DIR/$f" "$c"
    done
done
