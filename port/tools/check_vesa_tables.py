#!/usr/bin/env python3
# Check the VESA (PC monitor) mode tables of the Amlogic HDMI TX driver - in the kernel and in
# U-Boot - against each other and against the VESA DMT standard.
#
# A VESA mode is described in four places that must agree:
#   timing   hdmi_parameters.c  fmt_para_vesa_*: porches, sync, totals, pixel clock, polarity
#            (used to match the sink's EDID detailed timings and to program the HDMI controller)
#   encoder  ENCP register table tvregs_vesa_* (totals and the active window of the video encoder)
#   clock    setting_enc_clk_val_24: HDMI PLL (VCO) and dividers; pixel clock =
#            VCO / (od1 * od2 * od3) / 5 (vid_pll_div) / vid_clk_div
#   PLL      the VCO frequency must be one the GXL PLL code has register values for, and those
#            values (24 MHz * (M + frac / 1024)) must give that frequency
# The kernel keeps the VESA clock entries divided by the od dividers (G12A style); on GXL the
# driver multiplies them back (patch 0011), so the check does the same.
#
# Also: the VESA mode numbers of both enums agree (U-Boot hands its mode over by number).
#
# usage: check_vesa_tables.py <kernel tree> <u-boot tree>     exit status 1 on any error
import os
import re
import sys

# VESA DMT (and CTA-861 for 2560x1080, CVT-RB for 2560x1440):
# pixel kHz, h active/front/sync/back, v active/front/sync/back, hsync+, vsync+
DMT = {
    "640x480p60hz":   (25175,  640, 16, 96, 48,    480, 10, 2, 33,  0, 0),
    "800x600p60hz":   (40000,  800, 40, 128, 88,   600, 1, 4, 23,   1, 1),
    "1024x768p60hz":  (65000,  1024, 24, 136, 160, 768, 3, 6, 29,   0, 0),
    "1152x864p75hz":  (108000, 1152, 64, 128, 256, 864, 1, 3, 32,   1, 1),
    "1280x768p60hz":  (79500,  1280, 64, 128, 192, 768, 3, 7, 20,   0, 1),
    "1280x800p60hz":  (83500,  1280, 72, 128, 200, 800, 3, 6, 22,   0, 1),
    "1280x960p60hz":  (108000, 1280, 96, 112, 312, 960, 1, 3, 36,   1, 1),
    "1280x1024p60hz": (108000, 1280, 48, 112, 248, 1024, 1, 3, 38,  1, 1),
    "1360x768p60hz":  (85500,  1360, 64, 112, 256, 768, 3, 6, 18,   1, 1),
    "1366x768p60hz":  (85500,  1366, 70, 143, 213, 768, 3, 3, 24,   1, 1),
    "1400x1050p60hz": (121750, 1400, 88, 144, 232, 1050, 3, 4, 32,  0, 1),
    "1440x900p60hz":  (106500, 1440, 80, 152, 232, 900, 3, 6, 25,   0, 1),
    "1600x900p60hz":  (108000, 1600, 24, 80, 96,   900, 1, 3, 96,   1, 1),
    "1600x1200p60hz": (162000, 1600, 64, 192, 304, 1200, 1, 3, 46,  1, 1),
    "1680x1050p60hz": (146250, 1680, 104, 176, 280, 1050, 3, 6, 30, 0, 1),
    "1920x1200p60hz": (193250, 1920, 136, 200, 336, 1200, 3, 6, 36, 0, 1),
    "2560x1080p60hz": (198000, 2560, 248, 44, 148, 1080, 4, 5, 11,  1, 1),
    "2560x1440p60hz": (241500, 2560, 48, 32, 80,   1440, 3, 5, 33,  1, 0),
    "2560x1600p60hz": (348500, 2560, 192, 280, 472, 1600, 3, 6, 49, 0, 1),
}

KERNEL = {
    "params": "drivers/amlogic/media/vout/hdmitx/hdmi_common/hdmi_parameters.c",
    "tvregs": "drivers/amlogic/media/vout/hdmitx/hdmi_tx_20/hw/enc_cfg_hw.c",
    "clk": "drivers/amlogic/media/vout/hdmitx/hdmi_tx_20/hw/hw_clk.c",
    "pll": "drivers/amlogic/media/vout/hdmitx/hdmi_tx_20/hw/hw_gxl.c",
}
UBOOT = {
    "params": "common/hdmi_parameters.c",
    "tvregs": "arch/arm/cpu/armv8/gxl/hdmitx20/hdmitx_tvenc.c",
    "clk": "arch/arm/cpu/armv8/gxl/hdmitx20/enc_clk_config.c",
    "pll": "arch/arm/cpu/armv8/gxl/hdmitx20/enc_clk_config.c",
}


def num(s):
    return int(s, 0)


def timings(src):
    out = {}
    for m in re.finditer(r"fmt_para_vesa_\w+ = \{(.*?)\n\};", src, re.S):
        b = m.group(1)
        vic = re.search(r"\.vic\s*=\s*(HDMIV?_\w+)", b)
        name = re.search(r'\.name\s*=\s*"(\w+)"', b)
        if not vic or not name:
            continue
        vinfo = re.search(r"\.hdmitx_vinfo = \{(.*?)\}", b, re.S)
        if vinfo:
            b = b.replace(vinfo.group(0), "")
            vinfo = {k: num(v) for k, v in re.findall(r"\.(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+),", vinfo.group(1))}
        f = {k: num(v) for k, v in re.findall(r"\.(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+),", b)}
        f["vic"] = vic.group(1)
        f["vinfo"] = vinfo
        out[name.group(1)] = f
    return out


def tvregs(src):
    tabs = {}
    for m in re.finditer(r"struct reg_[st] (tvregs_\w+)\[\] = \{(.*?)\};", src, re.S):
        tabs[m.group(1)] = {r: num(v) for r, v in
                            re.findall(r"\{P_(ENCP_VIDEO_\w+),\s*(0x[0-9a-fA-F]+|\d+),?\s*\}", m.group(2))}
    tab = re.search(r"struct vic_tvregs_set tvregsTab\[\] = \{(.*?)\};", src, re.S).group(1)
    tab = re.sub(r"#if 0.*?#endif", "", tab, flags=re.S)
    return {v: tabs[t] for v, t in re.findall(r"\{(HDMIV?_\w+),\s*(tvregs_\w+)\}", tab) if t in tabs}


def clocks(src):
    arr = re.search(r"setting_enc_clk_val_24\[\] = \{(.*?)\n\};", src, re.S).group(1)
    out = {}
    for vics, vals in re.findall(r"\{\{(.*?)\},(.*?)\}", arr, re.S):
        vals = [v.strip() for v in vals.split(",")]
        if vals[0] == "1":                      # U-Boot: viu_path, viu_type first
            vals = vals[2:]
        hpll, od1, od2, od3 = (num(v) for v in vals[:4])
        vid_pll_div, vid_clk_div = vals[4], num(vals[5])
        for v in re.findall(r"HDMIV?_\w+", re.sub(r"/\*.*?\*/", "", vics)):
            out[v] = (hpll, od1, od2, od3, vid_pll_div, vid_clk_div)
    return out


def plls(src):
    out = {}
    for m in re.finditer(r"case (\d{6,7}):(.*?)break;", src, re.S):
        c = re.search(r"P_HHI_HDMI_PLL_CNTL, (0x[0-9a-f]+)", m.group(2))
        c1 = re.search(r"P_HHI_HDMI_PLL_CNTL1, (0x[0-9a-f]+)", m.group(2))
        if c and c1:
            out[int(m.group(1))] = (num(c.group(1)), num(c1.group(1)))
    return out


def check(name, root, files, gxl_multiply):
    rd = lambda k: open(os.path.join(root, files[k])).read()
    tim, enc, clk, pll = timings(rd("params")), tvregs(rd("tvregs")), clocks(rd("clk")), plls(rd("pll"))
    errors = []

    def err(mode, msg):
        errors.append("%s %s: %s" % (name, mode, msg))

    for mode, ref in sorted(DMT.items(), key=lambda x: x[1][1] * 10000 + x[1][5]):
        pix, ha, hf, hs, hb, va, vf, vs, vb, hp, vp = ref
        t = tim.get(mode)
        if not t:
            err(mode, "no timing")
            continue
        want = dict(pixel_freq=pix, h_active=ha, h_front=hf, h_sync=hs, h_back=hb,
                    h_blank=hf + hs + hb, h_total=ha + hf + hs + hb, v_active=va, v_front=vf,
                    v_sync=vs, v_back=vb, v_blank=vf + vs + vb, v_total=va + vf + vs + vb,
                    hsync_polarity=hp, vsync_polarity=vp)
        if "tmds_clk" in t:
            want["tmds_clk"] = pix
        for k, v in want.items():
            if t.get(k) != v:
                err(mode, "timing %s = %s, want %s" % (k, t.get(k), v))
        vfreq = pix * 1000 * 1000 // (want["h_total"] * want["v_total"])
        if abs(t.get("v_freq", 0) - vfreq) > 5:
            err(mode, "timing v_freq = %s, want %d" % (t.get("v_freq"), vfreq))
        hfreq = pix * 1000 // want["h_total"]
        if abs(t.get("h_freq", 0) - hfreq) > 5:
            err(mode, "timing h_freq = %s, want %d" % (t.get("h_freq"), hfreq))
        if "vsync" in t and t["vsync"] != (vfreq + 500) // 1000:
            err(mode, "timing vsync = %s, want %d" % (t["vsync"], (vfreq + 500) // 1000))
        vi = t.get("vinfo")
        if vi:                                  # kernel: the vout info of the mode
            for k, v in (("width", ha), ("height", va), ("video_clk", pix * 1000),
                         ("htotal", want["h_total"]), ("vtotal", want["v_total"])):
                if vi.get(k) != v:
                    err(mode, "vinfo %s = %s, want %d" % (k, vi.get(k), v))

        e = enc.get(t["vic"])
        if not e:
            err(mode, "no encoder table")
        else:
            hav_b = e["ENCP_VIDEO_HAVON_BEGIN"]
            vav_b = e["ENCP_VIDEO_VAVON_BLINE"]
            for k, v in (("MAX_PXCNT", want["h_total"] - 1), ("MAX_LNCNT", want["v_total"] - 1),
                         ("HAVON_END", hav_b + ha - 1), ("VAVON_ELINE", vav_b + va - 1),
                         ("HAVON_BEGIN", hs + hb), ("VAVON_BLINE", vs + vb)):
                if e.get("ENCP_VIDEO_" + k) != v:
                    err(mode, "encoder %s = %s, want %d" % (k, e.get("ENCP_VIDEO_" + k), v))

        c = clk.get(t["vic"])
        if not c:
            err(mode, "no clock entry")
            continue
        hpll, od1, od2, od3, vpd, vcd = c
        vco = hpll * od1 * od2 * od3 if gxl_multiply and hpll < 2900000 else hpll
        if vpd != "VID_PLL_DIV_5":
            err(mode, "clock vid_pll_div %s" % vpd)
            continue
        got = vco / (od1 * od2 * od3) / 5 / vcd
        if abs(got - pix) > pix * 0.0005:
            err(mode, "clock gives %.0f kHz (VCO %d), want %d" % (got, vco, pix))
        if not 2900000 <= vco <= 6000000:
            err(mode, "VCO %d out of range" % vco)
        p = pll.get(vco)
        if not p:
            err(mode, "no PLL setting for VCO %d" % vco)
        else:
            m, frac = p[0] & 0x1ff, p[1] & 0x3ff
            real = 24000 * (m + frac / 1024)
            if abs(real - vco) > vco * 0.0002:
                err(mode, "PLL registers give VCO %.0f, want %d" % (real, vco))
    return errors


def vesa_enum(path):
    """the VESA mode names of enum hdmi_vic, in order"""
    s = open(path).read()
    s = s[s.index("HDMIV_640x480p60hz = HDMITX_VESA_OFFSET"):]
    s = re.sub(r"/\*.*?\*/", "", s[:s.index("}")], flags=re.S)
    return re.findall(r"HDMIV_\w+", s)


def check_enum(kernel, uboot):
    """U-Boot hands the output mode over to the kernel by number (ISA_DEBUG_REG0): every VESA
    mode of the kernel must have the same number in U-Boot"""
    k = vesa_enum(os.path.join(kernel, "include/linux/amlogic/media/vout/hdmi_tx/hdmi_common.h"))
    u = vesa_enum(os.path.join(uboot, "include/amlogic/hdmi.h"))
    off = [re.search(r"#define HDMITX_VESA_OFFSET\s+(0x[0-9a-fA-F]+)", open(f).read()).group(1)
           for f in (os.path.join(kernel, "include/linux/amlogic/media/vout/hdmi_tx/hdmi_common.h"),
                     os.path.join(uboot, "include/amlogic/hdmi.h"))]
    err = ["enum: HDMITX_VESA_OFFSET %s in the kernel, %s in U-Boot" % tuple(off)] \
        if int(off[0], 16) != int(off[1], 16) else []
    return err + ["enum: %s is %d in the kernel, %s in U-Boot" % (m, i, u.index(m) if m in u else "-")
                  for i, m in enumerate(k) if i >= len(u) or u[i] != m]


def main(kernel, uboot):
    errors = (check("kernel", kernel, KERNEL, True) + check("u-boot", uboot, UBOOT, False)
              + check_enum(kernel, uboot))
    for e in errors:
        print(e)
    print("%d error(s)" % len(errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
