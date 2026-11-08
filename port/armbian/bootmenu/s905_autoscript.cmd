echo "Rombica SmartBox A2: microSD boot (Armbian), boot menu"
if fatload mmc 0 ${loadaddr} boot_android; then if test ${ab} = 0; then setenv ab 1; saveenv; exit; else setenv ab 0; saveenv; fi; fi;
if fatload usb 0 ${loadaddr} boot_android; then if test ${ab} = 0; then setenv ab 1; saveenv; exit; else setenv ab 0; saveenv; fi; fi;
setenv irkey_value none
if fatload mmc 0 ${loadaddr} bootmenu.bmp; then osd open; osd clear; bmp display ${loadaddr}; bmp scale; fi;
if irkey 10000000 0xef104040 0xee114040 0xf20d4040; then echo "remote key ${irkey_value}"; fi;
if test "${irkey_value}" != "0xee114040"; then echo "boot menu: Android"; if fatload mmc 0 ${loadaddr} bootmenu_android.bmp; then bmp display ${loadaddr}; bmp scale; sleep 1; fi; osd clear; exit; fi;
echo "boot menu: Armbian"
if fatload mmc 0 ${loadaddr} bootmenu_armbian.bmp; then bmp display ${loadaddr}; bmp scale; fi;
setenv kernel_addr_r 0x11000000
setenv ramdisk_addr_r 0x15000000
setenv fdt_addr_r 0x1000000
setenv l_mmc "0"
for devtype in "mmc usb" ; do if test "${devtype}" = "usb"; then echo "start test usb"; setenv l_mmc "0 1 2 3"; fi; for devnum in ${l_mmc} ; do if test -e ${devtype} ${devnum} uEnv.txt; then fatload ${devtype} ${devnum} ${loadaddr} uEnv.txt; env import -t ${loadaddr} ${filesize}; setenv bootargs ${APPEND}; if printenv mac; then setenv bootargs ${bootargs} mac=${mac}; elif printenv eth_mac; then setenv bootargs ${bootargs} mac=${eth_mac}; fi; if fatload ${devtype} ${devnum} ${kernel_addr_r} ${LINUX}; then if fatload ${devtype} ${devnum} ${ramdisk_addr_r} ${INITRD}; then if fatload ${devtype} ${devnum} ${fdt_addr_r} ${FDT}; then fdt addr ${fdt_addr_r}; booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}; fi; fi; fi; fi; done; done;
