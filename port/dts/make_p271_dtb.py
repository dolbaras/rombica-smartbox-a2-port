#!/usr/bin/env python3
"""Build the Rombica SmartBox A2 (S905L2 / GXLX, board p271) DTB from the SlimBOX gxl_p212_1g DTB.

Pin numbers need no remapping: the board uses the same physical pins as p212
(LED GPIODV_24, WiFi power GPIOX_6, WiFi IRQ GPIOX_7). Only the differences
below, taken from the stock VPLT DTB, are applied.

usage: make_p271_dtb.py <slimbox_multi_dtb> <stock_vplt_dtb> <out_dir>
Writes p271.dtb, p271.dts and _aml_dtb.img (AML_ multi-DTB, same layout as the input).
"""
import struct
import sys

import fdt

AO_GPIO_PHANDLE = 0x57
ALIGN = 2048
MAX_DTB_AREA = 0x40000


def set_prop(node, cls, name, *values):
    node.remove_property(name)
    node.append(cls(name, *values))


def max_phandle(node):
    ph = node.get_property('phandle')
    best = ph.value if ph is not None else 0
    for child in node.nodes:
        best = max(best, max_phandle(child))
    return best


def add_remote_maps(tree, stock):
    """Append the stock VPLT IR keymaps (incl. the Rombica cs918 remote, customcode 0x4040)."""
    maps = tree.get_node('/custom_maps')
    count = maps.get_property('mapnum').value
    phandle = max_phandle(tree.root)
    for src in stock.get_node('/custom_maps').nodes:
        phandle += 1
        node = fdt.Node(f'map_{count}')
        for name in ('mapname',):
            node.append(fdt.PropStrings(name, *src.get_property(name).data))
        for name in ('customcode', 'release_delay', 'size', 'keymap'):
            node.append(fdt.PropWords(name, *src.get_property(name).data))
        node.append(fdt.PropWords('phandle', phandle))
        maps.append(node)
        maps.append(fdt.PropWords(f'map{count}', phandle))
        count += 1
    set_prop(maps, fdt.PropWords, 'mapnum', count)


def patch(tree, stock):
    root = tree.root
    add_remote_maps(tree, stock)
    set_prop(root, fdt.PropStrings, 'model', 'Rombica Smart Box A2 (S905L2 p271)')

    # AP6181 (BCM43362) OOB interrupt is active-high on this board (stock DTB).
    wifi = tree.get_node('/wifi')
    set_prop(wifi, fdt.PropStrings, 'irq_trigger_type', 'GPIO_IRQ_HIGH')

    # No Bluetooth on AP6181; stock DTB keeps bt-dev disabled.
    set_prop(tree.get_node('/bt-dev'), fdt.PropStrings, 'status', 'disabled')

    # Front LED: one bi-colour LED on the sysled pin (GPIODV_24): high = blue, low = red,
    # input = off (BL30 drives it red in standby). Our kernel's sysled driver exposes
    # sysled:blue and sysled:red; kernels without that support ignore the property.
    set_prop(tree.get_node('/sysled'), fdt.PropStrings, 'led_bicolor', 'blue', 'red')

    # GPIOH_6..9 carry the I2S output (stock DTB: audio_pin). The p212 DTB lets the JTAG driver
    # claim them ("select = apao"), so the sound card's I2S pinmux failed at boot. No JTAG here.
    set_prop(tree.get_node('/jtag'), fdt.PropStrings, 'status', 'disabled')

    # SD/eMMC controllers: eMMC and microSD use the GXLX variant (as the stock DTB).
    for path in ('/emmc@d0074000', '/sd@d0072000'):
        set_prop(tree.get_node(path), fdt.PropStrings, 'compatible', 'amlogic, meson-mmc-gxlx')
    set_prop(tree.get_node('/vdac'), fdt.PropStrings, 'compatible', 'amlogic, vdac-gxlx')

    # microSD: high speed (50 MHz) like the stock DTB.
    set_prop(tree.get_node('/sd@d0072000'), fdt.PropWords, 'max-frequency', 50000000)
    set_prop(tree.get_node('/sd@d0072000/sd'), fdt.PropWords, 'f_max', 50000000)

    # eMMC in the eMCP package: stock kernel uses HS200 only, no HS400.
    set_prop(tree.get_node('/emmc@d0074000/emmc'), fdt.PropStrings, 'caps2', 'MMC_CAP2_HS200')

    # Two keys on GPIOAO_2 (reset button in AV jack) and GPIOAO_6, as in stock DTB.
    keys = tree.get_node('/gpio_keypad')
    set_prop(keys, fdt.PropWords, 'key_num', 2)
    set_prop(keys, fdt.PropStrings, 'key_name', 'power', 'power2')
    set_prop(keys, fdt.PropWords, 'key_code', 116, 116)
    set_prop(keys, fdt.PropWords, 'key-gpios', AO_GPIO_PHANDLE, 2, 0, AO_GPIO_PHANDLE, 6, 0)

    # Chip id: cpu_version stays at the fused id register (AO_SEC_SD_CFG8); our kernel knows
    # GXLX (S905L2) as a GXL-family SoC (port/kernel/patches).

    # S905L2 has a Mali-450 MP2 (S905X: MP3). With num_of_pp=3 the driver touches the missing
    # PP2 and dies with "external abort on non-linefetch". Take the PP layout from the stock DTB
    # (it names the default clock def_clock; kernel 4.9 reads def_clk).
    mali, smali = tree.get_node('/mali@d00c0000'), stock.get_node('/mali')
    for name in ('num_of_pp', 'sc_mpp', 'pmu_domain_config', 'tbl', 'interrupts'):
        set_prop(mali, fdt.PropWords, name, *smali.get_property(name).data)
    set_prop(mali, fdt.PropStrings, 'interrupt-names', *smali.get_property('interrupt-names').data)
    set_prop(mali, fdt.PropWords, 'def_clk', *smali.get_property('def_clock').data)


def aml_dt_field(text):
    """Encode a multi-DTB name field: 16 bytes, space padded, every 32-bit word byte-reversed."""
    raw = text.ljust(16).encode()
    return b''.join(raw[i:i + 4][::-1] for i in range(0, 16, 4))


def main():
    src, stock_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    stock = fdt.parse_dtb(open(stock_path, 'rb').read())
    multi = bytearray(open(src, 'rb').read())
    assert multi[:4] == b'AML_', 'expected AML_ multi-DTB'
    version, count = struct.unpack('<II', multi[4:12])
    assert version == 2
    entries = []
    for i in range(count):
        o = 12 + i * 56
        entries.append((o, *struct.unpack('<II', multi[o + 48:o + 56])))

    first_off, first_size = entries[0][1], entries[0][2]
    tree = fdt.parse_dtb(bytes(multi[first_off:first_off + first_size]))
    patch(tree, stock)
    dtb = tree.to_dtb(version=17)

    open(f'{out}/p271.dtb', 'wb').write(dtb)
    open(f'{out}/p271.dts', 'w').write(tree.to_dts())

    # Same DTB for every entry (the board has 1 GB, but U-Boot may pick by aml_dt).
    # Rebuild the container, re-lay out slots for the new size. Entry names: the p271 U-Boot looks
    # up aml_dt=gxl_p271_<ram> (else disk_initial fails with "Not match any dtb"); the stock VPLT
    # U-Boot has aml_dt=gxl_p212_1g, so the last entry is gxl_p212_1g (install from a stock box).
    slot = -(-len(dtb) // ALIGN) * ALIGN
    header = bytearray(multi[:12 + count * 56])
    data_start = first_off
    image = bytearray(data_start + slot * count)
    for i, (o, _, _) in enumerate(entries):
        off = data_start + i * slot
        struct.pack_into('<II', header, o + 48, off, slot)
        assert header[o + 16:o + 32] == aml_dt_field('p212')
        if i < count - 1:                           # gxl_p271_1g, gxl_p271_2g: our U-Boot
            header[o + 16:o + 32] = aml_dt_field('p271')
        else:                                       # gxl_p212_1g: stock VPLT U-Boot (aml_dt)
            header[o + 32:o + 48] = aml_dt_field('1g')
        image[off:off + len(dtb)] = dtb
    image[:len(header)] = header
    assert len(image) <= MAX_DTB_AREA, '_aml_dtb larger than U-Boot DTB area'
    open(f'{out}/_aml_dtb.img', 'wb').write(image)
    print(f'p271.dtb {len(dtb)} bytes, _aml_dtb.img {len(image)} bytes ({count} entries, slot {slot})')


if __name__ == '__main__':
    main()
