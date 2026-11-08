"""Change the code of a system app of SlimBOX while keeping SlimBOX's signature (helpers for
make_settings_nobt.py, make_tvsettings_vesa.py and make_autostart_locked_boot.py).

System apps of SlimBOX are signed with SlimBOX's keys (APK Signature Scheme v3), and those that
share the system uid must stay signed with the platform key, which only SlimBOX has. For apps on
the system partition Android reads the signer certificate without hashing the contents
(PackageManagerService: skipVerify for system directories), but it still checks the content
length recorded in the signature (the APK verity digest). So the APK keeps its size and layout:
the new dex is written deflated in the place of the old one (the rest of that room is left as
zeros between two entries, which ZIP allows), and only that entry's central directory record
changes; every other entry, the signing block and the central directory stay
where they are. Android then extracts the dex at dexopt instead of mapping it from the APK, and
the app's precompiled code in oat/ no longer matches (build.sh removes it).

The code is changed as smali (baksmali -> edit -> smali 2.5.2); each edit checks the code it
expects first.
"""
import os
import struct
import subprocess
import tempfile
import zipfile
import zlib

SMALI_DIR = os.environ.get('SMALI_DIR') or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                        '../toolchains/smali')


def jar(name):
    return os.path.join(SMALI_DIR, '%s-2.5.2.jar' % name)


def patch_apk(src, dst, edit, dex='classes.dex'):
    """<src> -> <dst> with <dex> changed by edit(<smali dir>)"""
    with tempfile.TemporaryDirectory() as w:
        with zipfile.ZipFile(src) as z:
            open(os.path.join(w, 'classes.dex'), 'wb').write(z.read(dex))
        # one thread: the class order in the new dex is then always the same (reproducible)
        subprocess.check_call(['java', '-jar', jar('baksmali'), 'd', '-j', '1',
                               '-o', os.path.join(w, 'smali'), os.path.join(w, 'classes.dex')])
        edit(os.path.join(w, 'smali'))
        out = os.path.join(w, 'classes_new.dex')
        subprocess.check_call(['java', '-jar', jar('smali'), 'a', '-j', '1', '-a', '28', '-o', out,
                               os.path.join(w, 'smali')])
        apk = replace_entry(src, dex, open(out, 'rb').read())
    open(dst, 'wb').write(apk)
    with zipfile.ZipFile(dst) as z:                     # the result reads back as a ZIP
        assert z.testzip() is None


def replace_text(path, old, new):
    s = open(path).read()
    assert s.count(old) == 1, '%s: unexpected code' % os.path.basename(path)
    open(path, 'w').write(s.replace(old, new))


def replace_entry(apk, name, data):
    """the APK with entry <name> replaced in place, the file size kept (see above)"""
    d = bytearray(open(apk, 'rb').read())
    eocd = d.rindex(b'PK\x05\x06')
    cd_size, cd_off = struct.unpack_from('<II', d, eocd + 12)
    assert d[cd_off - 16:cd_off] == b'APK Sig Block 42', 'no APK signing block'
    blk_size, = struct.unpack_from('<Q', d, cd_off - 24)
    blk_off = cd_off - blk_size - 8

    entries, pos = [], cd_off                           # (local header offset, CD record offset)
    while pos < cd_off + cd_size:
        assert d[pos:pos + 4] == b'PK\x01\x02'
        nlen, xlen, clen = struct.unpack_from('<HHH', d, pos + 28)
        off, = struct.unpack_from('<I', d, pos + 42)
        entries.append((off, pos, bytes(d[pos + 46:pos + 46 + nlen])))
        pos += 46 + nlen + xlen + clen
    entries.sort()
    k = [e[2] for e in entries].index(name.encode())
    start, rec, enc = entries[k]
    end = entries[k + 1][0] if k + 1 < len(entries) else blk_off     # the entry's room

    # zopfli: SlimBOX's own deflated dex files are packed tighter than zlib -9 can (AutostartApp's
    # classes2.dex: 98785 bytes, zlib -9 104942, zopfli 89379), so zlib's output may not fit
    with tempfile.NamedTemporaryFile() as f:
        f.write(data)
        f.flush()
        packed = subprocess.run(['zopfli', '--deflate', '-c', f.name], check=True,
                                stdout=subprocess.PIPE).stdout
    crc = zlib.crc32(data) & 0xffffffff
    flags, = struct.unpack_from('<H', d, rec + 8)
    mtime, mdate = struct.unpack_from('<HH', d, rec + 12)
    local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, flags & ~0x8, 8, mtime, mdate, crc,
                        len(packed), len(data), len(enc), 0) + enc + packed
    assert len(local) <= end - start, 'the new entry does not fit in place'
    d[start:end] = local + bytes(end - start - len(local))   # the rest of the room stays unused
    struct.pack_into('<HH', d, rec + 8, flags & ~0x8, 8)
    struct.pack_into('<III', d, rec + 16, crc, len(packed), len(data))
    return bytes(d)


