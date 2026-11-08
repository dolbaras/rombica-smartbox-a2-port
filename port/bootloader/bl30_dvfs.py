#!/usr/bin/python3
"""Replace the CPU DVFS table in the stock VPLT BL30 (bl30.enc of the FIP).

The SCP firmware (BL301 part of BL30) owns CPU frequency and voltage on GXL; Linux and Android
only pick one of its table entries over SCPI. The stock VPLT table stops at 1.2 GHz:
    100/250/500 MHz 910 mV, 667 MHz 950, 1000 MHz 990, 1200 MHz 1070
The entry count is compiled into the code, so the new table keeps 6 entries (sorted). Voltages
must be steps of the board PWM table in the same BL301 (860..1140 mV, 10 mV steps); the
Amlogic reference table for this board (U-Boot board/amlogic/gxl_p271_v1/firmware/scp_task/
dvfs_board.c) runs 1512 MHz at 1110+30 mV.

usage: bl30_dvfs.py <gxlimg> <bl30.enc in> <bl30.enc out> <MHz:mV>x6
"""
import os
import struct
import subprocess
import sys
import tempfile

STOCK = [(100, 910), (250, 910), (500, 910), (667, 950), (1000, 990), (1200, 1070)]
TABLE_OFF = 0xc6b8                     # in the decrypted bl30_new.bin (BL301 starts at 0xa000)
PWM_OFF = 0xc5d0                       # board PWM voltage table: (reg, mV) x 29, 860..1140


def pack(tbl):
    return b''.join(struct.pack('<II', mhz * 1000000, mv) for mhz, mv in tbl)


def main():
    gxlimg, src, dst = sys.argv[1:4]
    new = [tuple(int(x) for x in a.split(':')) for a in sys.argv[4:]]
    assert len(new) == len(STOCK), 'need %d entries' % len(STOCK)
    assert all(a[0] < b[0] for a, b in zip(new, new[1:])), 'frequencies must ascend'
    with tempfile.TemporaryDirectory() as w:
        raw = os.path.join(w, 'bl30_new.bin')
        subprocess.run([gxlimg, '-t', 'bl3x', '-d', src, raw], check=True, stdout=subprocess.DEVNULL)
        d = bytearray(open(raw, 'rb').read())
        assert d[TABLE_OFF:TABLE_OFF + 48] == pack(STOCK), 'not the stock VPLT DVFS table'
        volts = [struct.unpack_from('<II', d, PWM_OFF + 8 * i)[1] for i in range(29)]
        assert volts == list(range(860, 1141, 10)), 'board PWM table not as expected'
        assert all(mv in volts for _, mv in new), 'voltage not a PWM step'
        d[TABLE_OFF:TABLE_OFF + 48] = pack(new)
        open(raw, 'wb').write(d)
        subprocess.run([gxlimg, '-t', 'bl3x', '-c', raw, dst], check=True, stdout=subprocess.DEVNULL)
    print('BL30 DVFS table: ' + ', '.join('%d MHz %d mV' % e for e in new))


if __name__ == '__main__':
    main()
