#!/bin/bash
# Make the Rombica SmartBox A2 DTB for ophub Armbian from ophub's meson-gxl-s905l2-x7-5g.dtb:
# the S905L2 HDMI transmitter is the GXL one (registers at 0xc883a000), ophub's DTB describes it
# as G12A (0xda800000) and the driver fails with "Unsupported HDMI controller".
# Also: Wi-Fi (AP6181), SDIO 50 MHz, USB OTG, own board compatible, eMMC off, GPU up to 744 MHz,
# front LED (details below).
# usage: make_dtb.sh <meson-gxl-s905l2-x7-5g.dtb> <out.dtb>          needs: dtc
set -euo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
dtc -q -I dtb -O dts -o "$W/in.dts" "$1"
python3 - "$W/in.dts" <<'PY'
import re
import sys
f = sys.argv[1]; s = open(f).read()
i = s.index('hdmi-tx@c883a000 {'); j = s.index('\t\t};', i); blk = s[i:j]
nb = blk.replace('compatible = "amlogic,meson-g12a-dw-hdmi";',
                 'compatible = "amlogic,meson-gxl-dw-hdmi", "amlogic,meson-gx-dw-hdmi";')
nb, n = re.subn(r'reg = <0x0+ 0xda800000 0x0+ 0x10000>;', 'reg = <0x0 0xc883a000 0x0 0x1c>;', nb)
assert nb != blk and n == 1, 'HDMI node not as expected'
s = s[:i] + nb + s[j:]
s = s.replace('model = "Amlogic Meson GXL (S905L2) X7 5G Tv Box";', 'model = "Rombica SmartBox A2 (S905L2)";')
# own board compatible: brcmfmac looks for brcmfmac43362-sdio.<compatible>.txt (the AP6181 nvram)
# (dtc prints string lists as "a", "b" or "a\0b" depending on its version)
root = s.index('compatible = "amlogic,x7-5g')
assert root < s.index('model = '), 'root compatible not as expected'
s = s[:root] + 'compatible = "rombica,smartbox-a2' + s[root + len('compatible = "amlogic,x7-5g'):]
# Wi-Fi: the board has an AP6181 (Broadcom BCM43362); ophub's node is for a MediaTek MT7668.
# The chip signals over its out-of-band host-wake line GPIOX_7 (active high, as in the stock DTB;
# gpio-intc input 89 + 7 = 96). Without an interrupt the MMC core polls the card (~43 KB/s), and
# in-band SDIO irq (cap-sdio-irq) makes the chip stop responding on this board. The stock
# brcmfmac refuses the OOB line because the Amlogic gpio-intc cannot enable_irq_wake; our patched
# module (brcmfmac-oob-irq-no-wake.patch) treats that as non-fatal.
i = s.index('mmc@70000 {'); j = s.index('wifi@1 {', i); k = s.index('};', j) + 2
ph = s[s.index('"amlogic,meson-gxl-gpio-intc'):]
ph = ph[ph.index('phandle = <') + 11:ph.index('>;', ph.index('phandle = <'))]
s = s[:j] + ('wifi@1 {\n\t\t\t\t\tcompatible = "brcm,bcm4329-fmac";\n\t\t\t\t\treg = <0x1>;\n'
             '\t\t\t\t\tinterrupt-parent = <' + ph + '>;\n\t\t\t\t\tinterrupts = <0x60 0x4>;\n'
             '\t\t\t\t\tinterrupt-names = "host-wake";\n\t\t\t\t};') + s[k:]
# SDIO at 50 MHz (high speed; the UHS modes of ophub's node are for another chip)
m = s.index('max-frequency = <0x5f5e100>;', i)
assert m < s.index('mmc@72000', i)
# USB: the OTG port (usb2-phy0) is forced to host by the p212-derived dr_mode = "host" of the glue,
# so the dwc2 device controller never sees the PC. "otg": device when a PC is on the A-A cable
# (USB network + serial console for debugging), host for an OTG adapter; /sys/class/usb_role.
u = s.index('usb@d0078080 {'); d = s.index('dr_mode = "host";', u)
assert d < s.index('usb@c9100000', u)
s = s[:d] + 'dr_mode = "otg";' + s[d + len('dr_mode = "host";'):]
s = s[:m] + 'max-frequency = <0x2faf080>;' + s[m + len('max-frequency = <0x5f5e100>;'):]
# eMMC off: it holds Android, Armbian has no use for it (and armbian-install cannot wipe it).
# (The Android hang after a warm reboot, "error -110", blamed on mainline touching the eMMC at
# first, was an Android kernel bug: vsprintf, kernel patch 0009 of the port.)
e = s.index('mmc@74000 {'); st = s.index('status = "okay";', e)
assert st < e + 300, 'eMMC node not as expected'
s = s[:st] + 'status = "disabled";' + s[st + len('status = "okay";'):]
# Mali-450: the 666 and 744 MHz steps are in ophub's table but disabled, the GPU stops at 500 MHz.
# The stock and our Android kernels clock this GPU up to 744 MHz (DT tbl up to gp0_pll 744 MHz)
# at the same, fixed VDDEE (there is no GPU regulator), so enable them.
for hz in ('666666666', '744000000'):
    o = s.index('opp-%s {' % hz); d = s.index('status = "disabled";', o)
    assert d < s.index('};', o), 'GPU OPP %s not as expected' % hz
    s = s[:d] + 'status = "okay";' + s[d + len('status = "disabled";'):]
# Front LED: one bi-colour LED on GPIODV_24 (periphs bank, line 73): high = blue, low = red,
# input = off. Driver: leds-bicolor-gpio (port/armbian/leds-bicolor), a module like brcmfmac.
b = s.index('bank@4b0 {'); g = s.index('gpio-controller;', b)
assert g < s.index('};', b), 'periphs GPIO bank not as expected'
ph = s[s.index('phandle = <', g) + 11:s.index('>;', s.index('phandle = <', g))]
r = s.rindex('};')                     # end of the root node (subnodes go after its properties)
s = s[:r] + ('\tled-bicolor {\n\t\tcompatible = "rombica,bicolor-gpio-led";\n'
             '\t\tgpios = <' + ph + ' 0x49 0x0>;\n'
             '\t\thigh {\n\t\t\tlabel = "rombica:blue";\n'
             '\t\t\tlinux,default-trigger = "default-on";\n\t\t};\n'
             '\t\tlow {\n\t\t\tlabel = "rombica:red";\n\t\t};\n\t};\n') + s[r:]
open(f, 'w').write(s)
PY
dtc -q -I dts -O dtb -o "$2" "$W/in.dts"
echo "written $2"
