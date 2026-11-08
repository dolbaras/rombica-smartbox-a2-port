"""Stage 1 of a RAM boot through the real BootROM (id 2.4): load <bl2>, init DDR, return.

usage: rom_stage1.py <bl2> <aml-flash-tool datas dir>
"""
import sys
import time

from pyamlboot import pyamlboot

bl2, datas = sys.argv[1:3]
for _ in range(450):
    try:
        dev = pyamlboot.AmlogicSoC()
        ident = [ord(c) for c in dev.identify()]
        break
    except Exception:
        time.sleep(0.2)
else:
    sys.exit('no device')
print('id', ident)
if ident[:2] != [2, 4]:
    sys.exit('not in BootROM')
dev.writeMemory(0xd9000000, open(bl2, 'rb').read()[:0xC000])
dev.writeLargeMemory(0xd900c000, open(f'{datas}/usbbl2runpara_ddrinit.bin', 'rb').read(), 32)
try:
    dev.run(0xd9000000)
except Exception:
    pass
print('BL2 started (DDR init)')
