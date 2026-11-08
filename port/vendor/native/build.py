#!/usr/bin/env python3
# Build the C code for one SlimBOX binary and add it to that binary as a new code segment.
#
#   <dir>/hooks.txt   what to build and where it is called from, one entry per line:
#                       import <function>...           imports of the binary the code calls
#                       extern <symbol> <address>      a Thumb function inside the binary the
#                                                        code calls (e.g. the rest of a hooked
#                                                        function, from a trampoline in a .S file)
#                     (addresses are virtual addresses, as objdump shows them)
#                       hook <symbol> <address> <bytes>  replace the Thumb code at <address>
#                                                        (<bytes>: its expected original bytes,
#                                                        4 or more) by "b.w <symbol>" - a tail
#                                                        call: the new function takes over the
#                                                        function starting there
#                       call <symbol> <address> <bytes>  the 4-byte Thumb "bl/blx" at <address>
#                                                        (original bytes given) now calls <symbol>
#                       md5 <md5 of the input binary>
#   <dir>/*.c, *.S    the code (freestanding, see common.h), Thumb-2, position independent
#
# Steps: plt_symbols.py -> gcc -> link at the address of the new segment (elf_add_segment.py
# --vaddr) -> check: no writable data, no relocations -> elf_add_segment.py -> branches.
#
# usage: build.py <dir> <in.elf> <out.elf>
# env:   TOOLCHAIN  arm-none-eabi bin dir (default: port/toolchains/gcc-arm-none-eabi-4_8-2013q4/bin,
#                   GNU Tools for ARM Embedded 4.8 2013q4, downloaded on first use)
import glob
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.environ.get("TOOLCHAIN") or os.path.join(
    HERE, "../../toolchains/gcc-arm-none-eabi-4_8-2013q4/bin")
TC_TARBALL = ("https://launchpad.net/gcc-arm-embedded/4.8/4.8-2013-q4-major/+download/"
              "gcc-arm-none-eabi-4_8-2013q4-20131204-linux.tar.bz2", "4869e6a6e1dc11ea0835e8b8213bb194")
CFLAGS = ["-mthumb", "-mcpu=cortex-a9", "-mfloat-abi=softfp", "-Os", "-fPIE", "-ffreestanding",
          "-fno-builtin", "-fno-stack-protector", "-fno-exceptions", "-fno-asynchronous-unwind-tables",
          "-fno-unwind-tables", "-fvisibility=hidden", "-Wall", "-Werror", "-Wno-unused-function"]


def tool(name):
    return os.path.join(TC, "arm-none-eabi-" + name)


def ensure_toolchain():
    """download and unpack the default toolchain into port/toolchains if it is not there"""
    if os.environ.get("TOOLCHAIN") or os.path.exists(tool("gcc")):
        return
    url, md5 = TC_TARBALL
    top = os.path.dirname(os.path.dirname(TC))
    os.makedirs(top, exist_ok=True)
    tar = os.path.join(top, os.path.basename(url))
    subprocess.check_call(["curl", "-sfL", "--retry", "3", "-o", tar, url])
    if hashlib.md5(open(tar, "rb").read()).hexdigest() != md5:
        sys.exit("%s: md5 mismatch" % tar)
    subprocess.check_call(["tar", "xjf", tar, "-C", top])
    os.remove(tar)


def thumb_bw(src, dst):
    """encoding of Thumb-2 B.W from src to dst"""
    off = dst - (src + 4)
    assert -(1 << 24) <= off < (1 << 24) and off % 2 == 0, hex(off)
    s = (off >> 24) & 1
    i1, i2 = (off >> 23) & 1, (off >> 22) & 1
    j1, j2 = (~(i1 ^ s)) & 1, (~(i2 ^ s)) & 1
    imm10, imm11 = (off >> 12) & 0x3ff, (off >> 1) & 0x7ff
    return struct.pack("<HH", 0xf000 | (s << 10) | imm10, 0x9000 | (j1 << 13) | (j2 << 11) | imm11)


def thumb_bl(src, dst):
    """encoding of Thumb-2 BL (to Thumb code) from src to dst"""
    hw1, hw2 = struct.unpack("<HH", thumb_bw(src, dst))
    return struct.pack("<HH", hw1, hw2 | 0x4000)


def file_offset(d, vaddr):
    """file offset of a virtual address (inside a PT_LOAD segment)"""
    e_phoff, = struct.unpack_from("<I", d, 0x1c)
    e_phentsize, e_phnum = struct.unpack_from("<HH", d, 0x2a)
    for i in range(e_phnum):
        p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<5I", d, e_phoff + i * e_phentsize)
        if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_filesz:
            return vaddr - p_vaddr + p_offset
    sys.exit("0x%x is in no loaded segment" % vaddr)


def main(src_dir, in_elf, out_elf):
    ensure_toolchain()
    cfg =[l.split() for l in open(os.path.join(src_dir, "hooks.txt")) if l.strip() and not l.startswith("#")]
    imports = [f for c in cfg if c[0] == "import" for f in c[1:]]
    md5 = [c[1] for c in cfg if c[0] == "md5"]
    d = open(in_elf, "rb").read()
    if md5 and hashlib.md5(d).hexdigest() != md5[0]:
        sys.exit("%s: md5 %s, want %s" % (in_elf, hashlib.md5(d).hexdigest(), md5[0]))
    vaddr = int(subprocess.check_output([sys.executable, os.path.join(HERE, "elf_add_segment.py"),
                                         "--vaddr", in_elf]).decode(), 16)
    with tempfile.TemporaryDirectory() as w:
        subprocess.check_call([sys.executable, os.path.join(HERE, "plt_symbols.py"), in_elf,
                               os.path.join(w, "imports.S")] + imports)
        with open(os.path.join(w, "imports.S"), "a") as f:
            f.write("    .thumb\n")
            for c in cfg:
                if c[0] == "extern":
                    f.write("    .global %s\n    .type %s, %%function\n    .set %s, 0x%x\n"
                            % (c[1], c[1], c[1], int(c[2], 16) | 1))
        objs = []
        srcs = sorted(glob.glob(os.path.join(src_dir, "*.c")) + glob.glob(os.path.join(src_dir, "*.S")))
        for c in srcs + [os.path.join(w, "imports.S")]:
            o = os.path.join(w, os.path.basename(c) + ".o")
            subprocess.check_call([tool("gcc")] + CFLAGS + ["-I", HERE, "-c", c, "-o", o])
            objs.append(o)
        ld = os.path.join(w, "seg.ld")
        open(ld, "w").write("""
SECTIONS {
  . = 0x%x;
  .text : { *(.text*) *(.rodata*) }
  .data : { *(.data*) *(.bss*) *(COMMON) *(.got*) }
  /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) *(.note*) }
}
ASSERT(SIZEOF(.data) == 0, "the added segment must not have writable data or a GOT");
""" % vaddr)
        elf = os.path.join(w, "seg.elf")
        libgcc = subprocess.check_output([tool("gcc")] + CFLAGS[:3] + ["-print-libgcc-file-name"]).decode().strip()
        subprocess.check_call([tool("ld"), "-T", ld, "-o", elf, "--no-undefined"] + objs + [libgcc])
        rel = subprocess.check_output([tool("readelf"), "-r", elf]).decode()
        assert "Relocation section" not in rel, rel
        syms = {}
        for line in subprocess.check_output([tool("nm"), elf]).decode().splitlines():
            a, t, n = line.split()
            syms[n] = int(a, 16)
        binf = os.path.join(w, "seg.bin")
        subprocess.check_call([tool("objcopy"), "-O", "binary", "-j", ".text", elf, binf])
        seg_size = os.path.getsize(binf)
        tmp = os.path.join(w, "out.elf")
        subprocess.check_call([sys.executable, os.path.join(HERE, "elf_add_segment.py"),
                               in_elf, binf, tmp])
        out = bytearray(open(tmp, "rb").read())
    for c in cfg:
        if c[0] not in ("hook", "call"):
            continue
        sym, addr, orig = c[1], int(c[2], 16), bytes.fromhex(c[3])
        off = file_offset(out, addr)
        assert bytes(out[off:off + len(orig)]) == orig, "%s: bytes at 0x%x differ" % (sym, addr)
        code = thumb_bw(addr, syms[sym]) if c[0] == "hook" else thumb_bl(addr, syms[sym])
        out[off:off + 4] = code
        print("%s 0x%x -> %s 0x%x" % (c[0], addr, sym, syms[sym]))
    open(out_elf, "wb").write(out)
    print("%s: segment 0x%x, %d bytes, md5 %s" % (out_elf, vaddr, seg_size, hashlib.md5(out).hexdigest()))


if __name__ == "__main__":
    main(*sys.argv[1:4])
