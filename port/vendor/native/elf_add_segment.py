#!/usr/bin/env python3
# Add a loadable code segment to a 32-bit ARM ELF (shared library or executable) built without
# room for it, so new code (compiled C, see build.sh) can live inside a closed binary.
#
# The PT_NOTE program header is turned into a PT_LOAD (R+X) for the new segment: the notes
# (Android/GNU ident, build id) are not used at run time, the header table keeps its size and
# place. The segment is appended at the end of the file at the first page after the highest
# PT_LOAD (file offset and address congruent modulo the page size), so the dynamic linker maps it
# together with the rest of the image; nothing else moves.
#
# usage: elf_add_segment.py <in> <code.bin> <out>       prints the segment address
#        elf_add_segment.py --vaddr <in>                only prints where the segment would go
import struct
import sys

PT_LOAD, PT_NOTE = 1, 4
PF_X, PF_R = 1, 4
PAGE = 0x1000


def phdrs(d):
    assert d[:4] == b"\x7fELF" and d[4] == 1 and d[5] == 1, "not a 32-bit little-endian ELF"
    e_phoff, = struct.unpack_from("<I", d, 0x1c)
    e_phentsize, e_phnum = struct.unpack_from("<HH", d, 0x2a)
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        yield off, struct.unpack_from("<8I", d, off)


def seg_vaddr(d):
    end = max(v + msz for _, (t, o, v, p, fsz, msz, fl, al) in phdrs(d) if t == PT_LOAD)
    return (end + PAGE - 1) & ~(PAGE - 1)


def main():
    if sys.argv[1] == "--vaddr":
        print("0x%x" % seg_vaddr(open(sys.argv[2], "rb").read()))
        return
    src, blob_path, dst = sys.argv[1:4]
    d = bytearray(open(src, "rb").read())
    blob = open(blob_path, "rb").read()
    vaddr = seg_vaddr(d)
    note = [off for off, h in phdrs(d) if h[0] == PT_NOTE]
    assert len(note) == 1, "need exactly one PT_NOTE to reuse"
    foff = (len(d) + PAGE - 1) & ~(PAGE - 1)
    assert foff % PAGE == vaddr % PAGE
    d += b"\0" * (foff - len(d)) + blob
    struct.pack_into("<8I", d, note[0], PT_LOAD, foff, vaddr, vaddr, len(blob), len(blob),
                     PF_R | PF_X, PAGE)
    open(dst, "wb").write(d)
    print("0x%x" % vaddr)


if __name__ == "__main__":
    main()
