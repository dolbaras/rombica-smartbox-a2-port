#!/usr/bin/env python3
"""List / extract items of an Amlogic aml_upgrade_package.img (v2).

usage: extract_aml_image.py <image> [out_dir]
Items are written as <SUB>.<MAIN> (e.g. boot.PARTITION, DDR.USB, meson1.dtb).
"""
import os
import struct
import sys

HEADER_SIZE = 64
ITEM_SIZE = 576
CHUNK = 1 << 24


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    with open(src, 'rb') as f:
        _, version, magic, size, _, count = struct.unpack('<IIIQII', f.read(28))
        assert version == 2 and magic == 0x27B51956, 'not an Amlogic v2 image'
        print(f'size={size} items={count}')
        f.seek(HEADER_SIZE)
        items = []
        for i in range(count):
            raw = f.read(ITEM_SIZE)
            _, ftype, _, off, sz = struct.unpack('<IIQQQ', raw[:32])
            main = raw[32:288].split(b'\0')[0].decode()
            sub = raw[288:544].split(b'\0')[0].decode()
            items.append((main, sub, off, sz))
            print(f'{i:2} {main:10} {sub:16} type={ftype:#04x} off={off:#x} size={sz}')
        if not out:
            return
        os.makedirs(out, exist_ok=True)
        for main, sub, off, sz in items:
            f.seek(off)
            name = 'meson1.dtb' if main == 'dtb' else f'{sub}.{main}'
            with open(os.path.join(out, name), 'wb') as o:
                left = sz
                while left:
                    block = f.read(min(left, CHUNK))
                    o.write(block)
                    left -= len(block)


if __name__ == '__main__':
    main()
