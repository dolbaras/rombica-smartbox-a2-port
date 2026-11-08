#!/usr/bin/python3
"""Fix the mouse pointer in SlimBOX's Amlogic hwcomposer (/vendor/lib/hw/hwcomposer.amlogic.so).

CursorPlane::updateCursorBuffer() copies the cursor layer into the OSD cursor plane only when the
layer's stride or height differ from the plane's; otherwise it returns at once. A new pointer
image of the same size never reaches the screen: the text (I-beam) pointer stays after leaving a
text field, the large pointer stays after "Large mouse pointer" is off (Android never shrinks the
sprite surface), until a reboot. Copying on every call instead is not enough either: the full
path also re-sets the plane geometry (updatePlaneInfo, FBIOPUT_VSCREENINFO), and doing that on
every pointer move makes the moving pointer flicker.

The copy re-arranges the 36-byte size check at the start of the function (file offset 0x331c8):
    stride, height as before; r5 = &height (ldr.w r2,[r5,#128]!), r7 = stride in pixels
    stride or height differ from the plane  -> updatePlaneInfo(this, r7, r2) + copy (as before)
    same size and the plane is mapped       -> copy only            (was: return without copying)
                                                ([this+92] = mapping length set by updatePlaneInfo)

usage: make_hwc_cursor.py <hwcomposer.amlogic.so from the SlimBOX vendor> <out.so>
"""
import hashlib
import sys

MD5 = '0b71ff58aa396ed5376d4137e9032bfe'       # SlimBOX 9.20 ATV and AOSP
OFF = 0x331c8                                   # in updateCursorBuffer(), file offset == address
OLD = ('e06f' 'd4f88410' '02eb8000' '20f01f00' 'b1eba00f' '05d1'
       '55f8802f' 'a968' '9142' '02d1' '48e0' '55f8802f')
NEW = ('e06f'       # ldr   r0, [r4, #124]          width
       '1f22'       # movs  r2, #31
       '02eb8000'   # add.w r0, r2, r0, lsl #2
       '20f01f00'   # bic.w r0, r0, #31             stride in bytes, 32-aligned
       '55f8802f'   # ldr.w r2, [r5, #128]!         r5 = this + 128, r2 = height
       '8710'       # asrs  r7, r0, #2              stride in pixels
       'd4f88410'   # ldr.w r1, [r4, #132]          plane xres
       'b942'       # cmp   r1, r7
       '05d1'       # bne   update
       'a968'       # ldr   r1, [r5, #8]            plane yres
       '9142'       # cmp   r1, r2
       '02d1'       # bne   update
       'e16d'       # ldr   r1, [r4, #92]           plane mapping length
       '21b9')      # cbnz  r1, copy                (else fall into update)


def main():
    d = bytearray(open(sys.argv[1], 'rb').read())
    assert hashlib.md5(d).hexdigest() == MD5, 'not the SlimBOX 9.20 hwcomposer.amlogic.so'
    assert d[OFF:OFF + 36] == bytes.fromhex(OLD), 'updateCursorBuffer() not as expected'
    d[OFF:OFF + 36] = bytes.fromhex(NEW)
    open(sys.argv[2], 'wb').write(d)
    print('cursor plane: new pointer images copied, plane re-set only on a size change: %s'
          % sys.argv[2])


if __name__ == '__main__':
    main()
