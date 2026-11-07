# Setup guide

From a new dongle to texts arriving in Telegram. Allow about 20 minutes.

**You need:**

- A UZ801 dongle with a working SIM (insert the SIM with the dongle unplugged)
- A Linux PC for the install. It's only needed once. The commands below are for Ubuntu or Debian
- A Telegram account
- A USB power bank, for running it away from the PC

```mermaid
flowchart LR
    A[Plug in the dongle] --> B[Install adb on the PC]
    B --> C[Turn on ADB in the dongle]
    C --> D[Check the tools]
    D --> E[Create a Telegram bot]
    E --> F[Install the bridge]
    F --> G[Test it]
    G --> H[Move to a power bank]
```

## 1. Plug in the dongle

Plug it into the PC and wait about 30 seconds, then check that the PC sees it.

```bash
lsusb | grep 05c6
```

```text
Bus 001 Device 002: ID 05c6:f00e Qualcomm, Inc. FP3
```

`05c6` is Qualcomm. The "FP3" text is only the name `lsusb` has on file for that ID, and you can ignore it. The dongle's web page should also answer:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.100.1/
```

This should print `200`.

## 2. Install adb on the PC

```bash
sudo apt install adb
```

The USB device needs root access, so start the adb server as root:

```bash
sudo adb kill-server; sudo adb start-server
```

The server keeps running, and your normal `adb` commands use it. After rebooting the PC you need to start it again.

## 3. Turn on ADB in the dongle

Send the command that the dongle's hidden `usbdebug.html` page sends. Opening `http://192.168.100.1/usbdebug.html` in a browser does the same thing.

```bash
curl -m 20 -X POST -d '{"funcNo":2001}' http://192.168.100.1/ajax
```

The USB connection drops and the dongle comes back, so the command may print nothing. Wait about 30 seconds and check again:

```bash
lsusb | grep 05c6
adb devices -l
```

```text
Bus 001 Device 005: ID 05c6:90b6 Qualcomm, Inc. Android
0123456789ABCDEF       device usb:1-2 product:msm8916_32_512 model:UZ801 device:msm8916_32_512
```

The new ID `05c6:90b6` means ADB is on. The setting survives reboots, so you only do this once.

## 4. Check the tools

Check that your firmware has what the bridge needs:

```bash
adb shell 'id; getprop ro.build.version.release; getprop ro.build.display.id; ls /system/bin/busybox /system/bin/runcon /system/bin/curl /system/xbin/sqlite3 2>&1'
```

You want `uid=0(root)`, Android `4.4.4`, and all four tools found. See [device.md](device.md#check-your-stick) if something is missing.

## 5. Create a Telegram bot

1. In Telegram, open **@BotFather** and send `/newbot`. Follow the steps and copy the token it gives you.
2. Run the setup script from this repo:

   ```bash
   bash pc/setup.sh
   ```

3. Paste the token when asked. It stays hidden, and it's saved only to `~/.config/sms-forward/telegram.env` with owner-only permissions.
4. Open your new bot in Telegram and press **Start**. Wait a few seconds, then press Enter in the terminal.

You should get this message from your bot: `✅ SMS forwarder on this PC is connected.`

If the script says "No messages yet", your Start hadn't reached Telegram yet. Run this after a moment:

```bash
python3 pc/sms_forward.py link && python3 pc/sms_forward.py test
```

**Optional: add the command menu.** In @BotFather, send `/setcommands`, pick your bot, and paste:

```text
start - start the bot
help - list the commands
check - show recent texts
calls - show recent calls
send - send an SMS
```

## 6. Install the bridge

First the boot hook, which adds one new file to the dongle's system partition:

```bash
dongle/install-boot-hook.sh
```

```text
-rwxr-xr-x root     shell             u:object_r:system_file:s0 install-recovery.sh
Boot hook installed. /system is read-only again.
```

Then the bridge itself:

```bash
dongle/install.sh
```

```text
Copied to /data/local/sms37 on the dongle and restarted the bridge.
```

## 7. Test it

Check that it's running. You should see `run.sh` and `sms37.sh`:

```bash
adb shell 'busybox ps | busybox grep -E "run.sh|sms37.sh" | busybox grep -v grep; busybox tail -n 5 /data/local/sms37/log'
```

Then in Telegram:

| Try this | You should see |
|---|---|
| Send `/help` to the bot | The command list |
| Send a text to the SIM's number from another phone | `📩 number · time` plus the text, within about 30 seconds |
| Send `/check` | The last 5 stored texts |
| Call the SIM's number, let it ring, then hang up | `📞 Missed call from number · time`, within about 30 seconds of hanging up |
| Send `/send <your number> hello`, then `/yes` | A preview, then `✅ Sent`, then the text on your phone |

Texts already stored when the bridge first starts count as seen, so they aren't forwarded. `/check` still shows them.

## 8. Move it to a power bank

Unplug the dongle and plug it into the power bank. It takes about a minute to boot and connect to LTE, and then the bot answers.

Some power banks switch off when the current draw is very low. If yours does, use one with an "always on" or low-current mode.

## Optional: run it on a PC instead

`pc/sms_forward.py` does the same job from a PC, reading the dongle over ADB. It's useful for testing, or for a dongle whose firmware lacks `curl` or `sqlite3`. It needs the dongle plugged in, and its Telegram messages go out through the PC's internet.

**Never run both versions on one bot.** They would compete for commands and forward every text twice. Remove the dongle version first, or it comes back at the next dongle reboot (see [operations.md](operations.md#stop-or-uninstall)).

```bash
python3 pc/sms_forward.py list 5      # print stored texts, sends nothing
python3 pc/sms_forward.py run         # run in the terminal
```

To run it as a service, clone the repo to `~/uz801-sms-telegram-bridge` (or edit the path in the unit file), then:

```bash
mkdir -p ~/.config/systemd/user
cp pc/sms-forward.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sms-forward
```

Next: [how it works](how-it-works.md) · [day-to-day operations](operations.md)
