#!/usr/bin/python3
# Draw the boot menu shown by U-Boot (bmp display) when the Armbian microSD is in the box:
# 1920x1080, 16-bit RGB565 BMP (BI_BITFIELDS) - the format of the stock boot logos; Amlogic's
# U-Boot draws a 24-bit BMP shifted and with wrong colours.
#   bootmenu.bmp           the menu while it waits for the remote
#   bootmenu_android.bmp   shown at once after the choice: Android highlighted, "loading" (also after the timeout)
#   bootmenu_armbian.bmp   the same for Armbian
# usage: make_bootmenu_bmp.py <out_dir>
import os
import struct
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
BOOK = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
title = ImageFont.truetype(BOLD, 64)
big = ImageFont.truetype(BOLD, 96)
small = ImageFont.truetype(BOOK, 44)
BOXES = {"android": ((180, 400, 900, 760), "◀  Android", (60, 140, 90)),
         "armbian": ((1020, 400, 1740, 760), "Armbian  ▶", (40, 100, 170))}
BG = (18, 24, 38)


def draw(chosen=None):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    def centered(y, text, font, fill):
        w = d.textlength(text, font=font)
        d.text(((W - w) / 2, y), text, font=font, fill=fill)

    centered(150, "Rombica SmartBox A2", title, (230, 236, 245))
    if chosen is None:
        centered(240, "Выберите систему кнопками пульта", small, (160, 172, 190))
    for name, ((x0, y0, x1, y1), label, colour) in BOXES.items():
        text = (255, 255, 255)
        if chosen == name:
            d.rounded_rectangle((x0 - 14, y0 - 14, x1 + 14, y1 + 14), radius=52, fill=(255, 255, 255))
        elif chosen is not None:            # the other one fades into the background
            colour = tuple((c + b * 2) // 3 for c, b in zip(colour, BG))
            text = (110, 118, 134)
        d.rounded_rectangle((x0, y0, x1, y1), radius=40, fill=colour)
        w = d.textlength(label, font=big)
        d.text((x0 + (x1 - x0 - w) / 2, y0 + (y1 - y0 - 110) / 2), label, font=big, fill=text)
    if chosen is None:
        centered(830, "◀ влево или OK — Android        вправо — Armbian", small, (200, 208, 220))
        centered(900, "Без нажатия через 10 секунд загрузится Android", small, (140, 150, 168))
    else:
        centered(850, "Загрузка " + ("Android" if chosen == "android" else "Armbian") + "…",
                 title, (230, 236, 245))
    return img


def save_rgb565(im, path):
    """BMP v3 with BI_BITFIELDS masks (RGB565), bottom-up rows."""
    w, h = im.size
    px = im.load()
    stride = (w * 2 + 3) & ~3
    data = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray()
        for x in range(w):
            r, g, b = px[x, y]
            row += struct.pack("<H", ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
        data += row + b"\0" * (stride - len(row))
    off = 14 + 40 + 12
    hdr = struct.pack("<2sIHHI", b"BM", off + len(data), 0, 0, off)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 16, 3, len(data), 2835, 2835, 0, 0)
    masks = struct.pack("<III", 0xF800, 0x07E0, 0x001F)
    with open(path, "wb") as f:
        f.write(hdr + info + masks + data)


out = sys.argv[1]
save_rgb565(draw(), os.path.join(out, "bootmenu.bmp"))
for name in BOXES:
    save_rgb565(draw(name), os.path.join(out, "bootmenu_%s.bmp" % name))
