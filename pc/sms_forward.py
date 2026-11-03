#!/usr/bin/env python3
"""Forward texts received by the UZ801 LTE dongle to Telegram.

The dongle runs Android 4.4 and stores texts in mmssms.db:
short SMS in table `sms`, long ones (KT sends them as LMS/MMS) in `pdu` + `part`.
Each round pulls a copy of the database over ADB and sends every inbox message
newer than the last forwarded one.

Usage:
  sms_forward.py run            poll forever and answer bot commands (what the systemd service runs)
  sms_forward.py once           one round, then exit
  sms_forward.py link           find your chat id after you message the bot
  sms_forward.py test           send a test message
  sms_forward.py list [N]       print the last N stored messages (no sending)
"""
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

CONFIG = Path.home() / ".config/sms-forward/telegram.env"
STATE = Path.home() / ".local/state/sms-forward/state.json"
DB_DIR = "/data/data/com.android.providers.telephony/databases"
POLL_SECONDS = int(os.environ.get("SMS_FORWARD_POLL", "30"))
TG_LIMIT = 4000  # Telegram allows 4096 chars per message


def log(*args):
    print(datetime.now().strftime("%Y-%m-%d %H:%M:%S"), *args, flush=True)


def load_config():
    cfg = {}
    if CONFIG.exists():
        for line in CONFIG.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                cfg[key.strip()] = value.strip().strip('"').strip("'")
    return cfg


def save_config(cfg):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text("".join(f"{k}={v}\n" for k, v in cfg.items()))
    CONFIG.chmod(0o600)


def telegram(method, token, **params):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode()
    # getUpdates long-polls for up to POLL_SECONDS, so allow more than that.
    with urllib.request.urlopen(url, data=data, timeout=POLL_SECONDS + 20) as resp:
        body = json.load(resp)
    if not body.get("ok"):
        raise RuntimeError(f"Telegram {method} failed: {body}")
    return body["result"]


def send(cfg, text):
    if len(text) > TG_LIMIT:
        text = text[:TG_LIMIT] + "\n…(cut)"
    telegram("sendMessage", cfg["TELEGRAM_BOT_TOKEN"],
             chat_id=cfg["TELEGRAM_CHAT_ID"], text=text,
             disable_web_page_preview="true")


def pull_db():
    """Copy mmssms.db (and its journal) from the dongle; return an open connection."""
    tmp = Path(tempfile.mkdtemp(prefix="sms-forward-"))
    try:
        for name in ("mmssms.db", "mmssms.db-journal"):
            subprocess.run(["adb", "pull", f"{DB_DIR}/{name}", str(tmp / name)],
                           check=(name == "mmssms.db"), capture_output=True, timeout=60)
        # Read into memory so the temp copy can be removed at once.
        disk = sqlite3.connect(tmp / "mmssms.db")
        mem = sqlite3.connect(":memory:")
        disk.backup(mem)
        disk.close()
        return mem
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def fix_subject(sub):
    # The MMS subject is stored as UTF-8 bytes read as Latin-1.
    if not sub:
        return ""
    try:
        return sub.encode("latin1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return sub


def fetch(db, last_sms, last_pdu):
    """Inbox messages newer than the given ids, oldest first."""
    out = []
    for _id, addr, date, body in db.execute(
            "select _id, address, date, body from sms where type = 1 and _id > ? order by _id",
            (last_sms,)):
        out.append({"kind": "sms", "id": _id, "from": addr,
                    "time": datetime.fromtimestamp(date / 1000), "text": body or ""})
    for _id, date, sub in db.execute(
            "select _id, date, sub from pdu where msg_box = 1 and m_type = 132 and _id > ? order by _id",
            (last_pdu,)):
        senders = [a for (a,) in db.execute(
            "select address from addr where msg_id = ? and type = 137", (_id,))]
        texts = [t for (t,) in db.execute(
            "select text from part where mid = ? and ct = 'text/plain' order by seq", (_id,)) if t]
        other = [ct for (ct,) in db.execute(
            "select ct from part where mid = ? and ct not in ('text/plain', 'application/smil')", (_id,))]
        text = "\n".join(texts) or fix_subject(sub)
        if other:
            text += f"\n[attachments not forwarded: {', '.join(other)}]"
        out.append({"kind": "mms", "id": _id, "from": ", ".join(senders) or "?",
                    "time": datetime.fromtimestamp(date), "text": text})
    out.sort(key=lambda m: m["time"])
    return out


def max_ids(db):
    sms = db.execute("select coalesce(max(_id), 0) from sms").fetchone()[0]
    pdu = db.execute("select coalesce(max(_id), 0) from pdu").fetchone()[0]
    return sms, pdu


def load_state(db):
    if STATE.exists():
        state = json.loads(STATE.read_text())
    else:
        # First start: everything already stored counts as seen.
        sms, pdu = max_ids(db)
        state = {"last_sms": sms, "last_pdu": pdu}
        save_state(state)
        log(f"first start, skipping stored messages (sms<={sms}, pdu<={pdu})")
    # Ids only grow; if they went down the dongle's database was reset.
    sms, pdu = max_ids(db)
    if sms < state["last_sms"] or pdu < state["last_pdu"]:
        log("dongle database looks reset, starting from its current contents")
        state = {"last_sms": min(state["last_sms"], sms), "last_pdu": min(state["last_pdu"], pdu)}
        save_state(state)
    return state


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE)


def format_message(m):
    return f"📩 {m['from']}  ·  {m['time']:%Y-%m-%d %H:%M}\n\n{m['text']}"


def one_round(cfg):
    db = pull_db()
    state = load_state(db)
    for m in fetch(db, state["last_sms"], state["last_pdu"]):
        send(cfg, format_message(m))
        state["last_sms" if m["kind"] == "sms" else "last_pdu"] = m["id"]
        save_state(state)
        log(f"forwarded {m['kind']} {m['id']} from {m['from']}")


def need_config():
    cfg = load_config()
    if not cfg.get("TELEGRAM_BOT_TOKEN") or not cfg.get("TELEGRAM_CHAT_ID"):
        sys.exit(f"Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in {CONFIG} (run setup.sh)")
    return cfg


HELP = ("I forward every text the dongle receives.\n"
        "/check – show the last 5 texts (/check 10 for more)\n"
        "/send <number> <text> – send an SMS from the dongle (asks /yes first)\n"
        "/help – this message")
CONFIRM_SECONDS = 120
SENT_TYPES = {2: "✅ Sent", 5: "❌ Failed to send"}  # sms.type: 4 outbox, 6 queued


def adb_shell(command):
    out = subprocess.run(["adb", "shell", command], capture_output=True, text=True, timeout=60)
    if out.returncode != 0 or "Error" in out.stdout:
        raise RuntimeError(f"adb shell failed: {out.stdout.strip()} {out.stderr.strip()}")
    return out.stdout


def send_sms(number, text):
    """Queue an SMS in the dongle's Messaging app and wait for the result."""
    before = max_ids(pull_db())[0]
    adb_shell("content insert --uri content://sms/queued"
              f" --bind address:s:{shlex.quote(number)} --bind body:s:{shlex.quote(text)}"
              f" --bind read:i:1 --bind seen:i:1 --bind date:l:{int(time.time() * 1000)}")
    adb_shell("am broadcast -a com.android.mms.transaction.SEND_MESSAGE"
              " -n com.android.mms/.transaction.SmsReceiver")
    for _ in range(15):
        time.sleep(3)
        rows = pull_db().execute(
            "select type from sms where _id > ? and type != 1 order by _id", (before,)).fetchall()
        if rows and all(t in SENT_TYPES for (t,) in rows):
            return " / ".join(SENT_TYPES[t] for (t,) in rows)
    return "⏳ Still sending after 45s; check again with /check later."


def parse_send(text):
    """'/send 010-1234-5678 hello' -> (number, body) or an error string."""
    parts = text.split(None, 2)
    if len(parts) < 3:
        return "Use: /send <number> <text>"
    number = re.sub(r"[\s\-()]", "", parts[1])
    if not re.fullmatch(r"\+?\d{3,15}", number):
        return f"Not a phone number: {parts[1]}"
    return number, parts[2].strip()


def handle_commands(cfg, offset, started, pending):
    """Answer bot commands from the linked chat; wait up to POLL_SECONDS for them."""
    updates = telegram("getUpdates", cfg["TELEGRAM_BOT_TOKEN"], offset=offset,
                       timeout=POLL_SECONDS, allowed_updates='["message"]')
    for u in updates:
        offset = u["update_id"] + 1
        msg = u.get("message") or {}
        # Only the owner's chat; ignore commands sent before this start.
        if str(msg.get("chat", {}).get("id")) != cfg["TELEGRAM_CHAT_ID"] or msg.get("date", 0) < started:
            continue
        words = (msg.get("text") or "").split()
        cmd = words[0].split("@")[0].lower() if words else ""
        if cmd == "/check":
            n = int(words[1]) if len(words) > 1 and words[1].isdigit() else 5
            texts = fetch(pull_db(), 0, 0)[-min(n, 20):]
            if not texts:
                send(cfg, "No texts stored on the dongle.")
            for m in texts:
                send(cfg, format_message(m))
            log(f"answered /check {n}")
        elif cmd in ("/start", "/help"):
            send(cfg, HELP)
        elif cmd == "/send":
            parsed = parse_send(msg.get("text", ""))
            if isinstance(parsed, str):
                send(cfg, parsed)
                continue
            pending.clear()
            pending.update(number=parsed[0], text=parsed[1], expires=time.time() + CONFIRM_SECONDS)
            send(cfg, f"Send SMS to {parsed[0]} ({len(parsed[1])} chars):\n\n{parsed[1]}\n\n"
                      f"Reply /yes within {CONFIRM_SECONDS // 60} minutes to send, /no to cancel.")
        elif cmd == "/yes":
            if not pending or time.time() > pending["expires"]:
                pending.clear()
                send(cfg, "Nothing waiting to be sent. Use /send <number> <text>.")
                continue
            number, body = pending["number"], pending["text"]
            pending.clear()
            send(cfg, f"Sending to {number}…")
            result = send_sms(number, body)
            send(cfg, f"{result}: {number}")
            log(f"sent sms to {number}: {result}")
        elif cmd == "/no":
            send(cfg, "Cancelled." if pending else "Nothing to cancel.")
            pending.clear()
    return offset


def cmd_run():
    cfg = need_config()
    log(f"forwarding texts every {POLL_SECONDS}s")
    started = int(time.time())
    offset = None
    pending = {}  # the /send waiting for /yes
    failing = False
    while True:
        try:
            one_round(cfg)
            offset = handle_commands(cfg, offset, started, pending)
            if failing:
                log("working again")
            failing = False
        except Exception as e:  # keep running through dongle unplugs and network drops
            if not failing:
                log(f"round failed: {e}")
            failing = True
            time.sleep(POLL_SECONDS)


def cmd_link():
    cfg = load_config()
    token = cfg.get("TELEGRAM_BOT_TOKEN")
    if not token:
        sys.exit(f"No TELEGRAM_BOT_TOKEN in {CONFIG}")
    me = telegram("getMe", token)
    updates = telegram("getUpdates", token)
    chats = {}
    for u in updates:
        msg = u.get("message") or u.get("edited_message")
        if msg and msg["chat"]["type"] == "private":
            chats[msg["chat"]["id"]] = msg["chat"].get("first_name", "")
    if not chats:
        sys.exit(f"No messages yet. Open t.me/{me['username']}, press Start, then run link again.")
    if len(chats) > 1:
        sys.exit(f"Several people messaged the bot: {chats}. Put the right id in {CONFIG} as TELEGRAM_CHAT_ID.")
    chat_id, name = next(iter(chats.items()))
    cfg["TELEGRAM_CHAT_ID"] = str(chat_id)
    save_config(cfg)
    print(f"Linked bot @{me['username']} to chat {chat_id} ({name}).")


def cmd_list(n):
    db = pull_db()
    for m in fetch(db, 0, 0)[-n:]:
        print(f"--- {m['kind']} {m['id']}  {m['from']}  {m['time']:%Y-%m-%d %H:%M:%S}\n{m['text']}\n")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        cmd_run()
    elif cmd == "once":
        one_round(need_config())
    elif cmd == "link":
        cmd_link()
    elif cmd == "test":
        send(need_config(), "✅ SMS forwarder on this PC is connected.")
        print("sent")
    elif cmd == "list":
        cmd_list(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
