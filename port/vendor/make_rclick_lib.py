#!/usr/bin/python3
"""Make the "right click" copy of SlimBOX's /system/lib/libinputflinger.so.

SlimBOX 9.20 maps the right mouse button to AMOTION_EVENT_BUTTON_BACK (8) in
CursorButtonAccumulator::getButtonState(), so every app gets KEYCODE_BACK instead of a right
click (remote desktop clients cannot send one). Upstream Android maps it to
AMOTION_EVENT_BUTTON_SECONDARY (2). The function is also inlined into CursorInputMapper::sync(),
which is the copy that matters; both get the same one-immediate change:
    getButtonState():  orrne.w r0, r0, #8  ->  #2       (file offset 0x31826)
    sync() (inlined):  orrne.w r9, r9, #8  ->  #2       (file offset 0x345dc)
build.sh puts the result (with the keyboard code of native/inputflinger) into the system image;
BACK on the right button is then the kernel's part (hid right_button_back, kernel patch 0010), switched at
once by the "Remote desktop mode" switch (persist.vendor.mouse_touch_input).

usage: make_rclick_lib.py <libinputflinger.so from the SlimBOX system> <out.so>
"""
import hashlib
import sys

MD5 = '2467935255efcf8fef2d6cf10936b953'      # SlimBOX 9.20 ATV and AOSP, identical
# (offset of the 8-byte context, old, new): it ne; orrne.w rX,rX,#8 -> #2 for "if (mBtnRight)"
PATCHES = [
    (0x31822, '18bf40f00800002b', '18bf40f00200002b'),   # getButtonState(); then cmp r3,#0
    (0x345d6, 'c67d18bf49f00809', 'c67d18bf49f00209'),   # sync(): ldrb r6,[r0,#23]; it ne; orrne
]


def main():
    d = bytearray(open(sys.argv[1], 'rb').read())
    assert hashlib.md5(d).hexdigest() == MD5, 'not the SlimBOX 9.20 libinputflinger.so'
    for off, old, new in PATCHES:
        assert d[off:off + 8] == bytes.fromhex(old), 'code at 0x%x not as expected' % off
        d[off:off + 8] = bytes.fromhex(new)
    open(sys.argv[2], 'wb').write(d)
    print('right button -> BUTTON_SECONDARY: %s' % sys.argv[2])


if __name__ == '__main__':
    main()
