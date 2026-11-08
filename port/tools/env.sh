# Source this file: sets up paths for the Amlogic USB tools in this folder.
#   source "$(dirname "$0")/env.sh"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$TOOLS/../.." && pwd)"
export PYTHONPATH="$TOOLS/pylib${PYTHONPATH:+:$PYTHONPATH}"
UPDATE="$TOOLS/bin/update"          # Amlogic USB burning CLI (khadas/utils, needs libusb-0.1)
DATAS="$TOOLS/datas"                 # usbbl2runpara_*.bin parameter blobs for BL2 USB boot
BACKUP="${BACKUP:-$PROJECT/backup/vplt_working_2026-09-29}"   # own eMMC backup (restore_vplt_bootloader.sh)
STOCK="$TOOLS/stock_vplt"            # DDR.USB / UBOOT.USB / bootloader / _aml_dtb from VPLT image
