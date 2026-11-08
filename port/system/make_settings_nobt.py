#!/usr/bin/env python3
"""Fix SlimBOX's phone Settings app (/system/priv-app/Settings, "Advanced settings") for a board
without Bluetooth.

Android 9's "Connected devices" screen is made for devices with Bluetooth: without it, one
controller after another dereferences the missing LocalBluetoothManager or its preference group
(NullPointerExceptions in AvailableMediaDeviceGroupController.onStart(), then
ConnectedDeviceGroupController.onDeviceRemoved() via the USB updater, ...). Settings itself
decides which of its screens exist from the device features (SettingsActivity.doUpdateTilesList()
enables or disables their components): the Bluetooth screen goes without the Bluetooth feature,
"Connected devices" only in demo mode. Here it also goes without Bluetooth, so the app no longer
offers a screen it cannot show (no action at boot needed: Settings applies it whenever it starts).

  baksmali classes.dex -> the condition in doUpdateTilesList() (the expected code is checked)
  -> smali -> the new classes.dex in the APK.

The APK keeps SlimBOX's signature, see apkpatch.py.

usage: make_settings_nobt.py <Settings.apk from the SlimBOX system image> <out.apk>
"""
import hashlib
import os
import sys

from apkpatch import patch_apk, replace_text

APK_MD5 = '9f652809700919d75ab851c3b0bd8ff5'          # SlimBOX 9.20 (ATV and AOSP builds)
CLASS = 'com/android/settings/SettingsActivity.smali'
# SettingsActivity.doUpdateTilesList(): the "Connected devices" tile (component) is enabled when
# the device is not in demo mode ...
OLD = """    const-class v11, Lcom/android/settings/Settings$ConnectedDeviceDashboardActivity;

    invoke-virtual {v11}, Ljava/lang/Class;->getName()Ljava/lang/String;

    move-result-object v11

    invoke-direct {v8, v6, v11}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    invoke-static/range {p0 .. p0}, Landroid/os/UserManager;->isDeviceInDemoMode(Landroid/content/Context;)Z

    move-result v11

    xor-int/2addr v11, v10
"""
# ... and now only if it also has Bluetooth (v2: the PackageManager, v10: 1), as the tile
# of the Bluetooth screen above it in the same method
NEW = """    const-class v11, Lcom/android/settings/Settings$ConnectedDeviceDashboardActivity;

    invoke-virtual {v11}, Ljava/lang/Class;->getName()Ljava/lang/String;

    move-result-object v11

    invoke-direct {v8, v6, v11}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    const-string v11, "android.hardware.bluetooth"

    invoke-virtual {v2, v11}, Landroid/content/pm/PackageManager;->hasSystemFeature(Ljava/lang/String;)Z

    move-result v11

    if-eqz v11, :rombica_no_bluetooth

    invoke-static/range {p0 .. p0}, Landroid/os/UserManager;->isDeviceInDemoMode(Landroid/content/Context;)Z

    move-result v11

    xor-int/2addr v11, v10

    :rombica_no_bluetooth
"""




def edit(smali_dir):
    replace_text(os.path.join(smali_dir, CLASS), OLD, NEW)


def main(src, dst):
    assert hashlib.md5(open(src, 'rb').read()).hexdigest() == APK_MD5, \
        'not the SlimBOX 9.20 Settings.apk'
    patch_apk(src, dst, edit)
    print('Settings without a "Connected devices" screen when there is no Bluetooth: %s' % dst)


if __name__ == '__main__':
    main(*sys.argv[1:3])
