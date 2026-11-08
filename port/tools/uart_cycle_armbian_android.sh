#!/bin/bash
# Warm-reboot round trips Android -> Armbian (microSD boot menu, no key) -> Android, the path that
# used to leave Android without eMMC ("error -110 whilst initialising MMC card"). Armbian is left
# with "systemctl reboot"; U-Boot is stopped over the two-way UART and Android started with
# "run storeboot". Needs uart_capture.sh writing <uart.log>, sshpass, root password of Armbian
# in $SSHPASS, both systems on the same IP (same Wi-Fi MAC).
#
# usage: SSHPASS=<pw> uart_cycle_armbian_android.sh <ip> <uart.log> <rounds> [tty=/dev/ttyUSB0]
set -u
IP="$1"; LOG="$2"; N="$3"; TTY="${4:-/dev/ttyUSB0}"; SER="$IP:5555"
O=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3)
android_up() { timeout 5 adb connect "$SER" >/dev/null 2>&1
               [ "$(timeout 5 adb -s "$SER" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; }
for r in $(seq 1 "$N"); do
    # Android -> Armbian
    (timeout 15 adb -s "$SER" reboot >/dev/null 2>&1 &)
    t0=$SECONDS; until timeout 6 sshpass -e ssh "${O[@]}" root@"$IP" true 2>/dev/null; do
        sleep 3; [ $((SECONDS - t0)) -gt 240 ] && { echo "round $r: Armbian did not come up"; exit 2; }; done
    sleep 15
    # Armbian -> U-Boot prompt -> Android
    start=$(wc -c < "$LOG")
    (timeout 10 sshpass -e ssh "${O[@]}" root@"$IP" 'systemctl reboot' >/dev/null 2>&1 &)
    exec 3>"$TTY"; t0=$SECONDS
    while [ $((SECONDS - t0)) -lt 120 ]; do
        printf ' ' >&3; sleep 0.05
        tail -c +"$start" "$LOG" | grep -aq "gxl_p271_v1#" && break
    done
    sleep 0.5; printf '\rrun storeboot\r' >&3; exec 3>&-
    t0=$SECONDS; res=TIMEOUT
    while [ $((SECONDS - t0)) -lt 240 ]; do
        sleep 3
        if tail -c +"$start" "$LOG" | grep -aq "error -110 whilst initialising MMC card"; then res=EMMC_FAIL; break; fi
        if android_up; then res=OK; break; fi
    done
    mangled=$(tail -c +"$start" "$LOG" | grep -ac "0xc01[0-9a-f]\{5\}_\|0xc01[0-9a-f]\{5\}: V4L2\|dmode 0xc")
    echo "round $r: $res (mangled strings: $mangled)"
    [ "$res" = OK ] || exit 1
    sleep 15
done
