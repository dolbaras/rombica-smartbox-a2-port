#!/bin/bash
# Apply overlay directories to a raw vendor ext4 image (also used to replace files in the system
# image, whose root holds /system/...: replaced files keep their mode, owner and label):
#   <dir>/<path>          copied to /<path>; a file replacing an existing one keeps its mode, owner
#                         and SELinux label (e.g. /bin/systemcontrol), a new one is root:root 0644
#                         (new directories root:shell 0755)
#   <dir>/<path>.append   appended to the existing /<path>, keeping its mode and label
#   <dir>/<subdir>/.replace   all files already in /<subdir> are removed first
# SELinux label of new files by path: /app/* vendor_app_file, /overlay/* vendor_overlay_file,
# /lib/* vendor_file, everything else vendor_configs_file.
#
# usage: apply_overlay.sh <vendor.ext4> [dir ...]      (default dir: overlay/ next to this script)
set -e
IMG="$(realpath "$1")"; shift
[ $# -gt 0 ] || set -- "$(dirname "$0")/overlay"
DIRS=(); for d in "$@"; do DIRS+=("$(realpath "$d")"); done
CTX=$(mktemp); TMP=$(mktemp)
label() {                              # label <vendor path> -> $CTX holds the xattr value
  case "$1" in
    /app|/app/*) l=vendor_app_file ;;
    /overlay|/overlay/*) l=vendor_overlay_file ;;
    /lib|/lib/*) l=vendor_file ;;
    *) l=vendor_configs_file ;;
  esac
  printf 'u:object_r:%s:s0\0' "$l" > "$CTX"
}
for DIR in "${DIRS[@]}"; do
cd "$DIR"
find . -name .replace -type f | sort | while read -r m; do
  d="/$(dirname "${m#./}")"
  debugfs -R "ls -p $d" "$IMG" 2>/dev/null | awk -F/ '$3 ~ /^10/ {print $6}' | while read -r n; do
    debugfs -w -R "rm $d/$n" "$IMG" >/dev/null 2>&1
  done
  echo "emptied $d"
done
find . -type f ! -name .replace | sort | while read -r f; do
  p="/${f#./}"
  if [[ "$p" == *.append ]]; then
    p="${p%.append}"
    mode=$(debugfs -R "stat $p" "$IMG" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p')
    label=$(debugfs -R "ea_get $p security.selinux" "$IMG" 2>/dev/null | sed -n 's/.*= "\(u:[^"\\]*\).*/\1/p')
    [ -n "$mode" ] && [ -n "$label" ] || { echo "cannot append, $p missing"; exit 1; }
    debugfs -R "cat $p" "$IMG" 2>/dev/null > "$TMP"
    grep -qxF "$(head -1 "$f")" "$TMP" || cat "$f" >> "$TMP"      # idempotent
    printf '%s\0' "$label" > "$CTX.l"
    debugfs -w -R "rm $p" "$IMG" >/dev/null 2>&1
    debugfs -w -f - "$IMG" >/dev/null <<CMD
write $TMP $p
set_inode_field $p mode 0100${mode: -3}
set_inode_field $p uid 0
set_inode_field $p gid 0
ea_set -f $CTX.l $p security.selinux
CMD
    echo "appended to $p"
    continue
  fi
  # create missing parent directories (root:shell 0755, vendor_configs_file)
  d=""
  for part in $(dirname "$p" | tr '/' ' '); do
    d="$d/$part"
    debugfs -R "stat $d" "$IMG" 2>/dev/null | grep -q "Type: directory" && continue
    label "$d"
    debugfs -w -f - "$IMG" >/dev/null 2>&1 <<CMD
mkdir $d
set_inode_field $d mode 040755
set_inode_field $d uid 0
set_inode_field $d gid 2000
ea_set -f $CTX $d security.selinux
CMD
    echo "mkdir $d"
  done
  label "$p"
  mode=0644; uid=0; gid=0
  old=$(debugfs -R "stat $p" "$IMG" 2>/dev/null) || true
  if echo "$old" | grep -q "Type: regular"; then         # replacing: keep mode, owner, label
    mode=$(echo "$old" | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p'); mode=${mode: -4}
    uid=$(echo "$old" | sed -n 's/.*User: *\([0-9]*\).*/\1/p')
    gid=$(echo "$old" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p')
    l=$(debugfs -R "ea_get $p security.selinux" "$IMG" 2>/dev/null | sed -n 's/.*= "\(u:[^"\\]*\).*/\1/p')
    [ -n "$l" ] && printf '%s\0' "$l" > "$CTX"
  fi
  debugfs -w -R "rm $p" "$IMG" >/dev/null 2>&1 || true
  debugfs -w -f - "$IMG" >/dev/null <<CMD
write $f $p
set_inode_field $p mode 0$(printf '%o' $((0100000 | 8#$mode)))
set_inode_field $p uid $uid
set_inode_field $p gid $gid
ea_set -f $CTX $p security.selinux
CMD
  debugfs -R "stat $p" "$IMG" 2>/dev/null | grep -q "Size: $(stat -c %s "$f")" \
    || { echo "FAILED to add $p"; exit 1; }
  echo "added $p"
done
done

# SlimBOX 9.20 ships three libraries with a truncated label ("...:vendor_app_file:s", no level),
# which the kernel treats as unlabeled. Give them the intended one.
printf 'u:object_r:vendor_app_file:s0\0' > "$CTX"
for p in /lib/libsystemcontrol_jni.so /lib/libsystemcontrolclient.so /lib/libsystemcontrolservice.so; do
  debugfs -R "ea_get $p security.selinux" "$IMG" 2>/dev/null | grep -q 'vendor_app_file:s\\000"' || continue
  debugfs -w -R "ea_set -f $CTX $p security.selinux" "$IMG" >/dev/null 2>&1
  debugfs -R "ea_get $p security.selinux" "$IMG" 2>/dev/null | grep -q 'vendor_app_file:s0' \
    || { echo "FAILED to relabel $p"; exit 1; }
  echo "relabeled $p"
done
rm -f "$CTX" "$CTX.l" "$TMP"
