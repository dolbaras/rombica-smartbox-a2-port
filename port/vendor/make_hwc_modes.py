#!/usr/bin/env python3
# Teach SlimBOX's hwcomposer.amlogic.so the VESA (PC monitor) display modes.
#
# The kernel (patch 0011) lists the VESA modes a monitor's EDID declares in disp_cap, e.g.
# "1280x1024p60hz". hwcomposer turns a mode name into a size with vmode_name_to_mode() and
# get_tv_info() (Amlogic's AmVinfo.cpp). SlimBOX's copy predates the VESA names: the name
# table has only TV modes and the lookup is strstr(), so "1024x768p60hz" was taken for
# "768p60hz" (1280x768) and "1280x1024p60hz" was unknown - Android kept drawing a 1280x720
# window into a 1280x1024 picture.
#
# The patch, applied to the cursor-fixed library (make_hwc_cursor.py output):
#   * rewrites vmode_match_table (50 entries): the VESA names first (strstr: they contain
#     TV names like "480p60hz"/"768p60hz"), then the TV modes; dropped are the repeat modes
#     (480irpt...), 4k2k5g/2160p5g, 768p50hz, smpte60hz420 and the 3840x1080/540 100-240 Hz
#     modes, none of which the S905L2 outputs;
#   * gives every VESA name a tv_info entry with its size: vga/svga/xga/sxga/wsxga exist
#     (vga's field height fixed to 480), the others reuse the entries of the 3D frame
#     packing modes (fhdvga, 1080fp*, 720fp*) and of the dropped 3840x1080 ones;
#   * the new names are stored over the strings of the dropped entries (0x3faaf-0x3fb9c,
#     only referenced from these two tables).
#   The OSD window comes from systemcontrol (getPosition), which knows the VESA modes
#   (port/vendor/native/systemcontrol); the UI size (HwcConfig::getFramebufferSize) is new
#   code too: port/vendor/native/hwc.
#
# usage: make_hwc_modes.py <hwcomposer.amlogic.so (cursor-fixed)> <out.so>
import hashlib
import struct
import sys

IN_MD5 = "07018f346bb1733d976b02fcc1ae2b8e"     # make_hwc_cursor.py output
MATCH = 0x41888        # vmode_match_table: {const char *name; u32 vmode}[50] (file offset)
MATCH_N = 50
TVINFO = 0x41a18       # tv_info: struct vinfo_s[61], 72 bytes each
TVINFO_SZ = 72
TVINFO_N = 61
STR_LO, STR_HI = 0x3faaf, 0x3fb9d    # strings of the dropped entries, free for new names
RODATA_LO, RODATA_HI = 0x3cc40, 0x40f34


# VESA modes: name, width, height, aspect, pixel clock, tv_info entry (by its old name)
VESA = [
    ("640x480p60hz",   640,  480,  (4, 3),   25175000,  "vga"),
    ("800x600p60hz",   800,  600,  (4, 3),   40000000,  "svga"),
    ("1024x768p60hz",  1024, 768,  (4, 3),   65000000,  "xga"),
    ("1280x800p60hz",  1280, 800,  (16, 10), 83500000,  "fhdvga"),
    ("1280x960p60hz",  1280, 960,  (4, 3),   108000000, "1080fp60hz"),
    ("1280x1024p60hz", 1280, 1024, (5, 4),   108000000, "sxga"),
    ("1360x768p60hz",  1360, 768,  (16, 9),  85500000,  "1080fp50hz"),
    ("1366x768p60hz",  1366, 768,  (16, 9),  85500000,  "1080fp30hz"),
    ("1440x900p60hz",  1440, 900,  (16, 10), 106500000, "wsxga"),
    ("1600x900p60hz",  1600, 900,  (16, 9),  108000000, "1080fp25hz"),
    ("1600x1200p60hz", 1600, 1200, (4, 3),   162000000, "1080fp24hz"),
    ("1920x1200p60hz", 1920, 1200, (16, 10), 193250000, "720fp60hz"),
    ("1680x1050p60hz", 1680, 1050, (16, 10), 119000000, "4k1k100hz420"),
    ("2560x1080p60hz", 2560, 1080, (64, 27), 198000000, "4k1k100hz"),
    ("2560x1440p60hz", 2560, 1440, (16, 9),  241500000, "4k1k120hz420"),
    ("2560x1600p60hz", 2560, 1600, (16, 10), 268500000, "4k1k120hz"),
]
# TV modes kept, in the original order (longer names before their prefixes: "...hz420")
TV = ["480i60hz", "480cvbs", "480p60hz", "576i50hz", "576cvbs", "576p50hz",
      "720p60hz", "720p50hz", "768p60hz", "1080i60hz", "1080i50hz",
      "1080p60hz", "1080p25hz", "1080p30hz", "1080p50hz", "1080p24hz",
      "2160p30hz", "2160p25hz", "2160p24hz", "smpte24hz", "smpte25hz", "smpte30hz",
      "smpte50hz420", "smpte50hz", "smpte60hz",
      "2160p60hz420", "2160p60hz", "2160p50hz420", "2160p50hz",
      "panel", "pal_m", "pal_n", "ntsc_m", "invalid"]


def cstr(d, off):
    return bytes(d[off:d.index(b"\0", off)]).decode()


def main(src, dst):
    d = bytearray(open(src, "rb").read())
    if hashlib.md5(d).hexdigest() != IN_MD5:
        sys.exit("unexpected input (md5 %s), want the make_hwc_cursor.py output" % hashlib.md5(d).hexdigest())

    match = {}
    for i in range(MATCH_N):
        p, mode = struct.unpack_from("<II", d, MATCH + i * 8)
        assert RODATA_LO <= p < RODATA_HI
        match[cstr(d, p)] = (p, mode)
    tvinfo = {}
    for i in range(TVINFO_N):
        off = TVINFO + i * TVINFO_SZ
        p, mode = struct.unpack_from("<II", d, off)
        tvinfo[cstr(d, p)] = (off, mode)
    assert len(match) == MATCH_N and "sxga" in tvinfo and "720fp60hz" in tvinfo
    assert not (STR_LO <= match["invalid"][0] < STR_HI)

    # new name strings
    names = b"".join(n.encode() + b"\0" for n, *_ in VESA)
    assert len(names) <= STR_HI - STR_LO
    for name in match:
        p = match[name][0]
        assert not (STR_LO <= p < STR_HI) or name not in TV, name
    d[STR_LO:STR_HI] = names + b"\0" * (STR_HI - STR_LO - len(names))
    newstr = {}
    off = STR_LO
    for n, *_ in VESA:
        newstr[n] = off
        off += len(n) + 1

    # tv_info entries for the VESA modes
    for name, w, h, (an, ad), clk, entry in VESA:
        toff, mode = tvinfo[entry]
        struct.pack_into("<II", d, toff, newstr[name], mode)
        struct.pack_into("<IIIIIII", d, toff + 8, w, h, h, an, ad, 60, 1)
        struct.pack_into("<I", d, toff + 44, clk)
    # other tv_info names inside the overwritten area: point to a kept name (the dropped
    # 3840x1080/540 modes become "invalid"; their entries are unreachable now)
    alias = {"480i_rpt": "480i60hz", "480p_rpt": "480p60hz", "576i_rpt": "576i50hz",
             "576p_rpt": "576p50hz", "720fp50hz": "720p50hz"}
    for name, (toff, mode) in tvinfo.items():
        p = struct.unpack_from("<I", d, toff)[0]
        if STR_LO <= p < STR_HI and p not in newstr.values():
            struct.pack_into("<I", d, toff, match[alias.get(name, "invalid")][0])

    # name table: VESA first, then the TV modes; 50 entries exactly
    table = [(newstr[n], tvinfo[e][1]) for n, *_, e in VESA] + [match[n] for n in TV]
    pad = MATCH_N - len(table)
    assert pad >= 0
    table += [match["invalid"]] * pad
    for i, (p, mode) in enumerate(table):
        struct.pack_into("<II", d, MATCH + i * 8, p, mode)

    open(dst, "wb").write(d)
    print("%s: %d VESA modes, md5 %s" % (dst, len(VESA), hashlib.md5(d).hexdigest()))


if __name__ == "__main__":
    main(*sys.argv[1:3])
