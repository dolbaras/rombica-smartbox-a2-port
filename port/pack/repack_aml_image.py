#!/usr/bin/env python3
"""Repack an Amlogic aml_upgrade_package.img (v2) replacing selected items.

usage: repack_aml_image.py <in.img> <out.img> MAIN:SUB=file[:sparse] ...
e.g.   PARTITION:bootloader=bootloader.img  PARTITION:vendor=vendor.simg:sparse

VERIFY items of replaced PARTITIONs are regenerated ("sha1sum <hex>"), backup
items (e.g. dtb:meson1 -> PARTITION:_aml_dtb) follow their target, offsets are
re-laid out with the original alignment and the header CRC is recomputed.
"""
import hashlib
import os
import struct
import sys
import zlib

HEADER_SIZE = 64
ITEM_SIZE = 576
MAGIC = 0x27B51956
FILE_TYPE_NORMAL = 0x00
FILE_TYPE_SPARSE = 0xFE
CHUNK = 1 << 24


class Item:
    def __init__(self, raw):
        self.raw = bytearray(raw)
        (self.id, self.file_type, _, self.offset, self.size) = struct.unpack('<IIQQQ', raw[:32])
        self.main = raw[32:288].split(b'\0')[0].decode()
        self.sub = raw[288:544].split(b'\0')[0].decode()
        self.verify, self.is_backup, self.backup_id = struct.unpack('<IHH', raw[544:552])
        self.source = None  # (path, offset) of the data to write
        self.data = None    # small in-memory replacement

    def pack(self):
        struct.pack_into('<IIQQQ', self.raw, 0, self.id, self.file_type, 0, self.offset, self.size)
        return bytes(self.raw)


def sha1_of(path=None, data=None):
    h = hashlib.sha1()
    if data is not None:
        h.update(data)
    else:
        with open(path, 'rb') as f:
            for block in iter(lambda: f.read(CHUNK), b''):
                h.update(block)
    return h.hexdigest()


def main():
    src, dst, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
    fin = open(src, 'rb')
    crc, version, magic, _, align, count = struct.unpack('<IIIQII', fin.read(28))
    assert magic == MAGIC and version == 2
    fin.seek(0)
    header = bytearray(fin.read(HEADER_SIZE))
    items = [Item(fin.read(ITEM_SIZE)) for _ in range(count)]
    by_key = {(it.main, it.sub): it for it in items}

    for it in items:
        it.source = (src, it.offset)

    for spec in specs:
        key, path = spec.split('=', 1)
        sparse = path.endswith(':sparse')
        path = path[:-len(':sparse')] if sparse else path
        main, sub = key.split(':')
        it = by_key[(main, sub)]
        it.source, it.size = (path, 0), os.path.getsize(path)
        if main == 'PARTITION':
            it.file_type = FILE_TYPE_SPARSE if sparse else FILE_TYPE_NORMAL
            verify = by_key.get(('VERIFY', sub))
            if verify:
                verify.data = f'sha1sum {sha1_of(path)}'.encode()
                verify.size = len(verify.data)
        print(f'replace {main}:{sub} <- {path} ({it.size} bytes)')

    # Lay out data: every non-backup item in original offset order.
    # VERIFY items follow their partition directly; everything else is aligned.
    offset = HEADER_SIZE + ITEM_SIZE * count
    for it in sorted((i for i in items if not i.is_backup), key=lambda i: i.offset):
        if it.main != 'VERIFY':
            offset = -(-offset // align) * align
        it.offset = offset
        offset += it.size
    total = offset
    by_id = {i.id: i for i in items}
    for it in items:
        if it.is_backup:
            target = by_id[it.backup_id]
            it.offset, it.size = target.offset, target.size

    with open(dst, 'wb') as out:
        out.truncate(total)
        for it in items:
            if it.is_backup:
                continue
            out.seek(it.offset)
            if it.data is not None:
                out.write(it.data)
                continue
            path, start = it.source
            with open(path, 'rb') as f:
                f.seek(start)
                left = it.size
                while left:
                    block = f.read(min(left, CHUNK))
                    out.write(block)
                    left -= len(block)
        struct.pack_into('<Q', header, 12, total)
        out.seek(0)
        out.write(header)
        for it in items:
            out.write(it.pack())

    with open(dst, 'r+b') as out:
        out.seek(4)
        crc = 0
        for block in iter(lambda: out.read(CHUNK), b''):
            crc = zlib.crc32(block, crc)
        out.seek(0)
        out.write(struct.pack('<I', crc ^ 0xFFFFFFFF))
    print(f'wrote {dst}: {total} bytes, {count} items, crc {crc ^ 0xFFFFFFFF:#010x}')


if __name__ == '__main__':
    main()
