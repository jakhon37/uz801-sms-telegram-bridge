#!/system/bin/sh
# SMS <-> Telegram bridge that runs on the UZ801 dongle itself (busybox ash).
# Forwards every received SMS/MMS to the owner's Telegram chat and answers
# /check, /send <number> <text> (+ /yes or /no), /help from that chat only.
#
#   sms37.sh            run the bridge (run.sh keeps it alive)
#   sms37.sh cmd FILE   handle FILE as if its text came from the owner's chat

D=/data/local/sms37
. $D/config                               # TOKEN=..., CHAT=...
DB=/data/data/com.android.providers.telephony/databases/mmssms.db
CA=$D/cacert.pem
T=$D/tmp
POLL=25                                   # Telegram long-poll seconds
CONFIRM=120                               # seconds to answer /yes
export TZ=KST-9
mkdir -p $T

HELP="I forward every text this dongle receives.
/check - show the last 5 texts (/check 10 for more)
/send <number> <text> - send an SMS (asks /yes first)
/help - this message"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
q() { sqlite3 -cmd ".timeout 5000" "$DB" "$1" </dev/null; }

save_state() {
    printf 'LAST_SMS=%s\nLAST_PDU=%s\nOFFSET=%s\n' "$LAST_SMS" "$LAST_PDU" "$OFFSET" > $D/state.tmp
    mv $D/state.tmp $D/state
}

# Telegram API call: tg METHOD [curl args...]; prints the JSON reply.
# The URL (with the token) goes through a config file so it never shows in `ps`.
tg() {
    m=$1; shift
    (umask 077; printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TOKEN" "$m" > $T/curl.cfg)
    curl -sS -m $((POLL + 20)) --cacert $CA -K $T/curl.cfg "$@" </dev/null
}

# Cut a file to 3900 bytes without splitting a UTF-8 character.
fit() {
    [ $(wc -c < "$1") -le 3900 ] && return
    head -c 3900 "$1" | awk 'BEGIN { RS = "\001"; for (i = 1; i < 256; i++) O[sprintf("%c", i)] = i }
        { s = $0; n = length(s)
          for (k = n; k > 0 && k > n - 4; k--) { b = O[substr(s, k, 1)]; if (b < 128 || b >= 192) break }
          if (k > 0) { b = O[substr(s, k, 1)]; need = b < 128 ? 1 : b < 224 ? 2 : b < 240 ? 3 : 4
                       if (n - k + 1 < need) s = substr(s, 1, k - 1) }
          printf "%s\n…(cut)", s }' > $T/fit
    mv $T/fit "$1"
}

# Send a file's text to the owner. 0 = sent, 1 = network problem, 2 = Telegram refused it.
send_file() {
    fit "$1"
    r=$(tg sendMessage -d "chat_id=$CHAT" -d disable_web_page_preview=true --data-urlencode "text@$1") || return 1
    case $r in *'"ok":true'*) return 0 ;; esac
    log "telegram refused message: $r"
    return 2
}

say() { printf '%s' "$1" > $T/say; send_file $T/say; }

when() { date -d "@$1" '+%Y-%m-%d %H:%M'; }

fmt_sms() {
    printf '📩 %s  ·  %s\n\n' "$(q "select address from sms where _id=$1")" "$(when $(q "select date/1000 from sms where _id=$1"))"
    q "select body from sms where _id=$1"
}

fmt_mms() {
    from=$(q "select group_concat(address, ', ') from addr where msg_id=$1 and type=137")
    printf '📩 %s  ·  %s\n\n' "${from:-?}" "$(when $(q "select date from pdu where _id=$1"))"
    for pid in $(q "select _id from part where mid=$1 and ct='text/plain' order by seq"); do
        q "select text from part where _id=$pid"
    done
    other=$(q "select group_concat(ct, ', ') from part where mid=$1 and ct not in ('text/plain', 'application/smil')")
    [ -n "$other" ] && printf '\n[attachments not forwarded: %s]' "$other"
}

# Forward texts newer than the last forwarded ones. Returns 1 on network trouble.
forward_new() {
    for id in $(q "select _id from sms where type=1 and _id>$LAST_SMS order by _id"); do
        fmt_sms $id > $T/msg
        send_file $T/msg; [ $? = 1 ] && return 1
        LAST_SMS=$id; save_state; log "forwarded sms $id"
    done
    for id in $(q "select _id from pdu where msg_box=1 and m_type=132 and _id>$LAST_PDU order by _id"); do
        fmt_mms $id > $T/msg
        send_file $T/msg; [ $? = 1 ] && return 1
        LAST_PDU=$id; save_state; log "forwarded mms $id"
    done
}

check() {
    rows=$(q "select kind || ':' || id from (
                select 's' kind, _id id, date/1000 t from sms where type=1
                union all select 'm', _id, date from pdu where msg_box=1 and m_type=132
                order by t desc limit $1) order by t")
    [ -z "$rows" ] && { say "No texts stored on the dongle."; return; }
    for r in $rows; do
        case $r in s:*) fmt_sms ${r#s:} ;; m:*) fmt_mms ${r#m:} ;; esac > $T/msg
        send_file $T/msg
    done
}

# /send <number> <text>: keep it pending until /yes.
prepare_send() {
    awk -v dir=$T 'BEGIN { RS = "\001" }
        { s = $0
          sub(/^[ \t\n]*[^ \t\n]+[ \t\n]*/, "", s)          # the /send word
          num = s; sub(/[ \t\n].*$/, "", num)
          sub(/^[^ \t\n]*[ \t\n]*/, "", s)                  # the number
          sub(/[ \t\n]+$/, "", s)
          printf "%s", num > (dir "/pend.num"); printf "%s", s > (dir "/pend.body") }' $1
    num=$(tr -d '()-' < $T/pend.num)
    if ! echo "$num" | grep -Eq '^\+?[0-9]{3,15}$' || [ ! -s $T/pend.body ]; then
        rm -f $T/pend.*
        say "Use: /send <number> <text>  (number without spaces)"
        return
    fi
    echo "$num" > $T/pend.num
    echo $(( $(date +%s) + CONFIRM )) > $T/pend.exp
    { printf 'Send SMS to %s:\n\n' "$num"; cat $T/pend.body
      printf '\n\nReply /yes within %s minutes to send, /no to cancel.' $((CONFIRM / 60)); } > $T/msg
    send_file $T/msg
}

do_send() {
    if [ ! -f $T/pend.exp ] || [ $(date +%s) -gt $(cat $T/pend.exp) ]; then
        rm -f $T/pend.*
        say "Nothing waiting to be sent. Use /send <number> <text>."
        return
    fi
    num=$(cat $T/pend.num); body=$(cat $T/pend.body)
    rm -f $T/pend.*
    say "Sending to $num…"
    before=$(q "select coalesce(max(_id), 0) from sms")
    content insert --uri content://sms/queued --bind "address:s:$num" --bind "body:s:$body" \
        --bind read:i:1 --bind seen:i:1 --bind "date:l:$(date +%s)000" </dev/null
    am broadcast -a com.android.mms.transaction.SEND_MESSAGE \
        -n com.android.mms/.transaction.SmsReceiver </dev/null >/dev/null
    result="⏳ Still sending after 45s; check again later with /check."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 3
        types=$(q "select group_concat(type) from sms where _id>$before and type!=1")
        case ",$types," in
            *,4,*|*,6,*|,,) ;;                            # outbox / queued / not there yet
            *,5,*) result="❌ Failed to send"; break ;;
            *) result="✅ Sent"; break ;;
        esac
    done
    say "$result: $num"
    log "send to $num: $result"
}

handle_cmd() {
    cmd=$(awk 'NR == 1 { print tolower($1); exit }' $1 | sed 's/@.*//')
    case $cmd in
        /start|/help) say "$HELP" ;;
        /check)
            n=$(awk 'NR == 1 { print $2; exit }' $1)
            case $n in ''|*[!0-9]*) n=5 ;; esac
            [ $n -gt 20 ] && n=20
            check $n ;;
        /send) prepare_send $1 ;;
        /yes) do_send ;;
        /no) if [ -f $T/pend.exp ]; then rm -f $T/pend.*; say "Cancelled."; else say "Nothing to cancel."; fi ;;
    esac
}

poll_updates() {
    r=$(tg getUpdates -d offset=$OFFSET -d timeout=$POLL -d 'allowed_updates=["message"]') || return 1
    rm -f $T/u*.txt
    echo "$r" | awk -v DIR=$T -f $D/json.awk > $T/updates
    if ! grep -q '^ok true' $T/updates; then
        log "getUpdates failed: $(echo "$r" | head -c 300)"
        return 1
    fi
    i=0
    grep -v '^ok ' $T/updates > $T/updates.list
    exec 3< $T/updates.list
    while read -r uid chat <&3; do
        OFFSET=$((uid + 1)); save_state           # never handle a command twice
        [ "$chat" = "$CHAT" ] && handle_cmd $T/u$i.txt
        i=$((i + 1))
    done
    exec 3<&-
}

[ -n "$SMS37_LIB" ] && return 0              # sourced for testing

if [ "$1" = cmd ]; then
    handle_cmd "$2"
    exit
fi

# First start: what is already stored counts as seen, old commands are skipped.
if [ -f $D/state ]; then
    . $D/state
else
    LAST_SMS=$(q "select coalesce(max(_id), 0) from sms")
    LAST_PDU=$(q "select coalesce(max(_id), 0) from pdu")
    OFFSET=$(tg getUpdates -d offset=-1 | awk -v DIR=$T -f $D/json.awk | awk 'NR == 2 { print $1 + 1 }')
    OFFSET=${OFFSET:-0}
    save_state
    log "first start: sms<=$LAST_SMS pdu<=$LAST_PDU offset=$OFFSET"
fi
rm -f $T/pend.*
log "bridge started"

while true; do
    [ $(wc -c < $D/log) -gt 200000 ] && { tail -n 300 $D/log > $T/log; cat $T/log > $D/log; }
    forward_new && poll_updates || sleep 15
done
