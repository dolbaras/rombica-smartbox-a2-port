#!/bin/bash
# Build the Rombica SmartBox A2 Armbian image from ophub's S905L2 image, with everything this folder
# describes (README.md): board DTB, microSD boot menu (Android / Armbian), Wi-Fi (patched brcmfmac,
# AP6181 firmware + nvram), sound, remote, front LED (driver + udev), zram, and for the desktop variant Xfce,
# Thorium + enhanced-h264ify, yt-play (hardware H.264), remote mouse mode and the LED window.
#
# usage: sudo build_image.sh <Armbian_*_amlogic_s905l2_*_server_*.img.gz> <server|desktop> <out.img>
#   env: THORIUM_DEB=<thorium-browser_*_arm64.deb>   (desktop)
#        YTDLP=<yt-dlp zipapp>                         (desktop, optional: else downloaded)
#        E2FSPROGS=<e2fsprogs >= 1.47 build dir>       (desktop, if the host's e2fsprogs are older)
# needs: root; on x86 qemu-user-static + binfmt (arm64 chroot); parted, e2fsprogs, rsync, curl
# The modules in modules/ are built for ophub's kernel 6.18.51 by build_modules.sh; another
# kernel needs them rebuilt.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$1"; VARIANT="$2"; OUT="$(realpath -m "$3")"
KVER=6.18.51-ophub
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
case "$VARIANT" in server|desktop) ;; *) echo "variant: server or desktop"; exit 1 ;; esac
[ -d "$HERE/modules/$KVER/brcmfmac" ] || { echo "no brcmfmac modules for $KVER"; exit 1; }
if [ "$VARIANT" = desktop ]; then
    [ -f "${THORIUM_DEB:-}" ] || { echo "set THORIUM_DEB"; exit 1; }
fi

echo "== image ($VARIANT)"
zcat "$BASE" > "$OUT"
if [ "$VARIANT" = desktop ]; then         # Xfce + Thorium need ~2.5 GB more than the server image
    truncate -s +3G "$OUT"
    parted -s "$OUT" resizepart 2 100%
fi
L=$(losetup -fP --show "$OUT")
R=$(mktemp -d)
cleanup() {
    set +e
    for m in dev/pts dev proc sys boot; do mountpoint -q "$R/$m" && umount "$R/$m"; done
    mountpoint -q "$R" && umount "$R"
    losetup -d "$L"; rmdir "$R"
}
trap cleanup EXIT
if [ "$VARIANT" = desktop ]; then
    # the image's ext4 uses features (orphan_file) that e2fsprogs older than 1.47 refuse:
    # E2FSPROGS=<built e2fsprogs source dir> when the host's are older
    E2FSCK=e2fsck; RESIZE2FS=resize2fs
    [ -n "${E2FSPROGS:-}" ] && { E2FSCK="$E2FSPROGS/e2fsck/e2fsck"; RESIZE2FS="$E2FSPROGS/resize/resize2fs"; }
    "$E2FSCK" -fy "${L}p2" >/dev/null || [ $? -le 1 ] || { echo "e2fsck failed"; exit 1; }
    "$RESIZE2FS" "${L}p2" >/dev/null
fi
mount "${L}p2" "$R"; mount "${L}p1" "$R/boot"
[ -f "$R/root/.not_logged_in_yet" ] || { echo "base image without the Armbian first-login marker"; exit 1; }

echo "== boot partition: DTB, boot menu, no mainline U-Boot"
B="$R/boot"
# mainline U-Boot (u-boot.ext) cannot read the microSD on S905L2; our U-Boot boots the kernel itself
[ -f "$B/u-boot.ext" ] && mv "$B/u-boot.ext" "$B/u-boot.ext.disabled"
install -m 644 "$HERE/meson-gxl-s905l2-rombica-a2.dtb" "$B/dtb/amlogic/"
grep -q '^FDT=' "$B/uEnv.txt" || { echo "uEnv.txt without FDT="; exit 1; }
sed -i 's|^FDT=.*|FDT=/dtb/amlogic/meson-gxl-s905l2-rombica-a2.dtb|' "$B/uEnv.txt"
install -m 644 "$HERE/bootmenu/s905_autoscript" "$HERE/bootmenu/s905_autoscript.cmd" \
    "$HERE/bootmenu/bootmenu.bmp" "$HERE/bootmenu/bootmenu_android.bmp" \
    "$HERE/bootmenu/bootmenu_armbian.bmp" "$B/"

echo "== system files"
# Wi-Fi: AP6181 nvram and the Android firmware 5.90.195 (linux-firmware's 5.90.247 stops passing
# the WPA handshake), patched brcmfmac (OOB interrupt without wake)
install -m 644 "$HERE/brcmfmac43362-sdio.rombica,smartbox-a2.txt" "$R/lib/firmware/brcm/"
install -m 644 "$HERE/../../device_info/wifi_40181/fw_bcm40181a2.bin" \
    "$R/lib/firmware/brcm/brcmfmac43362-sdio.rombica,smartbox-a2.bin"
# modules built for ophub's kernel (build_modules.sh): patched brcmfmac, front LED driver
mkdir -p "$R/lib/modules/$KVER/updates"
rsync -a "$HERE/modules/$KVER/" "$R/lib/modules/$KVER/updates/"
# front LED: the trigger of each colour from /etc/rombica-led/led.conf, set by udev
install -m 644 "$HERE/files/90-rombica-led.rules" "$R/etc/udev/rules.d/"
mkdir -p "$R/etc/rombica-led"
install -m 664 "$HERE/led.conf" "$R/etc/rombica-led/led.conf"
chgrp 100 "$R/etc/rombica-led" "$R/etc/rombica-led/led.conf"     # users: the LED window
chmod 2775 "$R/etc/rombica-led"
# Wi-Fi: NetworkManager keeps trying a saved network; USB gadget (developer aid, not enabled)
install -m 644 "$HERE/files/90-rombica-wifi.conf" "$R/etc/NetworkManager/conf.d/"
install -m 755 "$HERE/usb-gadget" "$R/usr/local/sbin/"
install -m 644 "$HERE/usb-gadget.service" "$R/etc/systemd/system/"
# the display mode is the monitor's or TV's own (EDID); ophub's command line forced 1080p
sed -i 's/ video=HDMI-A-1:[^ ]*//' "$B/uEnv.txt"
# sound route (HDMI + AV), zram, sysctl, remote key map
install -m 644 "$HERE/files/asound.state" "$R/var/lib/alsa/asound.state"
install -m 644 "$HERE/files/80-multihome.conf" "$HERE/files/90-zram.conf" "$R/etc/sysctl.d/"
mkdir -p "$R/etc/rc_keymaps"
install -m 644 "$HERE/rombica_a2.toml" "$R/etc/rc_keymaps/"
# the first-login wizard runs on every autologin console and the first one wins; on this box the
# HDMI screen is the console people see, so no root autologin on the serial port (UART pads)
rm -f "$R/etc/systemd/system/serial-getty@.service.d/override.conf"
echo "rombica-a2" > "$R/etc/hostname"
sed -i 's/\barmbian\b/rombica-a2/g' "$R/etc/hosts"

echo "== packages (arm64 chroot)"
for m in dev dev/pts proc sys; do mount --bind "/$m" "$R/$m"; done
mv "$R/etc/resolv.conf" "$R/etc/resolv.conf.build"; cp /etc/resolv.conf "$R/etc/resolv.conf"
CH() { chroot "$R" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"; }
CH apt-get update -q >/dev/null
CH apt-get install -y -q --no-install-recommends zram-tools ir-keytable python3 >/dev/null
install -m 644 "$HERE/files/zramswap" "$R/etc/default/zramswap"
if ! grep -q rombica_a2.toml "$R/etc/rc_maps.cfg"; then
    { printf '# Rombica SmartBox A2 remote (NEC 0x4040)\nmeson-ir\t*\trombica_a2.toml\n'
      cat "$R/etc/rc_maps.cfg"; } > "$R/etc/rc_maps.cfg.new"
    mv "$R/etc/rc_maps.cfg.new" "$R/etc/rc_maps.cfg"
fi

if [ "$VARIANT" = desktop ]; then
    echo "== desktop"
    CH apt-get install -y -q --no-install-recommends \
        xserver-xorg xinit libgl1-mesa-dri libegl1 libgles2 \
        xfce4 xfce4-terminal xfce4-xkb-plugin xfce4-pulseaudio-plugin xfce4-notifyd xfce4-taskmanager \
        lightdm lightdm-gtk-greeter pulseaudio pavucontrol network-manager-gnome dbus-x11 \
        policykit-1 xdg-utils fonts-dejavu-core \
        mpv ffmpeg xclip libnotify-bin python3-evdev python3-gi gir1.2-gtk-3.0 >/dev/null
    cp "$THORIUM_DEB" "$R/tmp/thorium.deb"
    CH apt-get install -y -q /tmp/thorium.deb >/dev/null
    rm -f "$R/tmp/thorium.deb"
    # Thorium: enhanced-h264ify (no AV1/VP9 from YouTube) and the "▶ HW" bookmark (yt-play)
    mkdir -p "$R/etc/chromium/policies/managed"
    install -m 644 "$HERE/files/rombica-h264ify.json" "$HERE/files/rombica-bookmarks.json" \
        "$R/etc/chromium/policies/managed/"
    install -m 644 "$HERE/files/thorium-browser.helper.desktop" \
        "$R/usr/share/xfce4/helpers/thorium-browser.desktop"
    # YouTube with hardware H.264, remote mouse mode, LED window
    if [ -f "${YTDLP:-}" ]; then install -m 755 "$YTDLP" "$R/usr/local/bin/yt-dlp"
    else curl -sfL -o "$R/usr/local/bin/yt-dlp" https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
         chmod 755 "$R/usr/local/bin/yt-dlp"; fi
    install -m 755 "$HERE/yt-play" "$HERE/rombica-led-settings" "$R/usr/local/bin/"
    install -m 755 "$HERE/rc-mouse" "$R/usr/local/sbin/"
    install -m 644 "$HERE/rc-mouse.service" "$R/etc/systemd/system/"
    install -m 644 "$HERE/yt-play.desktop" "$HERE/rombica-led-settings.desktop" "$R/usr/share/applications/"
    printf '[Default Applications]\nx-scheme-handler/ytplay=yt-play.desktop\n' >> "$R/etc/xdg/mimeapps.list"
    # display: software cursor; 1 GB swap file on first boot (1 GB RAM)
    mkdir -p "$R/etc/X11/xorg.conf.d"
    install -m 644 "$HERE/files/20-meson-display.conf" "$R/etc/X11/xorg.conf.d/"
    install -m 755 "$HERE/files/rombica-swapfile" "$R/usr/local/sbin/"
    install -m 644 "$HERE/files/rombica-swapfile.service" "$R/etc/systemd/system/"
    # keyboard us/ru (Alt+Shift), the panel / wallpaper / workspace setup for new users
    install -m 644 "$HERE/files/keyboard" "$R/etc/default/keyboard"
    cp -a "$HERE/files/skel/." "$R/etc/skel/"
    CH systemctl enable rc-mouse.service rombica-swapfile.service >/dev/null 2>&1
    # Armbian's first-login wizard creates the user, sets LightDM autologin (user-session=xfce) and
    # starts LightDM itself; until then the console shows the wizard. Keep the autologin afterwards.
    rm -f "$R/etc/systemd/system/display-manager.service"
    touch "$R/root/.desktop_autologin"
fi

CH depmod -a "$KVER"
CH apt-get clean
rm -f "$R/etc/resolv.conf"; mv "$R/etc/resolv.conf.build" "$R/etc/resolv.conf"
rm -rf "$R/var/lib/apt/lists/"*_dists_* "$R/root/.bash_history"
echo "rombica-a2 $VARIANT, built $(date -u +%F) from $(basename "$BASE")" > "$R/etc/rombica-a2-image"
sync
echo "== root filesystem: $(df -h --output=used,avail "$R" | tail -1)"
echo "built $OUT ($VARIANT)"
