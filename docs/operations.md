# Operations

Everyday tasks and fixes. All `adb` commands need the dongle plugged into a PC, with the adb server running:

```bash
sudo adb start-server
```

## See what it's doing

```bash
# Is it running?
adb shell 'busybox ps | busybox grep -E "run.sh|sms37.sh" | busybox grep -v grep'

# The log
adb shell 'busybox tail -n 30 /data/local/sms37/log'

# Last forwarded ids and Telegram offset
adb shell cat /data/local/sms37/state
```

A healthy log looks like this. The 1970 line is normal, as the clock isn't set until the network connects:

```text
1970-01-01 09:00:14 bridge started
curl: (6) Couldn't resolve host 'api.telegram.org'
2026-11-03 16:09:50 forwarded call 1
2026-11-03 16:10:15 send to 01000000000: ✅ Sent
2026-11-03 16:10:20 forwarded sms 16
```

Bridge log lines include phone numbers. Remove them before sharing a log.

## Update the code

Edit the files in `dongle/`, then copy them over and restart:

```bash
dongle/install.sh
```

Settings near the top of `dongle/sms37.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `POLL` | `25` | Seconds for each Telegram long poll. Telegram allows up to 50 |
| `CONFIRM` | `120` | Seconds to answer `/yes` |
| `TZ` | `KST-9` | Time zone for message times, in POSIX form. Example: `UTC0` |

## Replace the bot token

If the token leaks, or you want a new bot:

1. In @BotFather, send `/revoke` and pick your bot. Copy the new token.
2. With the dongle plugged in, run:

   ```bash
   bash pc/setup.sh
   dongle/install.sh
   ```

## Data use

Each idle round is one HTTPS request, and the old `curl` opens a new TLS connection for each. That's about 3,500 connections a day with the default `POLL=25`. At an estimated 5 to 10 KB per connection, that comes to **roughly 17 to 35 MB a day**, or about 0.5 to 1 GB a month. This is an estimate, not a measurement.

On a small data plan, set `POLL=50` to cut it in half. Commands still get an immediate answer, since long polling returns as soon as there's a message. New texts and calls would then wait up to 50 seconds, because forwarding runs between polls.

## Stop or uninstall

Stop the bridge until the next reboot:

```bash
adb shell 'for p in $(busybox pgrep -f "sms37/(run|sms37)[.]sh"); do kill $p; done'
```

Remove it completely:

```bash
adb shell 'for p in $(busybox pgrep -f "sms37/(run|sms37)[.]sh"); do kill $p; done'
adb shell 'mount -o remount,rw /system; rm /system/etc/install-recovery.sh; sync; mount -o remount,ro /system'
adb shell 'rm -r /data/local/sms37'
```

This deletes the token from the dongle too. Texts stay in the dongle's own databases.

## Troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| `adb devices` is empty | ADB not on, or server not root | Check `lsusb` for `05c6:90b6`, then `sudo adb kill-server; sudo adb start-server` |
| `adb devices` says `no permissions` | Server running as your user | `adb kill-server; sudo adb start-server` |
| `lsusb` shows `05c6:f00e` | ADB is off | Repeat [setup step 3](setup.md#3-turn-on-adb-in-the-dongle) |
| Log: `Couldn't resolve host` | LTE not connected yet | Normal just after boot. If it stays, check the SIM, signal and data plan |
| Log: `SSL certificate problem` | CA bundle missing or too old | Run `dongle/install.sh` to copy a fresh one |
| Log: `Unknown SSL protocol error` or `errno 110` | Weak or dropping network | It retries by itself. Move the stick if it keeps happening |
| Log: `getUpdates failed` with `409` | Another program is reading the same bot | Stop the other program, such as the PC service. Only one may run |
| Bot ignores some commands but forwarding works | Another program is taking the commands | Same as above: look for an old script using this token |
| `❌ Could not queue the SMS`, or log shows `TransactionTooLargeException` | `content` ran in the wrong SELinux domain | See [SELinux](how-it-works.md#selinux-why-runcon-is-needed). Check that `as_shell` is in use |
| `⏳ Still sending after 45s` | Weak signal or a slow network | Look for the result with this query:<br>`select _id,type from sms order by _id desc limit 3` |
| `❌ Failed to send` | The carrier refused it | Check the number, the SIM's balance and whether it may send SMS |
| Same text forwarded twice | The carrier delivered it twice | Two separate rows in `sms` confirm this. It isn't caused by the bridge |
| `content://sms/inbox` is empty but texts arrive | Long texts are stored as MMS | Query `pdu` and `part`. See [device.md](device.md#long-texts-tables-pdu-part-addr) |
| Message dates are negative in `content query` | Display overflow in that command | The stored value is right. Read it with `sqlite3` |
| Calls never appear | The carrier may not ring calls to this stick | Check the `calls` table after a test call. Voice support differs by carrier and firmware |
| Dongle dies on a power bank | Low-current auto-off | Use an "always on" mode or a different bank |
| `runcon u:r:init:s0 content ...` hangs under `adb shell` | `app_process` lands in the `zygote` domain, which may not use the terminal or signal its parent | Expected. Wrap it with `timeout`, or use the `shell` domain as `as_shell` does |

## Test a change the way it really runs

Use the [init-context test](how-it-works.md#selinux-why-runcon-is-needed), not plain `adb shell`, and use a text to the SIM's own number so nobody else receives anything.

Next: [setup](setup.md) · [how it works](how-it-works.md) · [the device](device.md)
