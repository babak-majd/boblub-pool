#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Thing To Link
#   Publish a file, directory, or URL and hand back a download
#   link. Three backends, and only the ones this box actually has
#   are offered — in this order of preference (the first available
#   one is the default):
#     • web root    — classic copy into /var/www/html (served by
#                     the running web server; stays until removed)
#     • python link — a throwaway python server on a random free port
#     • php link    — a throwaway `php -S`, same behaviour
#   A temporary (php/python) link serves EXACTLY one file behind a
#   random token path, opens its port in the firewall for the life
#   of the run, and tears everything down when your SSH session
#   ends, on Ctrl+C, or when the timeout (max 12h) expires.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.3.0
# ════════════════════════════════════════════════════════════
VERSION="1.3.0"
set +H

WEBROOT="/var/www/html"
PORT_LOW=20000          # random serving port is picked in [PORT_LOW, PORT_HIGH]
PORT_HIGH=60000
DRAIN_GRACE=300         # on timeout, let in-progress downloads finish up to this (s)
MAX_TIMEOUT=43200       # 12h hard cap on --timeout

# ---------- Output helpers ----------
info(){  echo -e "\033[33m$*\033[0m"; }
ok(){    echo -e "\033[32m$*\033[0m"; }
warn(){  echo -e "\033[1;33m$*\033[0m"; }
err(){   echo -e "\033[31m✘ $*\033[0m" >&2; }
link(){  echo -e "\033[1;36m$*\033[0m"; }

# ---------- Usage + argument parsing ----------
usage() {
    cat <<EOF
Usage: thing-to-link.sh [options] [input]

Publish a file, directory, or URL and get a download link. Only the backends
this server actually has are offered; anything you omit is asked for.
The default backend is the first one available, in this order:
web root  →  python link  →  php link   (Enter at the menu picks it).

Options:
  -i, --input <path|url>  File, directory, or URL to publish. A bare positional
                          value works too.
      --default           Use the default backend (first available of web root
                          → python → php) without showing the menu.
      --web               Use the classic web-root copy into /var/www/html.
      --python            Temporary link served by python  (= --serve python).
      --php               Temporary link served by php     (= --serve php).
      --serve <php|python>  Temporary-link backend: a throwaway server on a
                          random port, one file behind a random token, firewall
                          port opened for the run and closed on teardown.
  -w, --webroot <dir>     Use the classic web-root copy instead, into <dir>
                          (default: /var/www/html). Stays until you remove it.
  -c, --compress <type>   Compression for a directory input: tar.gz or zip
                          (skips the interactive prompt).
  -t, --timeout <dur>     Temporary link: keep it alive at most this long, e.g.
                          30m, 2h, 90 (bare = minutes). Max 12h. The link also
                          dies when your SSH session ends or on Ctrl+C. Asked
                          for when omitted.
  -h, --help              Show this help and exit.

Notes:
  * A temporary link lives only while THIS process does. If you run it inside
    tmux/screen it survives an SSH disconnect — the timeout still closes it.
  * On timeout, new connections are blocked first and in-progress downloads are
    given up to ${DRAIN_GRACE}s to finish; an SSH disconnect tears down at once.

Examples:
  thing-to-link.sh
  thing-to-link.sh -i /root/backup.tar.gz --default -t 2h
  thing-to-link.sh -i /root/backup.tar.gz --serve php -t 2h
  thing-to-link.sh -i https://example.com/file.zip --serve python
  thing-to-link.sh -i /home/user/backups -c zip --webroot /var/www/html
EOF
}

input=""
COMPRESS=""
MODE=""                 # webroot | php | python | default — resolved from flags or the menu
TIMEOUT_RAW=""

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input)    [ -n "${2:-}" ] || { err "$1 requires a value."; exit 1; }; input="$2"; shift 2 ;;
        --serve)       [ -n "${2:-}" ] || { err "$1 requires a value."; exit 1; }
                       case "$2" in php) MODE="php" ;; python) MODE="python" ;; *) err "--serve must be php or python."; exit 1 ;; esac
                       shift 2 ;;
        -w|--webroot)  [ -n "${2:-}" ] || { err "$1 requires a value."; exit 1; }; WEBROOT="$2"; MODE="webroot"; shift 2 ;;
        --web)         MODE="webroot"; shift ;;
        --python)      MODE="python";  shift ;;
        --php)         MODE="php";     shift ;;
        --default)     MODE="default"; shift ;;
        -c|--compress) [ -n "${2:-}" ] || { err "$1 requires a value."; exit 1; }; COMPRESS="$2"; shift 2 ;;
        -t|--timeout)  [ -n "${2:-}" ] || { err "$1 requires a value."; exit 1; }; TIMEOUT_RAW="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            err "Unknown option: $1"; usage; exit 1 ;;
        *)             input="$1"; shift ;;   # bare positional input
    esac
done

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Thing To Link${N}"
    echo -e "  Publish a file or URL and hand back a download link."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}
print_header

# ════════════════════════════════════════════════════════════
#   BACKEND DETECTION — only offer what this box has
# ════════════════════════════════════════════════════════════
# Locate a usable PHP CLI: PATH, the common fixed path, then cPanel EA-PHP.
find_php() {
    local p
    for p in php /usr/local/bin/php; do
        if command -v "$p" >/dev/null 2>&1 && "$p" -v >/dev/null 2>&1; then
            command -v "$p"; return 0
        fi
    done
    for p in /opt/cpanel/ea-php*/root/usr/bin/php /usr/local/bin/ea-php*; do
        [ -x "$p" ] && "$p" -v >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# True when a web server is present (running or installed) or the web root exists.
detect_webserver() {
    local s
    for s in httpd apache2 nginx litespeed lshttpd; do
        pgrep -x "$s"            >/dev/null 2>&1 && return 0
        command -v "$s"          >/dev/null 2>&1 && return 0
    done
    [ -d "$WEBROOT" ] && return 0
    return 1
}

WEB_OK=""; PHP_BIN=""; PY_BIN=""
detect_webserver && WEB_OK=1
PHP_BIN=$(find_php) || PHP_BIN=""
command -v python3 >/dev/null 2>&1 && PY_BIN=$(command -v python3)

# ---------- Default backend: first available of web root → python → php ----------
DEFAULT_MODE=""
if   [ -n "$WEB_OK" ];  then DEFAULT_MODE="webroot"
elif [ -n "$PY_BIN" ];  then DEFAULT_MODE="python"
elif [ -n "$PHP_BIN" ]; then DEFAULT_MODE="php"
fi

# ---------- Mode menu (dynamic: active options only) ----------
# A --serve/--webroot/--web/--python/--php flag settles the mode and --default
# takes the default without asking; otherwise list exactly the backends that
# exist (in preference order, default marked) and let the operator pick — Enter
# picks the default. If none exist, there is nothing to do.
if [ -z "$MODE" ] || [ "$MODE" = "default" ]; then
    if [ -z "$DEFAULT_MODE" ]; then
        err "No web server, PHP, or Python found — nothing to serve a file with."
        info "Install one of: a web server (for the web-root copy), php-cli, or python3."
        exit 1
    fi
fi
if [ "$MODE" = "default" ]; then
    MODE="$DEFAULT_MODE"
elif [ -z "$MODE" ]; then
    info "How do you want to publish?"
    declare -A MENU=()
    n=0; def_n=""
    if [ -n "$WEB_OK" ];  then n=$((n+1)); MENU[$n]="webroot"; echo "  $n) web root     — copy into $WEBROOT (served by the running web server)$([ "$DEFAULT_MODE" = webroot ] && echo '  [default]')"; [ "$DEFAULT_MODE" = webroot ] && def_n=$n; fi
    if [ -n "$PY_BIN" ];  then n=$((n+1)); MENU[$n]="python";  echo "  $n) python link  — temporary python server on a random port, dies with your SSH session$([ "$DEFAULT_MODE" = python ] && echo '  [default]')"; [ "$DEFAULT_MODE" = python ] && def_n=$n; fi
    if [ -n "$PHP_BIN" ]; then n=$((n+1)); MENU[$n]="php";     echo "  $n) php link     — temporary php -S, same behaviour$([ "$DEFAULT_MODE" = php ] && echo '  [default]')"; [ "$DEFAULT_MODE" = php ] && def_n=$n; fi
    read -r -p "Enter choice (1-$n) [$def_n]: " CHOICE
    [ -n "$CHOICE" ] || CHOICE="$def_n"
    MODE="${MENU[$CHOICE]:-}"
    [ -n "$MODE" ] || { err "Invalid choice."; exit 1; }
fi

# A forced backend must actually be available.
case "$MODE" in
    php)    [ -n "$PHP_BIN" ] || { err "PHP CLI not found — cannot use --php / --serve php."; exit 1; } ;;
    python) [ -n "$PY_BIN" ]  || { err "python3 not found — cannot use --python / --serve python."; exit 1; } ;;
esac
info "Method: $MODE"

# ---------- Resolve the input ----------
if [ -z "$input" ]; then
    read -r -p $'\033[36mEnter file path, directory, or URL:\033[0m ' input
fi
[ -n "$input" ] || { err "No input given."; exit 1; }

# ════════════════════════════════════════════════════════════
#   WEB ROOT MODE (classic copy — unchanged behaviour)
# ════════════════════════════════════════════════════════════
publish_webroot() {
    mkdir -p "$WEBROOT" 2>/dev/null
    local hn ip; hn=$(hostname); ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    if [[ "$input" =~ ^https?:// ]]; then
        local filename; filename=$(basename "$input")
        rm -f "$WEBROOT/$filename"
        if wget "$input" -O "$WEBROOT/$filename"; then
            chown root:root "$WEBROOT/$filename"; chmod +r "$WEBROOT/$filename"
            ok "Download completed."
        else
            rm -f "$WEBROOT/$filename"; err "Download failed, file removed."; return 1
        fi
        info "Download links:"; link "https://$hn/$filename"; link "http://$ip/$filename"

    elif [ -f "$input" ]; then
        local filename; filename=$(basename "$input")
        cp "$input" "$WEBROOT/"
        chmod +r "$WEBROOT/$filename"; chown root:root "$WEBROOT/$filename"
        ok "Success."
        info "Download links:"; link "https://$hn/$filename"; link "http://$ip/$filename"

    elif [ -d "$input" ]; then
        local dirname; dirname=$(basename "$input")
        info "Detected directory: $dirname"
        local comp_type="$COMPRESS"
        if [ -z "$comp_type" ]; then
            echo "Choose compression type:"; echo "1) tar.gz"; echo "2) zip"
            read -r -p "Enter option (1 or 2): " opt
            case "$opt" in 1) comp_type="tar.gz" ;; 2) comp_type="zip" ;; *) err "Invalid option."; return 1 ;; esac
        fi
        local outname
        if [ "$comp_type" = "tar.gz" ]; then
            outname="${dirname}.tar.gz"; tar -czf "/tmp/$outname" -C "$(dirname "$input")" "$dirname"
        elif [ "$comp_type" = "zip" ]; then
            outname="${dirname}.zip"; zip -r "/tmp/$outname" "$input" >/dev/null
        else
            err "Invalid compression type (use tar.gz or zip)."; return 1
        fi
        mv "/tmp/$outname" "$WEBROOT/"
        chown root:root "$WEBROOT/$outname"; chmod +r "$WEBROOT/$outname"
        ok "Directory compressed and uploaded."
        info "Download links:"; link "https://$hn/$outname"; link "http://$ip/$outname"
    else
        err "Not a valid URL, file path, or directory."; return 1
    fi
}

# ════════════════════════════════════════════════════════════
#   TEMPORARY LINK MODE (php / python)
# ════════════════════════════════════════════════════════════
# A random token, a random free port, one file, a firewall hole opened for the
# run, and a teardown wired to this process so the link cannot outlive it.
WORK=""; DOCROOT=""; TOKEN=""; PAYLOAD_NAME=""; PORT=""
SERVER_PID=""; WATCH_PID=""; CLEANED=""
FW_METHOD=""; FW_ADDED=""; FW_TAG=""   # FW_ADDED set only when WE opened the port
TIMEOUT_SECS=""

# Parse a duration (30m / 2h / 90 == 90m) to seconds, clamped to the 12h cap.
parse_timeout() {   # $1 = raw -> prints seconds, or nothing on a bad value
    local raw="$1" num unit secs
    case "$raw" in
        *h) num="${raw%h}"; unit=3600 ;;
        *m) num="${raw%m}"; unit=60 ;;
        *s) num="${raw%s}"; unit=1 ;;
        *)  num="$raw";     unit=60 ;;   # bare number = minutes
    esac
    [[ "$num" =~ ^[0-9]+$ ]] || return 1
    secs=$((num*unit))
    [ "$secs" -ge 1 ] || return 1
    [ "$secs" -gt "$MAX_TIMEOUT" ] && secs="$MAX_TIMEOUT"
    printf '%s' "$secs"
}

# Pick a random TCP port in range that nothing is currently listening on.
pick_free_port() {
    local tries=0 p
    while [ "$tries" -lt 50 ]; do
        p=$(( (RANDOM<<15 | RANDOM) % (PORT_HIGH-PORT_LOW+1) + PORT_LOW ))
        if command -v ss >/dev/null 2>&1; then
            ss -ltnH "sport = :$p" 2>/dev/null | grep -q . || { printf '%s' "$p"; return 0; }
        else
            ( exec 3<>"/dev/tcp/127.0.0.1/$p" ) 2>/dev/null || { printf '%s' "$p"; return 0; }
        fi
        tries=$((tries+1))
    done
    return 1
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 12
    else tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24; fi
}

# ---------- Firewall (auto-detect; open for the run, close precisely on teardown) ----------
# Safety first: we open ONLY the one random port, tag the iptables rule with a
# unique comment, remember that WE added it, and on teardown remove EXACTLY that
# rule — never a pre-existing one — then verify it is gone.
fw_open() {   # $1 = port
    local port="$1"
    FW_TAG="thing-to-link:$$:$port"
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 && { FW_METHOD="firewalld"; FW_ADDED=1; }
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 && { FW_METHOD="ufw"; FW_ADDED=1; }
    elif command -v iptables >/dev/null 2>&1; then
        # Prefer a comment-tagged rule so teardown can target only our own.
        if iptables -I INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; then
            FW_METHOD="iptables"; FW_ADDED=1
        elif iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            FW_METHOD="iptables-plain"; FW_ADDED=1   # comment module unavailable
        fi
    fi
    if [ -n "$FW_ADDED" ]; then
        ok "Firewall: opened port $port ($FW_METHOD)"
    else
        warn "No firewall tool found (or none active) — make sure port $port is reachable."
    fi
}
# Remove only what we added, retry, then verify; shout (with the manual command)
# if anything of ours survives. Idempotent and safe to call more than once.
fw_close() {  # $1 = port
    local port="${1:-}" tries=0
    [ -n "$FW_ADDED" ] && [ -n "$port" ] || return 0
    case "$FW_METHOD" in
        firewalld) firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 ;;
        ufw)       ufw delete allow "${port}/tcp" >/dev/null 2>&1 ;;
        iptables)
            while iptables -C INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null || break
                tries=$((tries+1)); [ "$tries" -ge 10 ] && break
            done ;;
        iptables-plain)
            while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
                tries=$((tries+1)); [ "$tries" -ge 10 ] && break
            done ;;
    esac
    # Verify (iptables only — the one we can re-check cheaply) and warn loudly.
    if [ "$FW_METHOD" = "iptables" ] \
       && iptables -C INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; then
        warn "Could NOT remove the firewall rule for port $port — close it by hand:"
        warn "  iptables -D INPUT -p tcp --dport $port -j ACCEPT"
    else
        FW_ADDED=""   # confirmed closed
    fi
}

# ---------- Teardown (wired to EXIT / Ctrl+C / SSH hang-up) ----------
cleanup() {
    [ -n "$CLEANED" ] && return 0
    CLEANED=1
    [ -n "$WATCH_PID" ]  && kill "$WATCH_PID"  2>/dev/null
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    fw_close "$PORT"
    [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}

# ---------- Stage the single file under DOCROOT/<token>/<name> ----------
# Only this one file ever lives in the served tree, so even a bypassed router
# could reach nothing else.
stage_payload() {
    WORK=$(mktemp -d /tmp/ttl.XXXXXX) || { err "Cannot create a temp dir."; return 1; }
    DOCROOT="$WORK/pub"
    mkdir -p "$DOCROOT/$TOKEN" || return 1

    if [[ "$input" =~ ^https?:// ]]; then
        PAYLOAD_NAME=$(basename "$input"); [ -n "$PAYLOAD_NAME" ] || PAYLOAD_NAME="download"
        info "Fetching $input ..."
        if command -v wget >/dev/null 2>&1; then
            wget -q "$input" -O "$DOCROOT/$TOKEN/$PAYLOAD_NAME" || { err "Download failed."; return 1; }
        else
            curl -fsSL "$input" -o "$DOCROOT/$TOKEN/$PAYLOAD_NAME" || { err "Download failed."; return 1; }
        fi

    elif [ -f "$input" ]; then
        PAYLOAD_NAME=$(basename "$input")
        cp "$input" "$DOCROOT/$TOKEN/$PAYLOAD_NAME" || { err "Could not stage the file."; return 1; }

    elif [ -d "$input" ]; then
        local dn comp_type; dn=$(basename "$input"); comp_type="$COMPRESS"
        info "Detected directory: $dn"
        if [ -z "$comp_type" ]; then
            echo "Choose compression type:"; echo "1) tar.gz"; echo "2) zip"
            read -r -p "Enter option (1 or 2): " opt
            case "$opt" in 1) comp_type="tar.gz" ;; 2) comp_type="zip" ;; *) err "Invalid option."; return 1 ;; esac
        fi
        if [ "$comp_type" = "tar.gz" ]; then
            PAYLOAD_NAME="${dn}.tar.gz"; tar -czf "$DOCROOT/$TOKEN/$PAYLOAD_NAME" -C "$(dirname "$input")" "$dn" || return 1
        elif [ "$comp_type" = "zip" ]; then
            PAYLOAD_NAME="${dn}.zip"; ( cd "$(dirname "$input")" && zip -r "$DOCROOT/$TOKEN/$PAYLOAD_NAME" "$dn" >/dev/null ) || return 1
        else
            err "Invalid compression type (use tar.gz or zip)."; return 1
        fi
    else
        err "Not a valid URL, file path, or directory."; return 1
    fi
    chmod +r "$DOCROOT/$TOKEN/$PAYLOAD_NAME" 2>/dev/null
}

# ---------- Server scripts (one file, token-gated, 404 for everything else) ----------
write_router_php() {
    # The built-in php -S static server ignores Range, so the router streams the
    # file itself: ONLY /<token>/<file>, with Range/resume support, 404 for the rest.
    cat > "$WORK/router.php" <<'PHPEOF'
<?php
$token = getenv('TTL_TOKEN');
$file  = getenv('TTL_FILE');
$root  = getenv('TTL_ROOT');
$path  = rawurldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
$target = $root . '/' . $token . '/' . $file;
if ($path !== "/{$token}/{$file}" || !is_file($target)) {
    http_response_code(404); header('Content-Type: text/plain'); echo "404 Not Found\n"; return true;
}
$size = filesize($target);
$start = 0; $end = $size - 1; $status = 200;
if (!empty($_SERVER['HTTP_RANGE']) && preg_match('/bytes=(\d*)-(\d*)/', $_SERVER['HTTP_RANGE'], $m)) {
    if ($m[1] === '' && $m[2] !== '') { $start = max(0, $size - (int)$m[2]); $end = $size - 1; }
    else { $start = (int)$m[1]; $end = ($m[2] !== '') ? (int)$m[2] : $size - 1; }
    if ($start > $end || $start >= $size) { http_response_code(416); header("Content-Range: bytes */{$size}"); return true; }
    $status = 206;
}
$length = $end - $start + 1;
http_response_code($status);
header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="' . $file . '"');
header('Accept-Ranges: bytes');
header('Content-Length: ' . $length);
if ($status === 206) header("Content-Range: bytes {$start}-{$end}/{$size}");
$fp = fopen($target, 'rb'); fseek($fp, $start); $remaining = $length;
while ($remaining > 0 && !feof($fp)) {
    $chunk = fread($fp, min(65536, $remaining));
    if ($chunk === false) break;
    echo $chunk; flush();
    $remaining -= strlen($chunk);
}
fclose($fp);
return true;
PHPEOF
}

write_server_py() {
    cat > "$WORK/server.py" <<'PYEOF'
import os
from urllib.parse import urlparse, unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ['TTL_TOKEN']
NAME  = os.environ['TTL_FILE']
ROOT  = os.environ['TTL_ROOT']
PORT  = int(os.environ['TTL_PORT'])
TARGET  = os.path.join(ROOT, TOKEN, NAME)
ALLOWED = '/%s/%s' % (TOKEN, NAME)

class H(BaseHTTPRequestHandler):
    def _deny(self):
        self.send_response(404); self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        try: self.wfile.write(b'404 Not Found\n')
        except Exception: pass
    def do_HEAD(self): self._serve(head=True)
    def do_GET(self):  self._serve(head=False)
    def _serve(self, head):
        path = unquote(urlparse(self.path).path)
        if path != ALLOWED or not os.path.isfile(TARGET):
            return self._deny()
        size = os.path.getsize(TARGET)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            try:
                s, e = rng[6:].split('-', 1)
                if s.strip() == '':
                    start = max(0, size - int(e)); end = size - 1
                else:
                    start = int(s); end = int(e) if e.strip() else size - 1
                if start > end or start >= size: raise ValueError
                status = 206
            except Exception:
                self.send_response(416); self.send_header('Content-Range', 'bytes */%d' % size)
                self.end_headers(); return
        length = end - start + 1
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="%s"' % NAME)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(length))
        if status == 206:
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.end_headers()
        if head: return
        with open(TARGET, 'rb') as f:
            f.seek(start); remaining = length
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): break
                remaining -= len(chunk)
    def log_message(self, *a): pass

ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
PYEOF
}

# ---------- Watchdog ----------
# Two jobs, both ending in a clean teardown: (1) the timeout, and (2) a safety
# backstop — if the main process dies WITHOUT running its trap (e.g. kill -9, a
# crash), the watchdog notices the parent is gone and closes the port anyway, so
# a firewall hole can never outlive the script. On a normal teardown the trap
# kills this watchdog first, so only abnormal deaths reach the parent-gone path.
start_watchdog() {
    local ppid=$$
    (
        local elapsed=0
        while :; do
            kill -0 "$ppid" 2>/dev/null || break          # parent gone (killed/crashed)
            [ "$elapsed" -ge "$TIMEOUT_SECS" ] && break    # timeout reached
            sleep 2; elapsed=$((elapsed+2))
        done
        fw_close "$PORT"                     # stop NEW connections first
        local waited=0
        while ss -tnH "sport = :$PORT" state established 2>/dev/null | grep -q .; do
            [ "$waited" -ge "$DRAIN_GRACE" ] && break
            sleep 3; waited=$((waited+3))
        done
        kill "$SERVER_PID" 2>/dev/null       # then stop the server
    ) &
    WATCH_PID=$!
}

publish_temp() {   # $1 = backend bin, $2 = kind (php|python)
    local bin="$1" kind="$2"
    TOKEN=$(gen_token); [ -n "$TOKEN" ] || { err "Could not generate a token."; return 1; }

    # Timeout: flag, else prompt (blank = 1h), capped at 12h.
    if [ -z "$TIMEOUT_RAW" ]; then
        read -r -p "Keep the link alive for how long? (e.g. 30m, 2h; max 12h) [1h]: " TIMEOUT_RAW
        [ -n "$TIMEOUT_RAW" ] || TIMEOUT_RAW="1h"
    fi
    TIMEOUT_SECS=$(parse_timeout "$TIMEOUT_RAW") || { err "Invalid timeout: $TIMEOUT_RAW"; return 1; }
    [ "$TIMEOUT_SECS" = "$MAX_TIMEOUT" ] && [ "$TIMEOUT_RAW" != "12h" ] && warn "Timeout clamped to the 12h maximum."

    stage_payload || return 1

    PORT=$(pick_free_port) || { err "No free port found in $PORT_LOW-$PORT_HIGH."; return 1; }

    if [ "$kind" = "php" ]; then
        write_router_php
        TTL_TOKEN="$TOKEN" TTL_FILE="$PAYLOAD_NAME" TTL_ROOT="$DOCROOT" \
            "$bin" -S "0.0.0.0:$PORT" "$WORK/router.php" >"$WORK/server.log" 2>&1 &
    else
        write_server_py
        TTL_TOKEN="$TOKEN" TTL_FILE="$PAYLOAD_NAME" TTL_ROOT="$DOCROOT" TTL_PORT="$PORT" \
            "$bin" "$WORK/server.py" >"$WORK/server.log" 2>&1 &
    fi
    SERVER_PID=$!
    sleep 1
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        err "The $kind server failed to start:"; cat "$WORK/server.log" >&2; return 1
    fi

    fw_open "$PORT"

    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo
    ok "Serving one file via $kind — live until this session ends, Ctrl+C, or the timeout."
    info "Download link:"
    link "http://$ip:$PORT/$TOKEN/$PAYLOAD_NAME"
    echo
    info "Timeout: ${TIMEOUT_SECS}s   ·   Press Ctrl+C to stop now."

    start_watchdog
    wait "$SERVER_PID"      # foreground: an SSH hang-up (SIGHUP) lands on the EXIT trap
}

# ════════════════════════════════════════════════════════════
#   DISPATCH
# ════════════════════════════════════════════════════════════
case "$MODE" in
    webroot) publish_webroot ;;
    php)     trap cleanup EXIT INT TERM HUP; publish_temp "$PHP_BIN" php ;;
    python)  trap cleanup EXIT INT TERM HUP; publish_temp "$PY_BIN"  python ;;
    *)       err "Unknown mode: $MODE"; exit 1 ;;
esac

set -H
