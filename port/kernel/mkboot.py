#!/usr/bin/env python3
"""Build an Android boot image (header v0/v1) from a template boot image with a new kernel.

The kernel (ARM zImage) is wrapped in a legacy U-Boot uImage like the SlimBOX one (load/entry
0x208000, type kernel, no compression: the zImage decompresses itself). Everything else - header
addresses, second stage, recovery dtbo, cmdline - is taken from the template.

usage: mkboot.py <template_boot.img> <zImage> <out_boot.img> [--cmdline-append "args"]
"""
import argparse
import hashlib
import os
import struct
import time
import zlib

UIMAGE_LOAD = 0x208000


def uimage(data, name=b'Linux-4.9.113'):
    hdr = struct.pack('>7I4B32s', 0x27051956, 0, int(os.environ.get('SOURCE_DATE_EPOCH', time.time())), len(data), UIMAGE_LOAD,
                      UIMAGE_LOAD, zlib.crc32(data) & 0xffffffff, 5, 2, 2, 0, name)
    hcrc = zlib.crc32(hdr) & 0xffffffff
    return hdr[:4] + struct.pack('>I', hcrc) + hdr[8:] + data


def pages(n, page):
    return (n + page - 1) // page


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('template'); ap.add_argument('zimage'); ap.add_argument('out')
    ap.add_argument('--cmdline-append', default='')
    a = ap.parse_args()

    t = open(a.template, 'rb').read()
    assert t[:8] == b'ANDROID!', 'not an Android boot image'
    (ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, hver, osver) = struct.unpack_from('<10I', t, 8)
    assert hver in (0, 1), f'header version {hver} not supported'
    off = page
    parts = {}
    for name, size in (('kernel', ksz), ('ramdisk', rsz), ('second', ssz)):
        parts[name] = t[off:off + size]
        off += pages(size, page) * page
    dtbo_sz = dtbo_off = 0
    if hver == 1:
        dtbo_sz, dtbo_off = struct.unpack_from('<IQ', t, 1632)
        parts['dtbo'] = t[off:off + dtbo_sz]

    cmdline = t[64:64 + 512].split(b'\0')[0]
    extra = t[608:608 + 1024].split(b'\0')[0]
    if a.cmdline_append:
        cmdline = (cmdline + b' ' + a.cmdline_append.encode()).strip()
        assert len(cmdline) < 512, 'cmdline too long'

    kernel = uimage(open(a.zimage, 'rb').read())
    sha = hashlib.sha1()
    for name in ('kernel', 'ramdisk', 'second') + (('dtbo',) if hver == 1 else ()):
        d = kernel if name == 'kernel' else parts[name]
        sha.update(d); sha.update(struct.pack('<I', len(d)))

    hdr = bytearray(t[:page])
    struct.pack_into('<I', hdr, 8, len(kernel))
    hdr[64:64 + 512] = cmdline.ljust(512, b'\0')
    hdr[576:576 + 32] = sha.digest().ljust(32, b'\0')
    hdr[608:608 + 1024] = extra.ljust(1024, b'\0')

    out = bytearray(hdr)
    for d in (kernel, parts['ramdisk'], parts['second']) + ((parts['dtbo'],) if hver == 1 else ()):
        out += d + b'\0' * (pages(len(d), page) * page - len(d))
    if hver == 1 and dtbo_sz:
        struct.pack_into('<Q', out, 1636, page * (1 + pages(len(kernel), page) + pages(rsz, page)
                                                   + pages(ssz, page)))
    open(a.out, 'wb').write(out)
    print(f'{a.out}: {len(out)} bytes, kernel {len(kernel)}, cmdline "{cmdline.decode()}"')


if __name__ == '__main__':
    main()
