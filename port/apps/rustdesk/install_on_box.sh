#!/bin/bash
# Replace the RustDesk app on the box with this build and keep its data (ID, password, peers).
# The APK is signed with another key, so it can not be installed over the official one: the data
# is saved, the app uninstalled, the APK installed and the data put back (root, before the first
# start, owned by the new uid, SELinux labels restored). A copy stays in /data/local/tmp/rd_backup.tgz.
# usage: install_on_box.sh [apk]   (adb connected to the box)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APK="${1:-$HERE/out/rustdesk-1.4.9-a2hw-armeabi-v7a.apk}"
PKG=com.carriez.flutter_hbb
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# su on the port mangles "sh -c" with quotes: the steps go to the box as script files
cat > "$W/rd_save.sh" <<EOF
cd /data/data && tar -czf /data/local/tmp/rd_backup.tgz $PKG
EOF
cat > "$W/rd_restore.sh" <<EOF
P=$PKG
am force-stop \$P
U=\$(stat -c %u /data/data/\$P) || exit 1
cd /data/local/tmp && rm -rf rd_restore && mkdir rd_restore && cd rd_restore || exit 1
tar -xzf ../rd_backup.tgz || exit 1
for d in app_flutter files shared_prefs; do
    [ -d \$P/\$d ] || continue
    rm -rf /data/data/\$P/\$d
    cp -a \$P/\$d /data/data/\$P/ || exit 1
    chown -R \$U:\$U /data/data/\$P/\$d
done
restorecon -R /data/data/\$P
cd .. && rm -rf rd_restore
EOF
adb push "$W/rd_save.sh" "$W/rd_restore.sh" /data/local/tmp/ >/dev/null

if adb shell pm path "$PKG" | grep -q package:; then
    echo "== saving the app data"
    adb shell su 0 sh /data/local/tmp/rd_save.sh
    echo "== uninstalling"
    adb uninstall "$PKG"
fi
echo "== installing $APK"
adb install "$APK"
if adb shell su 0 ls /data/local/tmp/rd_backup.tgz >/dev/null 2>&1; then
    echo "== restoring the app data"
    adb shell su 0 sh /data/local/tmp/rd_restore.sh
fi
adb shell rm -f /data/local/tmp/rd_save.sh /data/local/tmp/rd_restore.sh
echo "done"
