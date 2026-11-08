#!/usr/bin/env python3
"""Make the port's copy of Amlogic's /vendor/framework/droidlogic.jar (SlimBOX 9.20).

OutputModeManager.setOutputModeNowLocked() stores the output mode in
persist.sys.display.resolution, which the framework (LocalDisplayAdapter) parses as
"<height>p<rate>hz". The port's PC monitor modes ("1280x1024p60hz") broke that parse: the display
was not configured and the mouse pointer stayed at 0,0. The property now gets the form its reader
expects (droidlogic/com/droidlogic/app/RombicaDisplayMode.java: "1280x1024p60hz" ->
"1024p60hz", "smpte24hz" -> "2160p24hz", TV modes unchanged).

OutputModeManager.getHighestMatchResolution() ("Best resolution") ranked the modes of disp_cap
with parseInt() and threw on PC monitor modes, crashing TvSettings. It now returns the native
mode of a PC monitor, and ranks only the TV modes otherwise (the same policy as systemcontrol).

  javac + d8 the helper -> baksmali (helper and droidlogic.jar) -> the calls in
  setOutputModeNowLocked() and getHighestMatchResolution() (the expected code is checked) ->
  smali -> classes.dex of the jar.
The jar is not signed and not precompiled (/vendor/framework/oat is empty).

usage: make_droidlogic_jar.py <droidlogic.jar from the SlimBOX vendor> <out.jar>
env:   ANDROID_SDK (default ~/build/rombica-smartbox-a2/android-sdk: build-tools 30.0.3, platform 28), SMALI_DIR
"""
import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../system"))
from apkpatch import jar, replace_text  # noqa: E402

JAR_MD5 = "4ca5f6aefa0d86bccb11d02db070b355"           # SlimBOX 9.20
SDK = os.environ.get("ANDROID_SDK") or os.path.expanduser("~/build/rombica-smartbox-a2/android-sdk")
CLS = "com/droidlogic/app/OutputModeManager.smali"
OLD = """    const-string v3, "persist.sys.display.resolution"

    invoke-virtual {v2, v3, p1}, Lcom/droidlogic/app/SystemControlManager;->setProperty(Ljava/lang/String;Ljava/lang/String;)V
"""
NEW = """    invoke-static {p1}, Lcom/droidlogic/app/RombicaDisplayMode;->resolution(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v4

    const-string v3, "persist.sys.display.resolution"

    invoke-virtual {v2, v3, v4}, Lcom/droidlogic/app/SystemControlManager;->setProperty(Ljava/lang/String;Ljava/lang/String;)V
"""

OLD_BEST = """    invoke-virtual {v6, v8}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v4

    :cond_50
"""
NEW_BEST = """    invoke-virtual {v6, v8}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v4

    invoke-static {v4}, Lcom/droidlogic/app/RombicaDisplayMode;->nativePcMode([Ljava/lang/String;)Ljava/lang/String;

    move-result-object v6

    if-eqz v6, :rombica_tv_modes

    return-object v6

    :rombica_tv_modes
    invoke-static {v4}, Lcom/droidlogic/app/RombicaDisplayMode;->tvModes([Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v4

    :cond_50
"""


def main(src, dst):
    d = open(src, "rb").read()
    assert hashlib.md5(d).hexdigest() == JAR_MD5, "not the SlimBOX 9.20 droidlogic.jar"
    aj = os.path.join(SDK, "platforms/android-28/android.jar")
    with tempfile.TemporaryDirectory() as w:
        java = os.path.join(HERE, "droidlogic/com/droidlogic/app/RombicaDisplayMode.java")
        os.makedirs(os.path.join(w, "cls"))
        subprocess.check_call(["javac", "-source", "8", "-target", "8", "-bootclasspath", aj,
                               "-Xlint:-options", "-d", os.path.join(w, "cls"), java])
        os.makedirs(os.path.join(w, "hdex"))
        subprocess.check_call([os.path.join(SDK, "build-tools/30.0.3/d8"), "--release",
                               "--min-api", "28", "--lib", aj, "--output", os.path.join(w, "hdex"),
                               os.path.join(w, "cls/com/droidlogic/app/RombicaDisplayMode.class")])
        with zipfile.ZipFile(src) as z:
            open(os.path.join(w, "classes.dex"), "wb").write(z.read("classes.dex"))
        smali = os.path.join(w, "smali")
        for dex in (os.path.join(w, "classes.dex"), os.path.join(w, "hdex/classes.dex")):
            subprocess.check_call(["java", "-jar", jar("baksmali"), "d", "-j", "1", "-o", smali, dex])
        replace_text(os.path.join(smali, CLS), OLD, NEW)
        replace_text(os.path.join(smali, CLS), OLD_BEST, NEW_BEST)
        out = os.path.join(w, "new.dex")
        subprocess.check_call(["java", "-jar", jar("smali"), "a", "-j", "1", "-a", "28", "-o", out, smali])
        with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w") as zo:
            for info in zi.infolist():                  # same entries, order and times
                data = open(out, "rb").read() if info.filename == "classes.dex" else zi.read(info)
                zo.writestr(info, data)
    print("droidlogic.jar with PC monitor modes in the resolution property and the best mode: %s" % dst)


if __name__ == "__main__":
    main(*sys.argv[1:3])
