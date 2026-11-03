#!/usr/bin/env bash
# Copy the sms37 bridge onto the dongle over ADB (run from this folder).
# Uses the bot token and chat id from ~/.config/sms-forward/telegram.env.
set -euo pipefail
cd "$(dirname "$0")"
D=/data/local/sms37
. ~/.config/sms-forward/telegram.env
cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
printf 'TOKEN=%s\nCHAT=%s\n' "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" > "$cfg"

adb shell "mkdir -p $D/bin $D/tmp"
adb push sms37.sh json.awk run.sh $D/ >/dev/null
adb push "$cfg" $D/config >/dev/null
adb push /etc/ssl/certs/ca-certificates.crt $D/cacert.pem >/dev/null
adb shell "busybox --install -s $D/bin; chmod 700 $D; chmod 600 $D/config; chmod 755 $D/*.sh; touch $D/log"
# Restart the bridge so it picks up the new files (the pattern can't match this shell itself).
adb shell 'for p in $(busybox pgrep -f "sms37/(run|sms37)[.]sh"); do kill $p; done'
adb shell "/system/bin/busybox setsid /system/bin/busybox sh $D/run.sh </dev/null >/dev/null 2>&1 &"
echo "Copied to $D on the dongle and restarted the bridge."
