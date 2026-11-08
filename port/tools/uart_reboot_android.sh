#!/bin/bash
# Warm-reboot the box from Android (adb) and boot Android again past the microSD boot menu:
# stop U-Boot autoboot over the two-way UART and "run storeboot". Then wait for Android to come
# up (sys.boot_completed over adb) or for the kernel eMMC init failure.
# Needs port/tools/uart_capture.sh writing <uart.log> and write access to the UART tty.
#
# usage: uart_reboot_android.sh <adb serial> <uart.log> [tty=/dev/ttyUSB0] [reboot arg]
# prints one line: OK <seconds> | EMMC_FAIL | TIMEOUT
set -u
SER="$1"; LOG="$2"; TTY="${3:-/dev/ttyUSB0}"; ARG="${4:-}"
start=$(wc -c < "$LOG")
new() { tail -c +"$start" "$LOG"; }
# adb reboot over TCP may block until the connection drops - longer than the autoboot delay
(timeout 15 adb -s "$SER" reboot $ARG >/dev/null 2>&1 &)
t0=$SECONDS
# stop autoboot: keep sending spaces until the U-Boot prompt shows (the capture log lags ~1 s
# behind, longer than the 1 s autoboot delay, so waiting for "stop autoboot" first is too late)
exec 3>"$TTY"
while [ $((SECONDS - t0)) -lt 90 ]; do
    printf ' ' >&3; sleep 0.05
    new | grep -aq "gxl_p271_v1#" && break
done
sleep 0.5; printf '\r' >&3; sleep 0.5
printf 'run storeboot\r' >&3; exec 3>&-
while [ $((SECONDS - t0)) -lt 240 ]; do
    sleep 3
    if new | grep -aq "error -110 whilst initialising MMC card"; then echo EMMC_FAIL; exit 1; fi
    timeout 5 adb connect "$SER" >/dev/null 2>&1
    if [ "$(timeout 5 adb -s "$SER" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
        echo "OK $((SECONDS - t0))"; exit 0
    fi
done
echo TIMEOUT; exit 2
