#!/usr/bin/env python3
"""Fix SlimBOX's Autostart app (tv.autostart, /product/app/AutostartApp) crashing at every boot.

Its BootReceiver is direct-boot aware and also listens to LOCKED_BOOT_COMPLETED, which Android
sends before the user's credential-encrypted storage is unlocked; onReceive() then reads the
app's settings (default SharedPreferences, in that storage) and throws IllegalStateException
("SharedPreferences in credential encrypted storage are not available until after user is
unlocked"): the app crashes once per boot. Its work (start the chosen app, start
AutostartService) needs those settings anyway and is done on BOOT_COMPLETED, which follows the
unlock. Now onReceive() returns at once while the user is still locked.

  baksmali classes2.dex -> the start of BootReceiver.onReceive() (the expected code is checked)
  -> smali -> the new classes2.dex in the APK.

The APK keeps SlimBOX's signature, see apkpatch.py.

usage: make_autostart_locked_boot.py <AutostartApp.apk from the SlimBOX system image> <out.apk>
"""
import hashlib
import os
import sys

from apkpatch import patch_apk, replace_text

APK_MD5 = 'cefe994b52c1f12353fb26fbf394137d'          # SlimBOX 9.20
CLASS = 'tv/autostart/BootReceiver.smali'
OLD = """.method public onReceive(Landroid/content/Context;Landroid/content/Intent;)V
    .registers 12

    invoke-static {p1}, Landroidx/preference/PreferenceManager;->getDefaultSharedPreferences(Landroid/content/Context;)Landroid/content/SharedPreferences;
"""
# v0 is free here (the method sets it next)
NEW = """.method public onReceive(Landroid/content/Context;Landroid/content/Intent;)V
    .registers 12

    const-string v0, "user"

    invoke-virtual {p1, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v0

    check-cast v0, Landroid/os/UserManager;

    invoke-virtual {v0}, Landroid/os/UserManager;->isUserUnlocked()Z

    move-result v0

    if-nez v0, :rombica_unlocked

    return-void

    :rombica_unlocked
    invoke-static {p1}, Landroidx/preference/PreferenceManager;->getDefaultSharedPreferences(Landroid/content/Context;)Landroid/content/SharedPreferences;
"""


def edit(smali_dir):
    replace_text(os.path.join(smali_dir, CLASS), OLD, NEW)


def main(src, dst):
    assert hashlib.md5(open(src, 'rb').read()).hexdigest() == APK_MD5, \
        'not the SlimBOX 9.20 AutostartApp.apk'
    patch_apk(src, dst, edit, dex='classes2.dex')
    print('Autostart app waiting for the user unlock: %s' % dst)


if __name__ == '__main__':
    main(*sys.argv[1:3])
