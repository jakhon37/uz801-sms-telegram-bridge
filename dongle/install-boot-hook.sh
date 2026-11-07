#!/usr/bin/env bash
# Add /system/etc/install-recovery.sh, which starts the bridge at every boot.
# Run once per dongle, before install.sh. Refuses to replace somebody else's file.
set -euo pipefail
cd "$(dirname "$0")"
HOOK=/system/etc/install-recovery.sh

# adb on Android 4.4 returns no exit codes, so check the output instead.
existing=$(adb shell "cat $HOOK 2>/dev/null" | tr -d '\r')
case "$existing" in
    ''|*'No such file'*|*sms37*) ;;
    *) echo "$HOOK already exists and is not ours. Look at it first:"; echo "$existing"; exit 1 ;;
esac

adb push install-recovery.sh /data/local/tmp/install-recovery.sh >/dev/null
adb shell "mount -o remount,rw /system && busybox cp /data/local/tmp/install-recovery.sh $HOOK \
    && chmod 755 $HOOK && chown root:shell $HOOK; sync; mount -o remount,ro /system; \
    rm /data/local/tmp/install-recovery.sh; ls -lZ $HOOK"
echo "Boot hook installed. /system is read-only again."
