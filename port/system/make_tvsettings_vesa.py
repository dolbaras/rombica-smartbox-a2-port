#!/usr/bin/env python3
"""Offer PC monitor resolutions in SlimBOX's TvSettings (Display -> Screen resolution).

TvSettings' OutputUiManager offers the modes of a fixed list of TV modes (HDMI_LIST, with their
titles in HDMI_TITLE) that the sink supports (disp_cap of the HDMI driver). The list gets the
VESA modes the port's hwcomposer and systemcontrol handle (port/vendor/make_hwc_modes.py), so a
monitor's own resolutions can be chosen too; which of them are offered is still decided by
disp_cap, which the kernel builds from the sink's EDID and range limits (kernel patches
0011, 0012). Titles follow the style of the TV ones ("1080p-60hz" -> "1280x1024p-60hz").

  baksmali classes.dex -> at the end of OutputUiManager's static initializer both arrays get the
  VESA modes appended (a new private static helper, rombicaAppend) -> smali -> new classes.dex

The APK keeps SlimBOX's signature, see apkpatch.py.

usage: make_tvsettings_vesa.py <TvSettings.apk from the SlimBOX system image> <out.apk>
"""
import hashlib
import os
import sys

from apkpatch import patch_apk, replace_text

APK_MD5 = '668c965f66f6bd5b3c24827c54fd3c6a'          # SlimBOX 9.20
CLASS = 'com/android/tv/settings/display/outputmode/OutputUiManager.smali'
OUM = 'Lcom/android/tv/settings/display/outputmode/OutputUiManager;'
VESA = ['2560x1600p60hz', '2560x1440p60hz', '2560x1080p60hz', '1920x1200p60hz', '1680x1050p60hz',
        '1600x1200p60hz', '1600x900p60hz', '1440x900p60hz', '1366x768p60hz', '1360x768p60hz',
        '1280x1024p60hz', '1280x960p60hz', '1280x800p60hz', '1024x768p60hz', '800x600p60hz',
        '640x480p60hz']                                 # = the VESA modes of make_hwc_modes.py
ANCHOR = ('    sput-object v0, %s->DOLBY_VISION_TYPE:[Ljava/lang/String;\n\n    return-void\n'
          '.end method\n' % OUM)
HELPER = '''
.method private static rombicaAppend([Ljava/lang/String;[Ljava/lang/String;)[Ljava/lang/String;
    .registers 6

    array-length v0, p0

    array-length v1, p1

    add-int v2, v0, v1

    invoke-static {p0, v2}, Ljava/util/Arrays;->copyOf([Ljava/lang/Object;I)[Ljava/lang/Object;

    move-result-object v2

    check-cast v2, [Ljava/lang/String;

    const/4 v3, 0x0

    invoke-static {p1, v3, v2, v0, v1}, Ljava/lang/System;->arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V

    return-object v2
.end method
'''


def append_code(field, values):
    regs = ['v%d' % (i + 1) for i in range(len(values))]
    code = ''.join('    const-string %s, "%s"\n\n' % (r, v) for r, v in zip(regs, values))
    code += '    filled-new-array/range {v1 .. v%d}, [Ljava/lang/String;\n\n' % len(values)
    code += '    move-result-object v0\n\n'
    code += '    sget-object v1, %s->%s:[Ljava/lang/String;\n\n' % (OUM, field)
    code += ('    invoke-static {v1, v0}, %s->rombicaAppend([Ljava/lang/String;[Ljava/lang/String;)'
             '[Ljava/lang/String;\n\n' % OUM)
    code += '    move-result-object v0\n\n'
    code += '    sput-object v0, %s->%s:[Ljava/lang/String;\n\n' % (OUM, field)
    return code


def edit(smali_dir):
    titles = [m.replace('p60hz', 'p-60hz') for m in VESA]
    new = ANCHOR.replace('    return-void\n', '    # Rombica A2 port: PC monitor (VESA) modes\n'
                         + append_code('HDMI_LIST', VESA) + append_code('HDMI_TITLE', titles)
                         + '    return-void\n') + HELPER
    path = os.path.join(smali_dir, CLASS)
    assert '.registers 18' in open(path).read().split('.method static constructor <clinit>()V')[1][:40]
    replace_text(path, ANCHOR, new)


def main(src, dst):
    assert hashlib.md5(open(src, 'rb').read()).hexdigest() == APK_MD5, \
        'not the SlimBOX 9.20 TvSettings.apk'
    patch_apk(src, dst, edit)
    print('TvSettings with PC monitor resolutions: %s' % dst)


if __name__ == '__main__':
    main(*sys.argv[1:3])
