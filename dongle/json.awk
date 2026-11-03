# Read a Telegram getUpdates reply (JSON) and, for each update, print
#   update_id chat_id
# and write that message's text (decoded UTF-8) to DIR/u<index>.txt.
# The first output line is "ok true" or "ok false".
# busybox awk works on bytes, which is what this relies on.

BEGIN { for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i }

{ s = s $0 "\n" }

END {
    n = length(s); p = 1; N = 0
    parse_value("")
    print "ok", (OK == "true" ? "true" : "false")
    for (i = 0; i < N; i++) {
        chat = ((i, ".message.chat.id") in F) ? F[i, ".message.chat.id"] : "-"
        if ((i, ".message.text") in F)
            printf "%s", F[i, ".message.text"] > (DIR "/u" i ".txt")
        else
            printf "" > (DIR "/u" i ".txt")
        close(DIR "/u" i ".txt")
        print F[i, ".update_id"], chat
    }
}

function ws() { while (p <= n && index(" \t\r\n", substr(s, p, 1))) p++ }

function emit(path, v,    i, rest) {
    if (path == ".ok") { OK = v; return }
    if (path !~ /^\.result\[[0-9]+\]\./) return
    i = path; sub(/^\.result\[/, "", i); sub(/\].*$/, "", i)
    rest = path; sub(/^\.result\[[0-9]+\]/, "", rest)
    F[i, rest] = v
    if (i + 1 > N) N = i + 1
}

function parse_value(path,    c, st) {
    ws(); c = substr(s, p, 1)
    if (c == "{") parse_object(path)
    else if (c == "[") parse_array(path)
    else if (c == "\"") emit(path, parse_string())
    else {
        st = p
        while (p <= n && index(",}] \t\r\n", substr(s, p, 1)) == 0) p++
        emit(path, substr(s, st, p - st))
    }
}

function parse_object(path,    c, key) {
    p++; ws()
    if (substr(s, p, 1) == "}") { p++; return }
    while (p <= n) {
        ws(); key = parse_string()
        ws(); p++                      # ':'
        parse_value(path "." key)
        ws(); c = substr(s, p, 1); p++
        if (c != ",") return
    }
}

function parse_array(path,    c, i) {
    p++; ws()
    if (substr(s, p, 1) == "]") { p++; return }
    i = 0
    while (p <= n) {
        parse_value(path "[" i "]")
        ws(); c = substr(s, p, 1); p++; i++
        if (c != ",") return
    }
}

function parse_string(    out, c, cp, lo) {
    p++; out = ""
    while (p <= n) {
        c = substr(s, p, 1)
        if (c == "\"") { p++; return out }
        if (c != "\\") { out = out c; p++; continue }
        c = substr(s, p + 1, 1); p += 2
        if (c == "n") out = out "\n"
        else if (c == "t") out = out "\t"
        else if (c == "r") out = out "\r"
        else if (c == "b") out = out "\b"
        else if (c == "f") out = out "\f"
        else if (c == "u") {
            cp = hexval(substr(s, p, 4)); p += 4
            if (cp >= 55296 && cp < 56320 && substr(s, p, 2) == "\\u") {   # surrogate pair
                lo = hexval(substr(s, p + 2, 4)); p += 6
                cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
            }
            out = out utf8(cp)
        }
        else out = out c                # \" \\ \/
    }
    return out
}

function hexval(h,    i, v) {
    v = 0; h = tolower(h)
    for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
    return v
}

function utf8(cp) {
    if (cp < 1) return ""
    if (cp < 128) return sprintf("%c", cp)
    if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
    if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
    return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64,
                   128 + int(cp / 64) % 64, 128 + cp % 64)
}
