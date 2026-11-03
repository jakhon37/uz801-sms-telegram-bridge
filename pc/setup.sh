#!/usr/bin/env bash
# Store the Telegram bot token (typed here, never shown) and link your chat.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
cfg="$HOME/.config/sms-forward/telegram.env"

echo "1. In Telegram, open @BotFather, send /newbot and follow the steps."
echo "2. Paste the token BotFather gives you here (input is hidden)."
read -rsp "Bot token: " token
echo
mkdir -p "$(dirname "$cfg")"
umask 077
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token" > "$cfg"
chmod 600 "$cfg"
echo "Saved to $cfg"

echo "3. Now open your new bot in Telegram and press Start (or send it any message)."
read -rp "Press Enter when done... " _
python3 "$dir/sms_forward.py" link
python3 "$dir/sms_forward.py" test
echo "Check Telegram for the test message."
