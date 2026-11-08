#!/usr/bin/env python3
"""Pack / unpack an Amlogic GXL "LZ4C" compressed BL33 (the form stock BL31 expects when booting
from eMMC/SD; it prints "BL33 decompress pass").

Layout (reverse engineered from the VPLT and SlimBOX bootloaders, both verified by this script):
  0x00  'LZ4C'
  0x04  u32  0x00800000         (max block size)
  0x08  u32  uncompressed size
  0x0C  u32  compressed size
  0x10  32B  sha256(uncompressed) or zeros (VPLT uses zeros)
  0x30  16B  build date string 'YYYYMMDDhh:mm:ss', zero padded to 0x50
  0x50  12B  opaque (salt?), copied from the VPLT header
  0x5C  'LZ4C'
  0x60  32B  sha256(header[0x00:0x60])
  0x80  raw LZ4 block, then zero padding to a 512-byte multiple

usage: aml_lz4c.py pack <u-boot.bin> <out.lz4c> [--hash]
       aml_lz4c.py unpack <in.lz4c> <out.bin>
"""
import hashlib
import os
import struct
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'pylib'))
import lz4.block  # noqa: E402

MAGIC = b'LZ4C'
BLOCK = 0x800000
VPLT_OPAQUE = bytes.fromhex('f29492ab647366a440810700')


def unpack(data):
    magic, block, usz, csz = struct.unpack_from('<4sIII', data)
    assert magic == MAGIC and block == BLOCK and data[0x5C:0x60] == MAGIC, 'not an LZ4C image'
    assert hashlib.sha256(data[:0x60]).digest() == data[0x60:0x80], 'header hash mismatch'
    raw = lz4.block.decompress(data[0x80:0x80 + csz], uncompressed_size=usz)
    if data[0x10:0x30] != bytes(32):
        assert hashlib.sha256(raw).digest() == data[0x10:0x30], 'payload hash mismatch'
    return raw


def pack(raw, with_hash=False, date=None):
    assert len(raw) < BLOCK
    comp = lz4.block.compress(raw, mode='high_compression', compression=12, store_size=False)
    date = (date or time.strftime('%Y%m%d%H:%M:%S')).encode()
    hdr = struct.pack('<4sIII', MAGIC, BLOCK, len(raw), len(comp))
    hdr += hashlib.sha256(raw).digest() if with_hash else bytes(32)
    hdr += date.ljust(0x20, b'\0') + VPLT_OPAQUE + MAGIC
    hdr += hashlib.sha256(hdr).digest()
    out = hdr + comp
    out += bytes(-len(out) % 512)
    assert unpack(out) == raw
    return out


if __name__ == '__main__':
    cmd, src, dst = sys.argv[1:4]
    data = open(src, 'rb').read()
    if cmd == 'pack':
        out = pack(data, with_hash='--hash' in sys.argv[4:])
        print(f'{src}: {len(data)} -> {len(out)} bytes')
    elif cmd == 'unpack':
        out = unpack(data)
    else:
        sys.exit(__doc__)
    open(dst, 'wb').write(out)
