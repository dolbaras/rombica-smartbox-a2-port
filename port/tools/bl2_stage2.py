"""Stage 2 of a RAM boot: BL2 is already in its USB mode (DDR up). Load <bl2> + <fip> and run.

usage: bl2_stage2.py <bl2> <fip> <aml-flash-tool datas dir>
"""
import sys

from pyamlboot import pyamlboot

bl2, fip, datas = sys.argv[1:4]
import time
for _ in range(150):
    try:
        dev = pyamlboot.AmlogicSoC()
        ident = [ord(c) for c in dev.identify()]
        break
    except Exception:
        time.sleep(0.2)
else:
    sys.exit('BL2 USB mode not found')
print('id', ident)
dev.writeLargeMemory(0xd9000000, open(bl2, 'rb').read(), 64)
dev.writeLargeMemory(0xd900c000, open(f'{datas}/usbbl2runpara_runfipimg.bin', 'rb').read(), 48)
dev.writeLargeMemory(0x200c000, open(fip, 'rb').read(), 64, True)
try:
    dev.run(0xd900c000 if ident[3] == 8 else 0xd9000000)
except Exception:
    pass
print('started', bl2, '+', fip)
