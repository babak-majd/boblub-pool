#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Magic Move
#   Two-pass migration verifier. Run on the SOURCE to snapshot
#   every account's status, then on the DESTINATION to re-check
#   and heal broken PHP sites — proving the move came across clean.
#   Before the first rsync, a PREP step stops SecCheck and the
#   scanner services, whitelists the peer IP in CSF, and (on the
#   destination) opens SSH root login — with a ready-to-paste
#   block printed for the destination, source IP already in it.
#   On a cPanel destination it can pull the accounts with cPanel's
#   own Transfer Tool (WHM API), asking every conflict one by one.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 2.7.0
# ════════════════════════════════════════════════════════════
VERSION="2.7.0"

set -u

# ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------- Logging  (standard block — identical across all bobclub scripts) ----------
# One directory per script under /var/log, a sub-directory per target (the domain
# or user; empty for whole-server scripts — this one has no key), and one
# timestamped file per run. start_log <key> begins capturing the whole run to
# that file (colors stripped) via tee; it falls back to /tmp when /var/log is not
# writable (e.g. not root). finish_log() prints the final path on any exit.
# Self-contained (literal colors, set -u safe) so the block stays byte-identical
# between scripts. The migration CSV/report/snapshots are the *result* of the run
# and stay in the output folder (see below) — they are deliberately not the log.
SCRIPT_NAME="magic-move"
LOG_FILE=""
_LOG_TEE_PID=""
start_log() {
    local key base dir
    key=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_')
    base="/var/log/${SCRIPT_NAME}"
    if ! mkdir -p "$base" 2>/dev/null || [ ! -w "$base" ]; then
        base="/tmp/${SCRIPT_NAME}"; mkdir -p "$base" 2>/dev/null
        printf '\033[1;33m⚠ /var/log not writable — logging under %s\033[0m\n' "$base" >&2
    fi
    if [ -n "$key" ]; then dir="${base}/${key}"; else dir="$base"; fi
    mkdir -p "$dir" 2>/dev/null
    LOG_FILE="${dir}/$(date +%F_%H-%M-%S).log"
    exec 3>&1                       # keep the real stdout for the closing notice
    exec > >(trap '' INT; tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1   # ignore Ctrl+C: keep logging through the script's own cancel handler
    _LOG_TEE_PID=$!
}
finish_log() {
    [ -n "$LOG_FILE" ] || return 0
    exec >&- 2>&-                   # close the redirected FDs so tee sees EOF
    [ -n "$_LOG_TEE_PID" ] && wait "$_LOG_TEE_PID" 2>/dev/null
    printf '\033[1;36m📄 Log saved to:\033[0m %s\n' "$LOG_FILE" >&3 2>/dev/null \
        || echo "Log saved to: ${LOG_FILE}"
}
trap finish_log EXIT

# info/success/error print to the terminal (captured by the global tee); log()
# appends an extra plain, machine-readable record to the log file only.
log() {
    [ -n "$LOG_FILE" ] && echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"
}
info(){ echo -e "${YELLOW}[INFO]${RESET} $*"; }
success(){ echo -e "${GREEN}[OK]${RESET} $*"; }
error(){ echo -e "${RED}[ERROR]${RESET} $*"; }

# ---------- Defaults ----------
MODE=""                       # source | destination | sync | prep — prompted when unset
PANEL=""                      # cpanel | directadmin — auto-detected / forced
SERVER_IP=""                  # this server's IP; auto-detected default, prompted
RESELLER=""                   # source: only accounts owned by this reseller
USERS=""                      # source: only these specific users (space/comma)
NS_LOOKUP=""                  # source: yes = also record each domain's ns1-ns4
                              # in the CSV. Empty means neither flag: ask.
LIST_ONLY=""                  # source: yes = extract the account list only (no
                              # requests, no snapshots); no = full health check.
                              # Empty means neither flag was given: ask.
CSV_IN=""                     # destination: the CSV produced on the source
OUT_DIR=""                    # output folder (default: magic-move-<mode>); holds
                              # migration.csv + snapshots/ together
OUT_CSV=""                    # derived: $OUT_DIR/migration.csv
SNAP_DIR=""                   # derived: $OUT_DIR/snapshots
PHP_VERSIONS="8.3 8.1 7.4"    # cascade tried, in order, on a fixable failure
TIMEOUTS="10 20 35 60"        # attempt 1 + three escalating retries on a 000
SETTLE=2                      # pause after a version switch before re-checking
DRY_RUN=""                    # destination: check & record, never switch PHP
PLUGIN_HEAL="yes"             # destination: disable plugins that throw a fatal
                              # (rename <slug> -> <slug>.dis), guided by WP_DEBUG
PROTECTED_PLUGINS="elementor woocommerce"   # never disabled; matches slug or slug-*
SYNC=""                       # source: yes = rsync the selected accounts' home
                              # dirs to the destination after the pass; no =
                              # don't. Empty means neither flag: ask.
SYNC_IP=""                    # sync: destination server IP/host — prompted
SYNC_PORT=""                  # sync: destination SSH port — prompted (default 22)
PREP=""                       # migration prep: yes = run without asking; skip =
                              # already prepared, don't run; empty = ask.
PREP_GIVEN=0                  # --prep was given (makes --prep alone a mode)
PREP_SIDE=""                  # standalone prep: source | destination (from
                              # --source / --destination; asked for when empty)
PEER_IP=""                    # prep: the OTHER server's IP to whitelist here
TRANSFER=""                   # destination: yes = pull the accounts with cPanel's
                              # Transfer Tool first; no = don't. Empty: ask (only
                              # when this destination is cPanel).
XFER_SRC_IP=""                # transfer: source IP (default: from the source report)
XFER_SRC_PORT=""              # transfer: source SSH port (default: from the report, else 22)

# ---------- Usage ----------
usage() {
    cat <<EOF
Usage: magic-move.sh [options]

A migration is verified in two passes:

  1. SOURCE       Detect every account (cPanel/DirectAdmin), health-check each
                  domain, and record it as status_before in $OUT_CSV. Snapshots
                  each page to $SNAP_DIR/before/<domain>.html. No changes made.
                  With --list-only it stops after the account list: no requests,
                  no snapshots, just user,domain in the CSV. With --ns it also
                  looks up each domain's nameservers into ns1..ns4 columns.
  2. DESTINATION  Take that CSV, re-check every domain against THIS server, and
                  heal any broken site. For a plugin fatal it turns on WP_DEBUG,
                  reads the culprit plugin from the error and disables it (renames
                  <slug> to <slug>.dis) — Elementor and WooCommerce are never
                  touched. Otherwise it steps the PHP version down. Records
                  status_after and snapshots to $SNAP_DIR/after/<domain>.html.

  SYNC            Copy the selected accounts' home directories to the
                  destination with ONE rsync (a filter keeps only those users),
                  run inside a detached screen. Offered at the end of the
                  source pass, or on its own with --sync. Users that do not
                  exist on the destination (or live under another home path
                  there) are not copied; they are listed in
                  <outdir>/sync-skipped.csv.

  PREP            Before the first rsync, both servers are prepared: SecCheck is
                  stopped & disabled (cron entries quarantined, /etc/SecCheck
                  moved away), the scanner services (clamd@scan, clamav-freshclam,
                  cxswatch, rspamd, spamd) are stopped & disabled, "ALL: ALL" is
                  commented out of hosts.deny, and the peer's IP is whitelisted
                  in CSF. The destination additionally opens SSH root login.
                  During a sync flow the source asks first; it then prints a
                  complete ready-to-paste block for the destination with the
                  source IP already in it, and waits for Enter before syncing.
                  --prep runs it standalone (no sync), --skip-prep skips it
                  entirely for servers that are already prepared.

  TRANSFER       On a cPanel destination, the destination pass offers to pull
                  the accounts with cPanel's own Transfer Tool (WHM API) before
                  verifying them — also when the source report doesn't say what
                  panel the source runs. Only the users listed in migration.csv
                  are taken (root, staff and system users are filtered out), and
                  every conflict is asked one by one: an existing account or
                  domain here (ignore / overwrite / overwrite with delete /
                  restore under another name), a reseller (same privileges /
                  without them / plain account), its owner, packages, IP,
                  Express/Live transfer and what to skip. The pull needs the
                  source prepared (root SSH open, this server whitelisted) —
                  it offers to prep this side and prints the block for the
                  source. The source report records the source panel, its
                  IP and SSH port, which become the defaults here.

Every domain is probed with all hostnames pinned to this server, so a redirect
to www/a subdomain follows onto the box we are testing, not wherever DNS points.

Options:
      --source            This is the source server (snapshot only). With --prep:
                          prep THIS server as the source, then exit.
      --destination       This is the destination server (verify + heal). With
                          --prep: prep THIS server as the destination, then exit.
  -i, --ip <ip>           Server IP to pin every domain to. Prompted for, with
                          the auto-detected IP as default, when omitted.
  -f, --file <path|url>   DESTINATION: the CSV from the source pass (path or URL).
                          SOURCE: optional "user,domain" list to use instead of
                          auto-detecting accounts.
  -r, --reseller <name>   SOURCE: only accounts owned by this reseller.
  -u, --users <list>      SOURCE: only these users (space/comma separated).
      --list-only         SOURCE: extract the account list only — no health
                          checks, no page snapshots, no server IP needed.
                          (implies --source; asked for when neither this nor
                          --snapshot is given)
      --snapshot          SOURCE: full pass — health-check every domain and save
                          a page snapshot. (implies --source)
      --ns                SOURCE: look up each domain's nameservers and add
                          ns1,ns2,ns3,ns4 columns to the CSV. Asked for when
                          neither this nor --no-ns is given.
      --no-ns             SOURCE: do not look up nameservers (no CSV columns).
  -o, --outdir <dir>      Output folder for migration.csv + snapshots/.
                          (default: magic-move)
  -p, --php-versions <v>  DESTINATION: cascade to try, in order. (default: "$PHP_VERSIONS")
  -n, --dry-run           DESTINATION: check & record only; never switch PHP,
                          never disable a plugin.
      --no-plugin-heal    DESTINATION: do not disable plugins on a fatal; only
                          step the PHP version.
      --protect <list>    DESTINATION: extra plugin slugs never to disable
                          (space/comma separated; added to the built-in
                          "$PROTECTED_PLUGINS").
      --sync              Sync only: pick accounts (all / users / reseller, or
                          -u, -r, -f <csv>) and rsync their homes. No checks.
      --with-sync         SOURCE: rsync the homes after the pass, without asking.
      --no-sync           SOURCE: do not offer the rsync.
      --dest-ip <ip>      Sync target server (asked for when omitted).
      --dest-port <port>  Sync target SSH port (asked for; default 22).
      --prep              Prep only: prepare THIS server (side picked from
                          --source / --destination, or asked), then exit. Inside
                          a sync flow (--sync / --with-sync) it forces the prep
                          step instead of asking.
      --skip-prep         SOURCE/SYNC: both servers are already prepared — run
                          no prep and print no destination block.
      --peer-ip <ip>      PREP: the OTHER server's IP to whitelist on this one
                          (asked for when omitted).
      --transfer          DESTINATION: pull the accounts with cPanel's Transfer
                          Tool first, without asking (implies --destination).
      --no-transfer       DESTINATION: do not offer the Transfer Tool.
      --src-ip <ip>       TRANSFER: source server IP (default: from the report).
      --src-port <port>   TRANSFER: source SSH port (default: from the report, 22).
      --cpanel            Force the cPanel account detector.
      --directadmin       Force the DirectAdmin account detector.
  -h, --help              Show this help and exit.

Examples:
  magic-move.sh --source
  magic-move.sh --source -r bob
  magic-move.sh --source --list-only --ns
  magic-move.sh --source --snapshot -u "bobuser, shopuser"
  magic-move.sh --source --list-only --with-sync --dest-ip 203.0.113.7 --dest-port 3131
  magic-move.sh --sync -f magic-move/migration.csv
  magic-move.sh --sync --skip-prep -f magic-move/migration.csv
  magic-move.sh --prep --source --peer-ip 203.0.113.7
  magic-move.sh --prep --destination --peer-ip 198.51.100.3
  magic-move.sh --destination -f migration.csv
  magic-move.sh --destination -f https://host/migration.csv --dry-run
  magic-move.sh --destination -f magic-move/migration.csv --transfer
  magic-move.sh --destination -f migration.csv --no-transfer
  magic-move.sh --destination -f migration.csv --protect "wp-rocket, litespeed-cache"
EOF
}

# ---------- Parse Arguments ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --source)        MODE="source"; shift ;;
        --destination)   MODE="destination"; shift ;;
        -i|--ip)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            SERVER_IP="$2"; shift 2 ;;
        -f|--file)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            CSV_IN="$2"; shift 2 ;;
        -r|--reseller)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            RESELLER="$2"; shift 2 ;;
        -u|--users)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            USERS="$2"; shift 2 ;;
        --list-only)     LIST_ONLY="yes"; shift ;;
        --snapshot)      LIST_ONLY="no"; shift ;;
        --ns)            NS_LOOKUP="yes"; shift ;;
        --no-ns)         NS_LOOKUP="no"; shift ;;
        -o|--outdir)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            OUT_DIR="$2"; shift 2 ;;
        -p|--php-versions)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            PHP_VERSIONS="$2"; shift 2 ;;
        -n|--dry-run)    DRY_RUN="yes"; shift ;;
        --no-plugin-heal) PLUGIN_HEAL=""; shift ;;
        --protect)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            PROTECTED_PLUGINS="$PROTECTED_PLUGINS ${2//,/ }"; shift 2 ;;
        --sync)          MODE="sync"; shift ;;
        --with-sync)     SYNC="yes"; shift ;;
        --no-sync)       SYNC="no"; shift ;;
        --dest-ip)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            SYNC_IP="$2"; shift 2 ;;
        --dest-port)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            SYNC_PORT="$2"; shift 2 ;;
        --prep)          PREP="yes"; PREP_GIVEN=1; shift ;;
        --skip-prep)     PREP="skip"; shift ;;
        --peer-ip)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            PEER_IP="$2"; shift 2 ;;
        --transfer)      TRANSFER="yes"; shift ;;
        --no-transfer)   TRANSFER="no"; shift ;;
        --src-ip)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            XFER_SRC_IP="$2"; shift 2 ;;
        --src-port)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            XFER_SRC_PORT="$2"; shift 2 ;;
        --cpanel)        PANEL="cpanel"; shift ;;
        --directadmin)   PANEL="directadmin"; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; break ;;
        -*)              error "Unknown option: $1"; usage; exit 1 ;;
        *)               error "Unexpected argument: $1"; usage; exit 1 ;;
    esac
done

# --prep alone (or with --source/--destination) is its own mode: prep this
# server, then exit — unless a sync flow was asked for, where it just forces
# the prep step instead of asking about it. --transfer is such a flow too.
if [ "$PREP_GIVEN" = 1 ] && [ "$MODE" != "sync" ] && [ "$SYNC" != "yes" ] && [ "$TRANSFER" != "yes" ]; then
    PREP_SIDE="$MODE"
    [ "$PREP_SIDE" = "source" ] || [ "$PREP_SIDE" = "destination" ] || PREP_SIDE=""
    MODE="prep"
fi

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Magic Move${N}"
    echo -e "  Verify a migration: snapshot the source, heal the destination."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}
start_log ""          # whole-server run: no per-domain/user key
print_header

# ---------- Prompt: Mode ----------
# The whole run hinges on this: the source only records, the destination heals.
# --list-only / --snapshot / --ns / --with-sync describe the source pass, so any
# of them settles the mode too — asking again would be asking something already answered.
[ -z "$MODE" ] && { [ -n "$LIST_ONLY" ] || [ -n "$NS_LOOKUP" ] || [ -n "$SYNC" ]; } && MODE="source"
[ -z "$MODE" ] && [ "$TRANSFER" = "yes" ] && MODE="destination"
if [ -z "$MODE" ]; then
    echo -e "${CYAN}Is this the source or the destination server?${RESET}"
    echo "  1) source       — read this server's accounts (list only, or full snapshot)"
    echo "  2) destination  — re-check and heal broken PHP sites"
    echo "  3) sync only    — rsync selected accounts' homes to the destination"
    echo "  4) prep only    — stop SecCheck/scanners & whitelist the peer (no sync)"
    read -r -p "Enter choice (1-4): " MODE_CHOICE
    case "$MODE_CHOICE" in
        1) MODE="source" ;;
        2) MODE="destination" ;;
        3) MODE="sync" ;;
        4) MODE="prep" ;;
        *) error "Invalid choice."; exit 1 ;;
    esac
fi
info "Mode: $MODE"

# ---------- Prompt: Source Scope ----------
# A flag is a decision already made: --list-only / --snapshot go straight
# through. Without either, ask — the two do very different amounts of work.
if [ "$MODE" = "destination" ] && [ "$LIST_ONLY" = "yes" ]; then
    error "--list-only describes the source pass; it has no meaning with --destination."
    exit 1
fi
if [ "$MODE" = "destination" ] && [ "$NS_LOOKUP" = "yes" ]; then
    error "--ns describes the source pass; the destination carries the columns through unchanged."
    exit 1
fi
if [ "$MODE" != "source" ] && { [ "$LIST_ONLY" = "yes" ] || [ "$NS_LOOKUP" = "yes" ] || [ "$SYNC" = "yes" ]; }; then
    error "--list-only / --ns / --with-sync describe the source pass; they have no meaning with --$MODE."
    exit 1
fi
if [ "$MODE" != "destination" ] && [ "$TRANSFER" = "yes" ]; then
    error "--transfer belongs to the destination pass; it has no meaning with --$MODE."
    exit 1
fi
if [ "$MODE" = "source" ] && [ -z "$LIST_ONLY" ]; then
    echo -e "${CYAN}What should the source pass do?${RESET}"
    echo "  1) full pass   — health-check every domain and snapshot each page"
    echo "  2) list only   — just extract the account list (no requests, no snapshots)"
    read -r -p "Enter choice (1 or 2) [1]: " SRC_CHOICE
    case "${SRC_CHOICE:-1}" in
        1) LIST_ONLY="no" ;;
        2) LIST_ONLY="yes" ;;
        *) error "Invalid choice."; exit 1 ;;
    esac
fi
[ "$LIST_ONLY" = "yes" ] && info "Scope: account list only (no health checks)"

# ---------- Output Layout ----------
# One folder holds the whole job, so it can be copied (or zipped) between servers
# in a single move and both passes accumulate into it:
#   magic-move/
#     snapshots/before/   (source)   snapshots/after/  (destination)
#     migration.csv       report.txt   destination-prep.sh
[ -n "$OUT_DIR" ] || OUT_DIR="magic-move"
OUT_CSV="$OUT_DIR/migration.csv"
SNAP_DIR="$OUT_DIR/snapshots"
REPORT_FILE="$OUT_DIR/report.txt"
mkdir -p "$OUT_DIR" || { error "Cannot create output folder: $OUT_DIR"; exit 1; }
info "Output folder: $OUT_DIR"

# ---------- Detect Server IP ----------
# Pin every domain to THIS server so we test the local install regardless of
# where public DNS points. Prefer the panel's own record of its main IP.
detect_server_ip() {
    local ip=""
    [ -r /var/cpanel/mainip ] && ip=$(tr -d '[:space:]' < /var/cpanel/mainip)
    if [ -z "$ip" ] && [ -r /usr/local/directadmin/data/admin/directadmin.conf ]; then
        ip=$(grep -m1 '^serverip=' /usr/local/directadmin/data/admin/directadmin.conf 2>/dev/null | cut -d= -f2)
    fi
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n1)
    printf '%s' "$ip"
}

# ---------- Prompt: Server IP ----------
# Nothing is fetched in list-only, sync or prep mode, so the IP is neither
# needed nor asked for. (Prep finds this server's IP on its own when it needs
# to embed it in the destination block.)
if [ "$LIST_ONLY" != "yes" ] && [ "$MODE" != "sync" ] && [ "$MODE" != "prep" ]; then
    if [ -z "$SERVER_IP" ]; then
        DETECTED_IP=$(detect_server_ip)
        if [ -n "$DETECTED_IP" ]; then
            read -r -p "Server IP [$DETECTED_IP]: " SERVER_IP
            SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
        else
            read -r -p "Server IP (auto-detect failed, enter manually): " SERVER_IP
        fi
        [ -n "$SERVER_IP" ] || { error "No server IP given."; exit 1; }
    fi
    info "Server IP: $SERVER_IP"
fi

# ---------- Nameserver Lookup (source) ----------
# The delegated nameservers say whether a domain has actually been repointed, so
# recording them next to the status turns the CSV into a to-do list for the DNS
# side of the move. Answers are sorted, so the same names land in the same
# columns on both passes and the two CSVs can be diffed field by field.
NS_TOOL=""
detect_ns_tool() {      # sets NS_TOOL — must be called plainly, not in $( )
    local t
    for t in dig host nslookup; do
        command -v "$t" >/dev/null 2>&1 && { NS_TOOL="$t"; return 0; }
    done
    return 1
}

ns_query() {    # $1 = name -> one bare, lowercase nameserver per line
    case "$NS_TOOL" in
        dig)      dig +short +time=3 +tries=1 NS "$1" 2>/dev/null ;;
        host)     host -W 3 -t NS "$1" 2>/dev/null | awk '/name server/{print $NF}' ;;
        nslookup) nslookup -type=ns -timeout=3 "$1" 2>/dev/null | awk '/nameserver = /{print $NF}' ;;
    esac | tr -d '\r' | tr 'A-Z' 'a-z' | sed 's/\.$//' | grep -E '^[a-z0-9][a-z0-9.-]*$' | sort -u
}

# An addon domain or subdomain has no NS record of its own, so fall back one
# label up to the zone that actually holds the delegation.
lookup_ns() {   # $1 = domain -> sets NS_CSV to exactly four comma-separated fields
    local d="$1" out
    out=$(ns_query "$d")
    if [ -z "$out" ] && [ "$(printf '%s' "$d" | tr -cd '.' | wc -c)" -ge 2 ]; then
        out=$(ns_query "${d#*.}")
    fi
    NS_CSV=$(printf '%s\n' "$out" | grep . | head -n 4 |
             awk '{a[NR]=$0} END{printf "%s,%s,%s,%s", a[1], a[2], a[3], a[4]}')
}

# ---------- Prompt: Nameservers ----------
# Optional because it costs a DNS query per domain and needs a resolver tool;
# --ns / --no-ns answer it up front.
if [ "$MODE" = "source" ] && [ -z "$NS_LOOKUP" ]; then
    read -r -p "Also record each domain's nameservers (ns1-ns4) in the CSV? [y/N]: " NS_CHOICE
    case "$NS_CHOICE" in [Yy]*) NS_LOOKUP="yes" ;; *) NS_LOOKUP="no" ;; esac
fi
if [ "$NS_LOOKUP" = "yes" ]; then
    if ! detect_ns_tool; then
        error "No dig, host or nslookup found — cannot look up nameservers."
        info "Install bind-utils (dnsutils), or re-run with --no-ns."
        exit 1
    fi
    info "Nameservers: recorded as ns1-ns4 (via $NS_TOOL)"
fi

# ---------- Account Detection (source) ----------
# One file/dir per account holds both the account's main domain and its owner
# (reseller). Exact-key awk keeps addon/parked/sibling keys out. Emits
# owner<TAB>user<TAB>domain.
cpanel_rows() {
    local f user owner d
    for f in /var/cpanel/users/*; do
        [ -f "$f" ] || continue
        user=$(basename "$f")
        case "$user" in system|root|nobody) continue ;; esac
        owner=$(awk -F= '$1=="OWNER"{print $2; exit}' "$f")
        d=$(awk -F= '$1=="DNS"{print $2; exit}' "$f")
        if [ -z "$d" ] && [ -r "/var/cpanel/userdata/$user/main" ]; then
            d=$(awk -F':[[:space:]]*' '$1=="main_domain"{print $2; exit}' "/var/cpanel/userdata/$user/main")
        fi
        [ -n "$d" ] && printf '%s\t%s\t%s\n' "${owner:-root}" "$user" "$d"
    done
}

directadmin_rows() {
    local base=/usr/local/directadmin/data/users
    local dir user owner d
    for dir in "$base"/*/; do
        [ -d "$dir" ] || continue
        user=$(basename "$dir")
        owner=""; d=""
        if [ -r "$dir/user.conf" ]; then
            owner=$(awk -F= '$1=="creator"{print $2; exit}' "$dir/user.conf")
            d=$(awk -F= '$1=="domain"{print $2; exit}' "$dir/user.conf")
        fi
        [ -z "$d" ] && [ -r "$dir/domains.list" ] && d=$(awk 'NF{print; exit}' "$dir/domains.list")
        [ -n "$d" ] && printf '%s\t%s\t%s\n' "${owner:-admin}" "$user" "$d"
    done
}

detect_panel() {
    if [ -d /usr/local/cpanel ]; then PANEL="cpanel"
    elif [ -d /usr/local/directadmin ]; then PANEL="directadmin"
    else return 1; fi
}

# ---------- Server Facts (report) ----------
# What the report records about the server it ran on, so the next pass (and the
# Transfer Tool on the destination) starts from facts instead of questions.
panel_version() {   # $1 = cpanel|directadmin -> version string or nothing
    local v=""
    case "$1" in
        cpanel)
            [ -r /usr/local/cpanel/version ] && v=$(tr -d '[:space:]' < /usr/local/cpanel/version)
            [ -z "$v" ] && [ -x /usr/local/cpanel/cpanel ] && v=$(/usr/local/cpanel/cpanel -V 2>/dev/null | awk 'NR==1{print $1}') ;;
        directadmin)
            local da=/usr/local/directadmin/directadmin
            if [ -x "$da" ]; then
                v=$("$da" version 2>/dev/null | head -n1)
                [ -z "$v" ] && v=$("$da" v 2>/dev/null | head -n1)
                v=$(printf '%s' "$v" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
            fi ;;
    esac
    printf '%s' "$v"
}
panel_label() {     # $1 = cpanel|directadmin -> "cPanel" / "DirectAdmin"
    case "$1" in cpanel) printf 'cPanel' ;; directadmin) printf 'DirectAdmin' ;; *) printf '%s' "$1" ;; esac
}
local_ssh_port() {  # the port sshd listens on here (first one), default 22
    local p=""
    command -v sshd >/dev/null 2>&1 && p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
    [ -z "$p" ] && [ -r /etc/ssh/sshd_config ] && \
        p=$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config)
    printf '%s' "${p:-22}"
}
os_name() {
    [ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}"
}

# ---------- Report Sections ----------
# report.txt travels with the job folder and holds one section per pass, each
# opened by its "Magic Move — <NAME> report" line. A pass replaces only its own
# section, so the source facts survive the destination pass (and re-runs).
report_set_section() {   # $1 = SOURCE|TRANSFER|DESTINATION ; stdin = section body
    local name="Magic Move — $1 report" body keep=""
    body=$(cat)
    if [ -f "$REPORT_FILE" ]; then
        keep=$(awk -v n="$name" '/^Magic Move — [A-Z]+ report/ { skip = ($0 == n) } !skip' "$REPORT_FILE")
    fi
    {
        [ -n "$keep" ] && printf '%s\n\n' "$keep"
        printf '%s\n%s\n' "$name" "$body"
    } > "$REPORT_FILE"
}

# Read the SOURCE section of a report. Works with every report version: old ones
# carry "Panel : cpanel|directadmin|list" and, on a full pass, "Server IP"; new
# ones add the panel version, "Source IP" and "SSH port". "list"/missing = unknown.
SRC_PANEL="" SRC_PANEL_VER="" SRC_IP="" SRC_SSH_PORT="" SRC_HOST=""
read_source_report() {   # $1 = report file
    [ -f "$1" ] || return 1
    local sect k v line
    sect=$(awk '/^Magic Move — SOURCE report/{on=1; next} /^Magic Move — [A-Z]+ report/{on=0} on' "$1")
    [ -n "$sect" ] || return 1
    while IFS= read -r line; do
        case "$line" in *:*) ;; *) continue ;; esac
        k=$(printf '%s' "${line%%:*}" | sed 's/[[:space:]]*$//')
        v=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$k" in
            Panel)
                case "$(printf '%s' "$v" | tr 'A-Z' 'a-z')" in
                    cpanel*|*whm*) SRC_PANEL="cpanel" ;;
                    directadmin*)  SRC_PANEL="directadmin" ;;
                esac
                SRC_PANEL_VER=$(printf '%s' "$v" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1) ;;
            "Source IP")  SRC_IP="$v" ;;
            "Server IP")  [ -n "$SRC_IP" ] || SRC_IP="$v" ;;
            "SSH port")   SRC_SSH_PORT="$v" ;;
            Hostname)     SRC_HOST="$v" ;;
        esac
    done <<< "$sect"
    [[ "$SRC_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || SRC_IP=""
    [[ "$SRC_SSH_PORT" =~ ^[0-9]+$ ]] || SRC_SSH_PORT=""
    return 0
}

# Filter owner<TAB>user<TAB>domain rows. Both panels carry an owner (cPanel
# OWNER, DirectAdmin creator), so reseller filtering works on either.
filter_users() {      # $1 rows, $2 space/comma user list
    printf '%s\n' "$1" | awk -F'\t' -v list="$2" '
        BEGIN { n=split(list, a, /[ ,]+/); for (k=1;k<=n;k++) if (a[k]!="") want[a[k]]=1 }
        ($2 in want)'
}
filter_reseller() {   # $1 rows, $2 reseller name
    printf '%s\n' "$1" | awk -F'\t' -v r="$2" '$1==r'
}

# ---------- Snapshot Writer ----------
# Save the page so it renders faithfully offline: external stylesheets are
# inlined, root/protocol-relative asset URLs are absolutized back to the live
# site, and every <script> is neutralized so the saved copy can never re-run JS
# (which would phone home, throw, or blank the page). Needs perl — present on
# every cPanel/DirectAdmin box; without it we fall back to raw HTML. The href we
# hand to curl is constrained to a shell-safe URL so a hostile page cannot get
# command execution out of us while we run as root.
save_snapshot() {
    local domain="$1" body="$2" snap="$3"
    if ! command -v perl >/dev/null 2>&1; then
        printf '%s' "$body" > "$snap" 2>/dev/null
        return
    fi
    printf '%s' "$body" | \
        SNAP_BASE="https://$domain" SNAP_IP="$SERVER_IP" \
        perl -0777 -e '
        my $html = do { local $/; <STDIN> };
        my $base = $ENV{SNAP_BASE};
        my $ip   = $ENV{SNAP_IP};
        sub abso {
            my ($u) = @_;
            return $u if $u =~ m{^(?:https?:|data:|mailto:|tel:|javascript:|\#)}i;
            return "https:$u" if $u =~ m{^//};
            return "$base$u"  if $u =~ m{^/};
            return $u;
        }
        # 1) inline external stylesheets (shell-safe href only)
        $html =~ s{<link\b[^>]*>}{
            my $tag = $&;
            if ($tag =~ /rel\s*=\s*["\x27]?[^"\x27>]*stylesheet/i
                && $tag =~ /href\s*=\s*["\x27]([^"\x27]+)["\x27]/i) {
                my $href = abso($1);
                if ($href =~ m{^https?://} && $href =~ m{^[^\s"\x27\$\\\x60]+$}) {
                    my $css = qx(curl -kfsS --resolve "*:443:$ip" --resolve "*:80:$ip" --max-time 15 "$href" 2>/dev/null);
                    length($css) ? "<style data-inlined=\"$href\">\n$css\n</style>" : $tag;
                } else { $tag }
            } else { $tag }
        }gei;
        # 2) absolutize asset URLs (src/href) and CSS url(...) targets
        $html =~ s{\b(src|href)\s*=\s*["\x27]([^"\x27]+)["\x27]}{ $1.q{="}.abso($2).q{"} }gei;
        $html =~ s{url\(\s*(["\x27]?)([^"\x27)]+)\1\s*\)}{ q{url(}.$1.abso($2).$1.q{)} }gei;
        # 3) neutralize every script (our type is parsed first, so it wins)
        $html =~ s{<script(\s|>)}{<script type="text/neutralized" data-orig$1}gi;
        print $html;
    ' > "$snap" 2>/dev/null
}

# ---------- Health Probe ----------
# Fetch body + status with ALL hostnames pinned to SERVER_IP (so a redirect to
# www/a subdomain follows onto this server), retrying a 000 with escalating
# timeouts. Saves the final body to <snapshot> and sets:
#   H_CODE    last HTTP code seen
#   H_STATUS  "OK" or "Fail(<reason>)"
#   H_BROKEN  yes when a PHP version switch could plausibly clear it
health() {
    local domain="$1" snap="$2"
    local t resp code body=""
    H_CODE="000"
    for t in $TIMEOUTS; do
        resp=$(curl -kLsS --resolve "*:443:$SERVER_IP" --resolve "*:80:$SERVER_IP" \
            -w '\n%{http_code}' --max-time "$t" "https://$domain" 2>/dev/null)
        code="${resp##*$'\n'}"
        body="${resp%$'\n'*}"
        H_CODE="$code"
        [ "$code" != "000" ] && break   # got a real answer; no need to wait longer
    done

    [ -n "$snap" ] && save_snapshot "$domain" "$body" "$snap"
    H_BODY="$body"          # exposed so the plugin-fatal healer can read the error

    # A PHP fatal can surface as either 200 (error thrown after headers flushed)
    # or 500 (thrown before). So inspect the BODY for a specific signature on
    # both codes and only fall back to a bare Fail(500) when none is found — a
    # WordPress critical-error page that returns 500 must still read "wp error".
    H_BROKEN="no"
    if [ "$code" = "000" ]; then
        H_STATUS="Fail(timeout)"
    elif [ "$code" = "200" ] || [ "$code" = "500" ]; then
        if grep -qiE 'there has been a critical error|WordPress database error' <<<"$body"; then
            H_STATUS="Fail(wp error)"; H_BROKEN="yes"
        elif grep -qiE 'the ionCube Loader for PHP needs to be installed' <<<"$body"; then
            H_STATUS="Fail(ioncube)"; H_BROKEN="yes"
        elif grep -qiE '<b>Fatal error' <<<"$body"; then
            H_STATUS="Fail(php fatal)"; H_BROKEN="yes"
        elif [ "$code" = "500" ]; then
            H_STATUS="Fail(500)"; H_BROKEN="yes"
        elif grep -qiE '<html|<!doctype html' <<<"$body" && ! grep -qi '</html>' <<<"$body"; then
            H_STATUS="Fail(truncated)"; H_BROKEN="yes"
        else
            H_STATUS="OK"
        fi
    elif [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "307" ] || [ "$code" = "308" ]; then
        H_STATUS="Fail(redirect)"
    else
        H_STATUS="Fail($code)"
    fi
}

# ---------- PHP Version (destination) ----------
get_current_php() {
    selectorctl --user-current --user="$1" 2>/dev/null | awk 'NR==1{print $1}'
}
switch_php() {
    [ -n "$DRY_RUN" ] && return 0
    selectorctl --set-user-current="$2" --user="$1" >/dev/null 2>&1
}

# ---------- Plugin-Fatal Healing (destination) ----------
# When a site is down with a plugin fatal, WordPress normally shows a generic
# "critical error" page that hides which plugin failed. So we turn WP_DEBUG +
# WP_DEBUG_DISPLAY on, re-fetch, read the culprit plugin from the shown error's
# path (.../wp-content/plugins/<slug>/...), disable it by renaming its folder to
# <slug>.dis, and repeat for any further culprit — then restore wp-config.
# Elementor and WooCommerce (and anything in --protect) are never disabled.

# Resolve the on-disk webroot for a user+domain on either panel.
resolve_webroot_for() {   # $1 user  $2 domain  -> echoes webroot or nothing
    local user="$1" domain="$2" docroot=""
    if [ -d /usr/local/cpanel ]; then
        if [ -r "/var/cpanel/userdata/$user/$domain" ]; then
            docroot=$(awk -F':[[:space:]]*' '$1=="documentroot"{print $2; exit}' \
                      "/var/cpanel/userdata/$user/$domain")
        fi
        printf '%s' "${docroot:-/home/$user/public_html}"
    elif [ -d /usr/local/directadmin ]; then
        local conf="/usr/local/directadmin/data/users/$user/domains/$domain.conf"
        [ -r "$conf" ] && docroot=$(awk -F= '$1=="document_root"{print $2; exit}' "$conf")
        printf '%s' "${docroot:-/home/$user/domains/$domain/public_html}"
    fi
}

# True when a plugin slug is protected (exact slug or "<slug>-*", e.g. elementor-pro).
is_protected_plugin() {   # $1 slug
    local p
    for p in $PROTECTED_PLUGINS; do
        [ -n "$p" ] || continue
        case "$1" in "$p"|"$p"-*) return 0 ;; esac
    done
    return 1
}

# Find wp-config.php for a webroot (same dir, or one level up as WP allows).
find_wp_config() {   # $1 webroot -> echoes path or nothing
    [ -f "$1/wp-config.php" ] && { printf '%s' "$1/wp-config.php"; return; }
    local up; up=$(dirname "$1")
    [ -f "$up/wp-config.php" ] && printf '%s' "$up/wp-config.php"
}

# Turn WP_DEBUG + display on in a wp-config.php, keeping a restorable backup.
enable_wp_debug() {   # $1 wp-config path
    local cfg="$1"
    cp -p "$cfg" "$cfg.magicmove.bak" 2>/dev/null || return 1
    # Neutralise any existing debug/display defines so ours take effect cleanly.
    sed -i -E "s@^([[:space:]]*define\([[:space:]]*['\"](WP_DEBUG|WP_DEBUG_DISPLAY|WP_DEBUG_LOG)['\"])@// magic-move // \1@" "$cfg"
    # Inject our defines right after the first <?php.
    awk 'BEGIN{done=0}
         {print}
         (!done && $0 ~ /<\?php/){
             print "/* magic-move temporary debug (auto-removed) */";
             print "define(\047WP_DEBUG\047, true);";
             print "define(\047WP_DEBUG_DISPLAY\047, true);";
             print "@ini_set(\047display_errors\047, 1);";
             done=1
         }' "$cfg" > "$cfg.mmtmp" 2>/dev/null && mv "$cfg.mmtmp" "$cfg" || {
        mv -f "$cfg.magicmove.bak" "$cfg" 2>/dev/null; return 1; }
}

# Restore wp-config.php from its backup (no-op if there is none).
restore_wp_config() {   # $1 wp-config path
    [ -n "${1:-}" ] && [ -f "$1.magicmove.bak" ] && mv -f "$1.magicmove.bak" "$1"
}

# Heal a plugin fatal for one user+domain. Sets DISABLED_PLUGINS to a comma list
# of slugs it turned off. Returns 0 when the site ends up healthy, else 1.
heal_plugin_fatal() {   # $1 user  $2 domain
    DISABLED_PLUGINS=""
    [ -n "$PLUGIN_HEAL" ] || return 1
    [ -z "$DRY_RUN" ] || return 1
    local user="$1" domain="$2" wr cfg plugdir slug target n=0 max=6 rc=1
    wr=$(resolve_webroot_for "$user" "$domain"); [ -n "$wr" ] || return 1
    cfg=$(find_wp_config "$wr");                 [ -n "$cfg" ] || return 1
    plugdir="$(dirname "$cfg")/wp-content/plugins"
    [ -d "$plugdir" ] || plugdir="$wr/wp-content/plugins"
    [ -d "$plugdir" ] || return 1

    restore_wp_config "$cfg"        # self-heal any wp-config left edited by a crash
    enable_wp_debug "$cfg" || return 1

    while [ "$n" -lt "$max" ]; do
        n=$((n+1))
        health "$domain" ""         # re-fetch with debug on; no snapshot overwrite
        if [ "$H_STATUS" = "OK" ]; then rc=0; break; fi
        # The culprit is the first wp-content/plugins/<slug>/ path in the error.
        slug=$(printf '%s' "$H_BODY" \
               | grep -aoiE 'wp-content/plugins/[^/"'"'"' ]+' \
               | head -n1 | sed -E 's@.*/@@')
        [ -n "$slug" ] || break     # fatal not attributable to a plugin path
        if is_protected_plugin "$slug"; then
            printf ' -> %bculprit %s is protected%b' "$YELLOW" "$slug" "$RESET"
            log "DEST PLUGIN-HEAL $domain culprit '$slug' protected — not disabling"
            break
        fi
        [ -d "$plugdir/$slug" ] || break
        target="$plugdir/$slug.dis"
        [ -e "$target" ] && target="$plugdir/$slug.dis.$(date +%s)"
        if mv "$plugdir/$slug" "$target" 2>/dev/null; then
            DISABLED_PLUGINS="${DISABLED_PLUGINS:+$DISABLED_PLUGINS,}$slug"
            printf ' -> %bdisabled %s%b' "$GREEN" "$slug" "$RESET"
            log "DEST PLUGIN-DISABLED $domain -> $slug (-> $(basename "$target"))"
        else
            log "DEST PLUGIN-HEAL $domain could not rename $slug"
            break
        fi
    done

    restore_wp_config "$cfg"
    return "$rc"
}

# ---------- Snapshot Helper ----------
snap_path() {   # $1 = subdir (before|after), $2 = domain
    printf '%s/%s/%s.html' "$SNAP_DIR" "$1" "$2"
}

# ---------- Duration ----------
fmt_duration() {   # $1 = seconds -> "1h 02m 03s"
    local s=$1 h m
    h=$((s/3600)); m=$(((s%3600)/60)); s=$((s%60))
    [ "$h" -gt 0 ] && printf '%dh %02dm %02ds' "$h" "$m" "$s" \
        || { [ "$m" -gt 0 ] && printf '%dm %02ds' "$m" "$s" || printf '%ds' "$s"; }
}

# ---------- Offer To Zip ----------
# The output folder is meant to travel to the other server; offer to bundle it.
offer_zip() {
    [ -t 0 ] || return 0            # non-interactive: leave the folder as-is
    local ans
    read -r -p "Zip the output folder for transfer? [y/N]: " ans
    case "$ans" in [Yy]*) ;; *) return 0 ;; esac
    if command -v zip >/dev/null 2>&1; then
        rm -f "$OUT_DIR.zip"
        ( zip -rq "$OUT_DIR.zip" "$OUT_DIR" ) && success "Created $OUT_DIR.zip"
    else
        ( tar -czf "$OUT_DIR.tar.gz" "$OUT_DIR" ) && success "zip not found — created $OUT_DIR.tar.gz"
    fi
}

# ---------- Account Selection (source / sync) ----------
# Sets ROWS (owner<TAB>user<TAB>domain). An explicit "user,domain" list wins;
# otherwise auto-detect and let the operator narrow the set (all / specific
# users / a reseller). Flags (-u / -r) skip the prompt for non-interactive runs.
ROWS=""
select_accounts() {
    if [ -n "$CSV_IN" ]; then
        [ -f "$CSV_IN" ] || { error "List not found: $CSV_IN"; exit 1; }
        ROWS=$(awk -F, 'NF>=2 && $1!~/^#/ && $1!="" && $1!="user" {print "?\t"$1"\t"$2}' "$CSV_IN")
    else
        [ -n "$PANEL" ] || detect_panel || { error "No cPanel/DirectAdmin found. Use --cpanel/--directadmin or -f."; exit 1; }
        info "Detecting accounts via: $PANEL"
        ROWS=$("${PANEL}_rows")
        [ -n "$ROWS" ] || { error "No accounts detected."; exit 1; }

        if [ -n "$USERS" ]; then
            ROWS=$(filter_users "$ROWS" "$USERS")
            [ -n "$ROWS" ] || { error "None of the given users matched."; exit 1; }
        elif [ -n "$RESELLER" ]; then
            ROWS=$(filter_reseller "$ROWS" "$RESELLER")
            [ -n "$ROWS" ] || { error "No accounts found for reseller: $RESELLER"; exit 1; }
        else
            local total_all
            total_all=$(printf '%s\n' "$ROWS" | grep -c .)
            echo -e "${CYAN}Which accounts do you want to include?${RESET}"
            echo "  1) all accounts ($total_all)"
            echo "  2) specific users"
            echo "  3) a reseller's accounts"
            read -r -p "Enter choice (1-3): " SEL
            case "$SEL" in
                1) : ;;
                2) read -r -p "Usernames (space/comma separated): " USERS
                   ROWS=$(filter_users "$ROWS" "$USERS")
                   [ -n "$ROWS" ] || { error "None of the given users matched."; exit 1; } ;;
                3) echo -e "${CYAN}Resellers with accounts:${RESET}"
                   local reslist=() rline rnum rc rn ridx
                   mapfile -t reslist < <(printf '%s\n' "$ROWS" | cut -f1 | sort | uniq -c | awk '{print $1" "$2}')
                   ridx=1
                   for rline in "${reslist[@]}"; do
                       rc="${rline%% *}"; rn="${rline#* }"
                       printf "  %2d) %-20s %s account(s)\n" "$ridx" "$rn" "$rc"
                       ridx=$((ridx+1))
                   done
                   read -r -p "Enter reseller number: " rnum
                   [[ "$rnum" =~ ^[0-9]+$ ]] && [ "$rnum" -ge 1 ] && [ "$rnum" -le "${#reslist[@]}" ] \
                       || { error "Invalid selection."; exit 1; }
                   rline="${reslist[$((rnum-1))]}"; RESELLER="${rline#* }"
                   info "Reseller: $RESELLER"
                   ROWS=$(filter_reseller "$ROWS" "$RESELLER")
                   [ -n "$ROWS" ] || { error "No accounts found for reseller: $RESELLER"; exit 1; } ;;
                *) error "Invalid choice."; exit 1 ;;
            esac
        fi
    fi
}

# ════════════════════════════════════════════════════════════
#   MIGRATION PREP (SecCheck / scanners / firewall / ssh)
# ════════════════════════════════════════════════════════════
# SecCheck re-enables itself between passes and the destination's firewall would
# drop the rsync, so both servers are prepared before the first byte moves:
#   both sides : SecCheck off (cron quarantined, /etc/SecCheck moved away),
#                scanners stopped & disabled, hosts.deny "ALL: ALL" commented,
#                the peer's IP whitelisted in CSF.
#   destination: + SSH root login (PermitRootLogin/PasswordAuthentication yes,
#                AllowUsers root), validated with sshd -t before any restart.
# Every step is idempotent and keeps a backup, so re-runs and re-pastes are safe.

disable_seccheck() {
    systemctl stop SecCheck OnlineSecCheck.timer OnlineSecCheck.service 2>/dev/null
    systemctl disable SecCheck OnlineSecCheck.timer OnlineSecCheck.service 2>/dev/null
    # Quarantine the cron entries that resurrect it — only *uncommented* lines,
    # so re-runs never stack a second '#'. A copy of the crontab is kept first.
    if crontab -l > "$OUT_DIR/crontab.before-magic-move.bak" 2>/dev/null; then
        crontab -l 2>/dev/null \
            | sed -E '/(SecCheck_Installer|systemctl restart SecCheck)/{/^[[:space:]]*#/!s/^/#/}' \
            | crontab -
        log "PREP seccheck: cron entries commented (backup: $OUT_DIR/crontab.before-magic-move.bak)"
    fi
    systemctl stop SecCheck.service 2>/dev/null
    if [ -d /etc/SecCheck ]; then
        local tgt="/etc/SecCheck-old"
        [ -e "$tgt" ] && tgt="/etc/SecCheck-old.$(date +%s)"
        mv /etc/SecCheck "$tgt" 2>/dev/null \
            && log "PREP seccheck: /etc/SecCheck -> $tgt"
    fi
    log "PREP seccheck: stopped & disabled"
}

stop_scanners() {
    local s
    for s in clamd@scan clamav-freshclam cxswatch rspamd spamd; do
        systemctl stop "$s" 2>/dev/null
        systemctl disable "$s" 2>/dev/null
    done
    # DirectAdmin: mark them OFF so the panel stops monitoring/restarting them.
    local ss="/usr/local/directadmin/data/admin/services.status"
    if [ -f "$ss" ]; then
        sed -i -E 's/^(rspamd|clamd@scan|clamav-freshclam)=ON/\1=OFF/' "$ss" 2>/dev/null
    fi
    log "PREP scanners: stopped & disabled (clamd@scan, clamav-freshclam, cxswatch, rspamd, spamd)"
}

allow_hosts_deny() {
    [ -f /etc/hosts.deny ] || return 0
    if grep -Eq '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL' /etc/hosts.deny; then
        [ -f /etc/hosts.deny.bak ] || cp -p /etc/hosts.deny /etc/hosts.deny.bak
        sed -i '/ALL[[:space:]]*:[[:space:]]*ALL/{/^[[:space:]]*#/!s/^/#/}' /etc/hosts.deny
        success "hosts.deny: ALL: ALL commented (backup: /etc/hosts.deny.bak)"
        log "PREP hosts.deny: ALL: ALL commented"
    else
        info "hosts.deny: no active ALL: ALL — nothing to do"
    fi
}

allow_in_firewall() {   # $1 = peer IP to whitelist on THIS server
    local ip="$1" esc
    esc="${ip//./\\.}"
    if command -v csf >/dev/null 2>&1; then
        if grep -qE "^${esc}([[:space:]]|$)" /etc/csf/csf.allow 2>/dev/null; then
            info "CSF: $ip is already allowed"
        else
            if csf -a "$ip" >/dev/null 2>&1; then
                success "CSF: $ip allowed"
            else
                error "CSF: could not add $ip — add it manually"
            fi
        fi
        csf -r >/dev/null 2>&1
        log "PREP firewall: $ip allowed, csf reloaded"
    else
        info "CSF not found — make sure $ip is allowed in the firewall manually."
        log "PREP firewall: csf missing, manual action needed for $ip"
    fi
}

open_ssh_root() {
    local cfg="/etc/ssh/sshd_config" K
    if [ ! -f "$cfg" ]; then
        error "sshd_config not found — enable root SSH manually."
        return 1
    fi
    [ -f "$cfg.bak" ] || cp -p "$cfg" "$cfg.bak"
    # Replace existing directives in place; append only when absent (sshd honours
    # the FIRST occurrence, so commented defaults are safe to append after).
    for K in PermitRootLogin PasswordAuthentication; do
        if grep -Eqi "^[[:space:]]*$K[[:space:]]" "$cfg"; then
            sed -i -E "s/^[[:space:]]*$K[[:space:]].*/$K yes/I" "$cfg"
        else
            echo "$K yes" >> "$cfg"
        fi
    done
    # AllowUsers: root must be on the FIRST AllowUsers line, so extend it rather
    # than appending a second directive sshd would ignore.
    if grep -Eqi '^[[:space:]]*AllowUsers[[:space:]]' "$cfg"; then
        grep -Eqi '^[[:space:]]*AllowUsers[[:space:]].*\broot\b' "$cfg" || \
            sed -i -E 's/^([[:space:]]*AllowUsers[[:space:]].*)$/\1 root/I' "$cfg"
    else
        echo "AllowUsers root" >> "$cfg"
    fi
    # Validate BEFORE restarting: a broken config must never cost us the session.
    local SSHD_BIN
    SSHD_BIN=$(command -v sshd 2>/dev/null || printf '/usr/sbin/sshd')
    if "$SSHD_BIN" -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null \
            || service sshd restart >/dev/null 2>&1
        if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
            success "SSH: root login enabled, sshd restarted (backup: $cfg.bak)"
            log "PREP sshd: root login enabled, restarted"
        else
            error "SSH restarted but its state is unknown — verify you can still log in!"
            log "PREP sshd: restarted, state unknown"
        fi
    else
        cp -f "$cfg.bak" "$cfg"
        error "sshd -t failed after the edit — backup restored, sshd NOT restarted."
        log "PREP sshd: config test failed, backup restored"
        return 1
    fi
}

# $3 decides root SSH: the side that is CONNECTED TO needs it — the destination
# for an rsync push, the source for a Transfer Tool pull. Default: destination.
run_prep() {   # $1 = side (source|destination)   $2 = peer IP to whitelist here   $3 = open root SSH? (yes|no)
    [ "$(id -u)" = 0 ] || { error "Prep must run as root."; return 1; }
    local side="$1" peer="$2" ssh="${3:-}"
    [ -n "$ssh" ] || { [ "$side" = "destination" ] && ssh="yes" || ssh="no"; }
    echo
    info "Prep on this ${side} — whitelisting peer ${peer}"
    disable_seccheck
    stop_scanners
    allow_hosts_deny
    allow_in_firewall "$peer"
    if [ "$ssh" = "yes" ]; then
        open_ssh_root
    fi
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  ${GREEN}Prep done on this server${RESET}"
    echo -e "   - SecCheck stopped & disabled (cron entries quarantined)"
    echo -e "   - Scanners stopped & disabled (clamd@scan, freshclam, cxswatch, rspamd, spamd)"
    echo -e "   - hosts.deny checked"
    echo -e "   - CSF: $peer allowed"
    [ "$ssh" = "yes" ] && echo -e "   - SSH root login enabled"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    log "PREP done side=$side peer=$peer"
    echo
}

# This server's IP as the DESTINATION must see it (for the block's whitelist):
# panel record / route table first, and a public-IP lookup when only a private
# address is visible (NAT). Confirmed interactively — whitelisting the wrong IP
# would lock the sync out.
prep_source_ip() {   # $1 = who whitelists it (default: destination)
    local ip="$SERVER_IP" pub ans who="${1:-destination}"
    [ -z "$ip" ] && ip=$(detect_server_ip)
    case "$ip" in ""|10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
        if command -v curl >/dev/null 2>&1; then
            pub=$(curl -4ks --max-time 6 https://api.ipify.org 2>/dev/null) \
                || pub=$(curl -4ks --max-time 6 http://ifconfig.me 2>/dev/null)
            [ -n "$pub" ] && ip="$pub"
        fi
    ;; esac
    if [ -t 0 ]; then
        read -r -p "This server's IP to whitelist on the $who [$ip]: " ans
        ip="${ans:-$ip}"
    fi
    case "$ip" in
        [0-9A-Fa-f]*|:[0-9A-Fa-f]*) [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] && { printf '%s' "$ip"; return 0; } ;;
    esac
    return 1
}

# The peer block: complete, prompt-free, idempotent, with this server's IP
# already in it. Written once to a file (so it can be scp'd too) and printed for
# pasting. The source writes it for the destination (rsync push); the destination
# writes it for the source (Transfer Tool pull). Both open root SSH there, since
# that is the side being connected to. __PEER_IP__ / __ROLE__ / __OTHER__ are
# substituted after the quoted heredoc.
write_prep_block() {   # $1 = role of the server that runs it (destination|source)   $2 = this server's IP   $3 = output path
    local role="$1" other
    [ "$role" = "source" ] && other="destination" || other="source"
    cat > "$3" <<'MMBLOCK'
#!/bin/bash
# ════════════════════════════════════════════════════════════
#   Magic Move — __ROLE_UC__ prep (generated on the __OTHER__)
#   Whitelists the __OTHER__, stops SecCheck + scanners, opens SSH root.
#   Safe to re-run; backups are kept next to every edited file.
# ════════════════════════════════════════════════════════════
PEER_IP="__PEER_IP__"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "── Magic Move — __ROLE__ prep (__OTHER__: $PEER_IP) ──"

# 1) SecCheck — stop, disable, quarantine its cron, move its directory
systemctl stop SecCheck OnlineSecCheck.timer OnlineSecCheck.service 2>/dev/null
systemctl disable SecCheck OnlineSecCheck.timer OnlineSecCheck.service 2>/dev/null
if crontab -l > /root/crontab.magicmove.bak 2>/dev/null; then
    crontab -l 2>/dev/null | sed -E '/(SecCheck_Installer|systemctl restart SecCheck)/{/^[[:space:]]*#/!s/^/#/}' | crontab -
    echo "   SecCheck cron entries commented (backup: /root/crontab.magicmove.bak)"
fi
systemctl stop SecCheck.service 2>/dev/null
if [ -d /etc/SecCheck ]; then
    T="/etc/SecCheck-old"; [ -e "$T" ] && T="/etc/SecCheck-old.$(date +%s)"
    mv /etc/SecCheck "$T" 2>/dev/null && echo "   /etc/SecCheck moved to $T"
fi

# 2) Scanners / anti-spam — stop & disable
for s in clamd@scan clamav-freshclam cxswatch rspamd spamd; do
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
done
SS="/usr/local/directadmin/data/admin/services.status"
if [ -f "$SS" ]; then
    sed -i -E 's/^(rspamd|clamd@scan|clamav-freshclam)=ON/\1=OFF/' "$SS"
fi
echo "   Scanners stopped & disabled (clamd@scan, freshclam, cxswatch, rspamd, spamd)"

# 3) hosts.deny — unblock everyone
if [ -f /etc/hosts.deny ] && grep -Eq '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL' /etc/hosts.deny; then
    [ -f /etc/hosts.deny.bak ] || cp -p /etc/hosts.deny /etc/hosts.deny.bak
    sed -i '/ALL[[:space:]]*:[[:space:]]*ALL/{/^[[:space:]]*#/!s/^/#/}' /etc/hosts.deny
    echo "   /etc/hosts.deny: ALL: ALL commented (backup kept)"
fi

# 4) Firewall — allow the __OTHER__ server
if command -v csf >/dev/null 2>&1; then
    if grep -qE "^${PEER_IP//./\\.}([[:space:]]|$)" /etc/csf/csf.allow 2>/dev/null; then
        echo "   CSF: $PEER_IP already allowed"
    else
        csf -a "$PEER_IP" >/dev/null 2>&1 && echo "   CSF: $PEER_IP allowed" \
            || echo "   ! CSF: could not add $PEER_IP — add it manually"
    fi
    csf -r >/dev/null 2>&1
    echo "   CSF reloaded"
else
    echo "   ! CSF not found — allow $PEER_IP in the firewall manually"
fi

# 5) SSH — allow root login (the __OTHER__ connects here as root)
CFG="/etc/ssh/sshd_config"
if [ -f "$CFG" ]; then
    [ -f "$CFG.bak" ] || cp -p "$CFG" "$CFG.bak"
    for K in PermitRootLogin PasswordAuthentication; do
        if grep -Eqi "^[[:space:]]*$K[[:space:]]" "$CFG"; then
            sed -i -E "s/^[[:space:]]*$K[[:space:]].*/$K yes/I" "$CFG"
        else
            echo "$K yes" >> "$CFG"
        fi
    done
    if grep -Eqi '^[[:space:]]*AllowUsers[[:space:]]' "$CFG"; then
        grep -Eqi '^[[:space:]]*AllowUsers[[:space:]].*\broot\b' "$CFG" || \
            sed -i -E 's/^([[:space:]]*AllowUsers[[:space:]].*)$/\1 root/I' "$CFG"
    else
        echo "AllowUsers root" >> "$CFG"
    fi
    SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
    if "$SSHD_BIN" -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo "   SSH: root login enabled, sshd restarted (backup: $CFG.bak)"
    else
        cp -f "$CFG.bak" "$CFG"
        echo "   ! sshd config test failed — backup restored, NOT restarted"
    fi
else
    echo "   ! /etc/ssh/sshd_config not found — enable root SSH manually"
fi

echo
echo "════════════════════════════════════════════════"
echo "  DONE — __ROLE__ is ready for Magic Move."
echo "  Now go back to the __OTHER_UC__ and press Enter there."
echo "════════════════════════════════════════════════"
MMBLOCK
    sed -i -e "s/__PEER_IP__/$2/g" -e "s/__ROLE_UC__/${role^^}/g" -e "s/__OTHER_UC__/${other^^}/g" \
           -e "s/__ROLE__/$role/g" -e "s/__OTHER__/$other/g" "$3"
    chmod +x "$3" 2>/dev/null
    log "PREP $role block written: $3 ($other IP: $2)"
}

print_destination_block() {   # $1 = source IP   $2 = wait for Enter? (yes|no)
    print_prep_block destination "$1" "$2"
}

print_prep_block() {   # $1 = role that runs it   $2 = this server's IP   $3 = wait for Enter? (yes|no)
    local role="$1" myip="$2" wait="$3" block="$OUT_DIR/$1-prep.sh"
    write_prep_block "$role" "$myip" "$block"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Run this on the ${role^^}${RESET} (paste the whole block there, press Enter):"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    cat "$block"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  Also saved for scp: ${YELLOW}$block${RESET}"
    if [ "$wait" = "yes" ] && [ -t 0 ]; then
        echo
        read -r -p "Press Enter here once the $role block has finished... " _
    fi
}

# Sync-flow hook: --skip-prep skips, --prep forces, otherwise ask (default yes).
maybe_prep_source() {   # $1 = destination IP (peer)
    if [ "$PREP" = "skip" ]; then
        info "Skipping migration prep (--skip-prep)"
        return 0
    fi
    if [ -z "$PREP" ]; then
        if [ ! -t 0 ]; then
            info "Non-interactive run: migration prep skipped (use --prep to force it)."
            return 0
        fi
        local ans
        echo
        read -r -p "Run migration prep on this source & print the destination block first? [Y/n]: " ans
        case "$ans" in [Nn]*) info "Prep skipped — make sure both servers are prepared."; return 0 ;; esac
    fi
    run_prep source "$1" || return 1
    local srcip
    srcip=$(prep_source_ip) || { error "Could not determine this server's IP for the destination block."; return 1; }
    print_destination_block "$srcip" yes
}

# ════════════════════════════════════════════════════════════
#   HOME SYNC (rsync)
# ════════════════════════════════════════════════════════════
# Copies exactly the selected accounts instead of all of /home behind a growing
# exclude list: ONE rsync of the home root, with a filter that lets only those
# users' directories through (+ /<user>/*** ... - /*), .cagefs and all.
# Before it starts, one SSH call asks the destination which of the users exist
# and where their home is. A user missing there — or homed under a different
# path, which a single rsync cannot map — is left out (copied onto a missing
# account, the files would land with raw UIDs) and listed in sync-skipped.csv.
# The SSH master connection is opened here, in the foreground, so a password or
# host-key prompt is answered once; the copy then runs in a detached screen
# (it survives a dropped session) and reuses that connection.
ask_sync_target() {
    if [ -z "$SYNC_IP" ]; then read -r -p "Destination server IP: " SYNC_IP || true; fi
    [ -n "$SYNC_IP" ] || { error "No destination IP given."; return 1; }
    [[ "$SYNC_IP" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || { error "Invalid destination IP/host: $SYNC_IP"; return 1; }
    if [ -z "$SYNC_PORT" ]; then
        read -r -p "Destination SSH port [22]: " SYNC_PORT || true
        SYNC_PORT="${SYNC_PORT:-22}"
    fi
    [[ "$SYNC_PORT" =~ ^[0-9]+$ ]] && [ "$SYNC_PORT" -ge 1 ] && [ "$SYNC_PORT" -le 65535 ] \
        || { error "Invalid SSH port: $SYNC_PORT"; return 1; }
}

# The runner is what screen executes; it is written next to the results so the
# exact command that ran stays inspectable.
write_sync_runner() {   # $1 = path
    cat > "$1" <<'RUNNER'
#!/bin/bash
# Generated by magic-move.sh — the home sync, run inside screen.
root="$1" ip="$2" port="$3" sock="$4" filter="$5" log="$6" skipped="$7" n="$8" nskip="$9"
exec > >(tee -a "$log") 2>&1
echo "Magic Move — home sync   $(date +'%F %T')"
echo "  $n account(s): $root/  ->  root@$ip:$root/  (ssh port $port)"
echo
start=$SECONDS
rsync -avzPHh --stats \
      --rsh="ssh -p $port -o ControlPath=$sock -o ServerAliveInterval=30" \
      --filter="merge $filter" \
      "$root/" "root@$ip:$root/"
rc=$?
ssh -p "$port" -o ControlPath="$sock" -O exit "root@$ip" >/dev/null 2>&1
s=$((SECONDS-start))
echo
echo "════════════════════════════════════════════════"
case $rc in
    0)  echo "  Result   : OK" ;;
    24) echo "  Result   : OK (some files vanished mid-copy — normal on live sites)" ;;
    *)  echo "  Result   : FAILED (rsync exit $rc)" ;;
esac
echo "  Accounts : $n"
[ "$nskip" -gt 0 ] && echo "  Skipped  : $nskip (not copied) — see $skipped"
printf '  Duration : %dh %02dm %02ds\n' $((s/3600)) $(((s%3600)/60)) $((s%60))
echo "  Log      : $log"
echo "════════════════════════════════════════════════"
read -r -p "Press Enter to close this screen... " _
RUNNER
}

start_sync() {   # $1 = rows (owner<TAB>user<TAB>domain)
    local t
    for t in rsync ssh screen getent; do
        command -v "$t" >/dev/null 2>&1 || { error "$t not found — install it first (yum/apt install $t)."; return 1; }
    done
    ask_sync_target || return 1

    # Prep before anything moves: SecCheck/scanners off here, the destination
    # whitelisted here, and the destination block printed + waited for.
    maybe_prep_source "$SYNC_IP" || return 1

    local dir stamp skipped filter slog runner sock session
    dir=$(cd "$OUT_DIR" && pwd) || return 1
    stamp=$(date +%F_%H-%M-%S)
    skipped="$dir/sync-skipped.csv"; filter="$dir/sync-filter.txt"
    slog="$dir/sync-$stamp.log";     runner="$dir/sync-run.sh"
    sock="/tmp/magic-move-ssh-$$"
    session="magic-move-sync-$(date +%H%M%S)"
    local rsh="ssh -p $SYNC_PORT -o ControlPath=$sock -o ServerAliveInterval=30"

    # Local side: each user needs a real home, and one rsync means one root —
    # the root most users live under wins (normally /home).
    local -A seen=() lhome=() rhome=()
    local cand=() keep=() user home root n_skip=0
    echo "user,reason" > "$skipped"
    while IFS=$'\t' read -r _ user _; do
        [ -n "$user" ] || continue
        [ -n "${seen[$user]:-}" ] && continue; seen[$user]=1
        if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "$user,invalid username" >> "$skipped"; n_skip=$((n_skip+1)); continue
        fi
        home=$(getent passwd "$user" | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ] || [ "${home##*/}" != "$user" ]; then
            echo "$user,no local home${home:+ ($home)}" >> "$skipped"; n_skip=$((n_skip+1)); continue
        fi
        lhome[$user]="$home"; cand+=("$user")
    done <<< "$1"
    [ "${#cand[@]}" -gt 0 ] || { error "No account has a usable home directory — see $skipped"; return 1; }
    root=$(for user in "${cand[@]}"; do dirname "${lhome[$user]}"; done | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')

    # One master connection; its fds are detached so it never holds the log tee open.
    info "Connecting to root@$SYNC_IP:$SYNC_PORT (enter the password if asked)..."
    ssh -p "$SYNC_PORT" -o ControlMaster=yes -o ControlPath="$sock" -o ControlPersist=yes \
        -o ServerAliveInterval=30 -fN "root@$SYNC_IP" </dev/null >/dev/null 2>&1 \
        || { error "Cannot connect to root@$SYNC_IP:$SYNC_PORT."; return 1; }
    local close_master="ssh -p $SYNC_PORT -o ControlPath=$sock -O exit root@$SYNC_IP"

    # Destination side: one call reports every user's home there (empty = missing).
    local out u h
    out=$(printf '%s\n' "${cand[@]}" | $rsh "root@$SYNC_IP" \
        'while read -r u; do printf "%s\t%s\n" "$u" "$(getent passwd "$u" | cut -d: -f6)"; done') \
        || { error "Could not query accounts on the destination."; $close_master >/dev/null 2>&1; return 1; }
    while IFS=$'\t' read -r u h; do [ -n "$u" ] && rhome[$u]="$h"; done <<< "$out"

    : > "$filter"
    for user in "${cand[@]}"; do
        h="${rhome[$user]:-}"
        if [ "$(dirname "${lhome[$user]}")" != "$root" ]; then
            echo "$user,home under $(dirname "${lhome[$user]}") not $root (sync it separately)" >> "$skipped"
        elif [ -z "$h" ]; then
            echo "$user,missing on destination" >> "$skipped"
        elif [ "$h" != "${lhome[$user]}" ]; then
            echo "$user,different home on destination ($h)" >> "$skipped"
        else
            keep+=("$user"); echo "+ /$user/***" >> "$filter"; continue
        fi
        n_skip=$((n_skip+1))
    done
    echo "- /*" >> "$filter"

    [ "$n_skip" -gt 0 ] && error "$n_skip account(s) will NOT be synced — see $skipped"
    if [ "${#keep[@]}" -eq 0 ]; then
        error "Nothing to sync."; $close_master >/dev/null 2>&1; return 1
    fi

    write_sync_runner "$runner"
    screen -dmS "$session" bash "$runner" "$root" "$SYNC_IP" "$SYNC_PORT" "$sock" \
        "$filter" "$slog" "$skipped" "${#keep[@]}" "$n_skip" </dev/null >/dev/null 2>&1
    sleep 1
    if ! screen -ls 2>/dev/null | grep -q "[0-9]\.$session[[:space:]]"; then
        error "Could not start the screen session."; $close_master >/dev/null 2>&1; return 1
    fi

    success "Sync started: ${#keep[@]} account(s) -> root@$SYNC_IP:$root/ (port $SYNC_PORT)"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Attach   : ${YELLOW}screen -r $session${RESET}"
    echo -e "  Detach   : Ctrl+A then D"
    echo -e "  Sync log : $slog"
    [ "$n_skip" -gt 0 ] && echo -e "  ${YELLOW}Skipped${RESET}  : $n_skip — $skipped"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    log "SYNC started: ${#keep[@]} accounts -> root@$SYNC_IP:$SYNC_PORT $root/, skipped=$n_skip, screen=$session, log=$slog"
}

# Source pass hook: --with-sync / --no-sync answer up front, otherwise ask.
maybe_sync() {   # $1 = rows
    [ "$SYNC" = "no" ] && return 0
    if [ -z "$SYNC" ]; then
        [ -t 0 ] || return 0
        local n ans
        n=$(printf '%s\n' "$1" | grep -c .)
        echo
        read -r -p "rsync these $n account(s)' home directories to the destination now? [y/N]: " ans
        case "$ans" in [Yy]*) ;; *) return 0 ;; esac
    fi
    start_sync "$1"
}

# ════════════════════════════════════════════════════════════
#   cPANEL TRANSFER TOOL (the destination pulls from the source)
# ════════════════════════════════════════════════════════════
# WHM's own Transfer Tool, driven through WHM API 1 on THIS (destination) server:
#   create_remote_root_transfer_session -> analyze + retrieve the source ->
#   one enqueue_transfer_item per feature list / package / account ->
#   start_transfer_session -> watch get_transfer_session_state.
# The session is an ordinary WHM one, so it also shows (and can be aborted) in
# WHM » Transfers » Transfer Tool. Only the users listed in migration.csv go,
# root / staff / system names never do, and every conflict is a question.
# The pull connects to the SOURCE as root over SSH, so the source must be
# prepared first (root SSH open, this server whitelisted) — offered below.

WHMAPI=/usr/local/cpanel/bin/whmapi1
WHM_JSON=""          # file holding the last whmapi1 answer
WHM_REASON=""        # its metadata.reason
XFER_SID=""          # the transfer session id
XFER_STATE=""        # COMPLETED | FAILED | ABORTED | DETACHED | ...
XFER_PASS=""         # source root password / key passphrase — never logged,
XFER_KEYPASS=""      # never echoed, wiped when the flow ends

# Names that are never a hosting account to move, whatever the CSV says.
XFER_RESERVED="root system nobody staff wheel users cpanel whm whmxfer
virtfs mailman mailnull mysql postgres named dovecot dovenull exim apache httpd
nginx ftp bin daemon adm lp sync shutdown halt mail operator games gopher sshd
rpc rpcuser nfsnobody tss polkitd chrony dbus clamav cxs csf lsadm redis
memcached postfix tomcat cpses"

# cPanel's own perl always has JSON::PP; the system one does on any modern box.
mm_perl() {
    if [ -x /usr/local/cpanel/3rdparty/bin/perl ]; then /usr/local/cpanel/3rdparty/bin/perl "$@"; else perl "$@"; fi
}

# Run perl code against a JSON file; the decoded document is $d. Fails (and
# prints nothing) when the file is not JSON.
json_q() {   # $1 = file  $2 = perl code
    mm_perl -MJSON::PP -e 'local $/; open(my $f, "<", $ARGV[0]) or exit 1; my $t = <$f>;
        our $d = eval { JSON::PP->new->allow_nonref->decode($t) }; exit 1 unless ref $d;
        sub sv { my $v = shift; defined $v && !ref $v ? $v : "" }
        eval $ARGV[1]; exit 1 if $@;' "$1" "$2" 2>/dev/null
}

whm_ok() {
    WHM_REASON=$(json_q "$WHM_JSON" 'print sv($d->{metadata}{reason})')
    [ "$(json_q "$WHM_JSON" 'print sv($d->{metadata}{result})')" = "1" ] && return 0
    [ -n "$WHM_REASON" ] || WHM_REASON="no valid answer from whmapi1"
    return 1
}

whm_call() {   # $1 = function, then key=value ... (no secrets here)
    local fn="$1"; shift
    "$WHMAPI" --output=json "$fn" "$@" > "$WHM_JSON" 2>/dev/null
    whm_ok
}

uri_enc() {    # stdin -> URI-encoded (the whmapi1 CLI takes key=value pairs URI-encoded)
    mm_perl -pe 's/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge'
}

# Numbered question; echoes the chosen number.
ask_num() {   # $1 = prompt  $2 = default  $3 = highest number
    local ans
    while :; do
        read -r -p "$1 [$2]: " ans || return 1
        ans="${ans:-$2}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$3" ]; then
            printf '%s' "$ans"; return 0
        fi
        echo "  Please enter a number from 1 to $3." >&2
    done
}
ask_yn() {    # $1 = prompt  $2 = default (y|n) -> 0 = yes
    local ans d="$2"
    read -r -p "$1 [$([ "$d" = y ] && echo Y/n || echo y/N)]: " ans
    case "${ans:-$d}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# The session is created with the secret on STDIN (--input=json), so it never
# shows up in the process list. An older whmapi1 without --input=json gets the
# same call as arguments — the secret URI-encoded, visible to root in ps for
# the moment the call runs.
xfer_create_session() {   # key=value ... (non-secret session options)
    local -a a=("$@") sec=()
    MM_PASS="$XFER_PASS" MM_KEYPASS="$XFER_KEYPASS" mm_perl -MJSON::PP -e '
        my %h; for (@ARGV) { my ($k, $v) = split /=/, $_, 2; $h{$k} = $v =~ /^\d+$/ ? $v + 0 : $v }
        $h{password}          = $ENV{MM_PASS}    if length($ENV{MM_PASS}    // "");
        $h{sshkey_passphrase} = $ENV{MM_KEYPASS} if length($ENV{MM_KEYPASS} // "");
        print JSON::PP->new->encode(\%h);' "${a[@]}" \
        | "$WHMAPI" --input=json --output=json create_remote_root_transfer_session > "$WHM_JSON" 2>/dev/null
    if ! whm_ok; then
        if json_q "$WHM_JSON" 'print 1' >/dev/null && \
           ! [[ "$WHM_REASON" =~ (issing|equired|parameter|argument|nput) ]]; then
            return 1                # a real answer (bad host, ...), not an input-format problem
        fi
        [ -n "$XFER_PASS" ]    && sec+=("password=$(printf '%s' "$XFER_PASS" | uri_enc)")
        [ -n "$XFER_KEYPASS" ] && sec+=("sshkey_passphrase=$(printf '%s' "$XFER_KEYPASS" | uri_enc)")
        "$WHMAPI" --output=json create_remote_root_transfer_session "${a[@]}" ${sec[@]+"${sec[@]}"} > "$WHM_JSON" 2>/dev/null
        whm_ok || return 1
    fi
    XFER_SID=$(json_q "$WHM_JSON" 'print sv($d->{data}{transfer_session_id})')
    [ -n "$XFER_SID" ] || { WHM_REASON="no session id in the answer"; return 1; }
}

xfer_reach() {   # $1 host  $2 port -> 0 when the TCP port answers
    timeout 8 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# Why a CSV user must not be transferred (empty = fine).
xfer_exclude_reason() {   # $1 = user  $2 = UID_MIN
    local u="$1" r uid
    for r in $XFER_RESERVED; do
        [ "$u" = "$r" ] && { printf 'root / staff / system account'; return; }
    done
    case "$u" in
        cpanel*|cpses_*|systemd-*) printf 'root / staff / system account'; return ;;
    esac
    [[ "$u" =~ ^[a-z][a-z0-9]{0,15}$ ]] || { printf 'not a valid cPanel username'; return; }
    if [ ! -f "/var/cpanel/users/$u" ]; then
        uid=$(getent passwd "$u" | cut -d: -f3)
        [ -n "$uid" ] && [ "$uid" -lt "$2" ] && { printf 'system user on this server (uid %s)' "$uid"; return; }
    fi
}

# Watch the session until it ends; Ctrl+C stops watching, never the transfer.
xfer_watch() {   # $1 = session id
    local sid="$1" st="" t0=$SECONDS stop=0 k
    echo -e "  Watching the session — ${YELLOW}Ctrl+C stops watching only${RESET}; the transfer keeps running in WHM."
    trap 'stop=1' INT
    while [ "$stop" = 0 ]; do
        if whm_call get_transfer_session_state transfer_session_id="$sid"; then
            st=$(json_q "$WHM_JSON" 'print sv($d->{data}{state_name})')
        fi
        printf '\r  State: %-22s elapsed %-14s' "${st:-?}" "$(fmt_duration $((SECONDS-t0)))"
        case "$st" in COMPLETED|FAILED|ABORTED) break ;; esac
        for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            [ "$stop" = 1 ] && break
            sleep 1
        done
    done
    trap - INT
    echo
    XFER_STATE="${st:-unknown}"
    [ "$stop" = 1 ] && XFER_STATE="DETACHED"
}

# The flow. $1 = rows "user<TAB>domain" from migration.csv.
# Returns 0 = transfer finished (COMPLETED), 1 = not done / failed / cancelled,
# 2 = still running (stopped watching).
run_transfer() {
    [ "$(id -u)" = 0 ] || { error "The Transfer Tool must run as root."; return 1; }
    [ -x "$WHMAPI" ]   || { error "whmapi1 not found — is this a cPanel server?"; return 1; }
    mm_perl -MJSON::PP -e 1 2>/dev/null || { error "perl JSON::PP is missing — cannot read WHM API answers."; return 1; }
    [ -t 0 ] || { error "The Transfer Tool flow asks questions — run it in an interactive terminal."; return 1; }
    WHM_JSON=$(mktemp) || { error "Could not create a temp file."; return 1; }
    local rc
    run_transfer_inner "$1"; rc=$?
    XFER_PASS=""; XFER_KEYPASS=""
    rm -f "$WHM_JSON"
    return "$rc"
}

run_transfer_inner() {
    local plan="$OUT_DIR/transfer-plan.csv" ans n i
    local -A dom=() seen=() act=() luser=() resmode=() owner=() size=() plan_of=() is_res=() src_has=()
    local -a cand=() keep=()
    local user domain why uidmin

    echo
    echo -e "${CYAN}════════ cPanel Transfer Tool ════════${RESET}"
    echo "  Pulls the accounts from the source into this server with WHM's own"
    echo "  transfer system. Only the users in migration.csv are considered."
    echo

    # ---- 1) the users: the CSV's, minus anything that is not a hosting account
    uidmin=$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null)
    [[ "$uidmin" =~ ^[0-9]+$ ]] || uidmin=1000
    echo "user,domain,action,local_user,reseller,result,note" > "$plan"
    n=0
    while IFS=$'\t' read -r user domain; do
        [ -n "$user" ] || continue
        [ -n "${seen[$user]:-}" ] && continue; seen[$user]=1
        why=$(xfer_exclude_reason "$user" "$uidmin")
        if [ -n "$why" ]; then
            [ "$n" = 0 ] && echo -e "  ${YELLOW}Left out (never transferred):${RESET}"
            printf '    %-18s %-32s %s\n' "$user" "$domain" "$why"
            echo "$user,$domain,excluded,,,,$why" >> "$plan"
            n=$((n+1)); continue
        fi
        cand+=("$user"); dom[$user]="$domain"
    done <<< "$1"
    [ "${#cand[@]}" -gt 0 ] || { error "No transferable user in the CSV."; return 1; }

    echo -e "  ${GREEN}${#cand[@]} user(s) from the CSV:${RESET}"
    printf '%s\n' "${cand[*]}" | fold -s -w 74 | sed 's/^/    /'
    echo
    echo "  1) all ${#cand[@]}"
    echo "  2) all except some"
    echo "  3) only some"
    echo "  4) cancel the transfer"
    ans=$(ask_num "Which users go?" 1 4) || return 1
    case "$ans" in
        2|3)
            local list u; local -A pick=()
            read -r -p "Users ($([ "$ans" = 2 ] && echo to LEAVE OUT || echo to TAKE), space/comma separated): " list
            for u in ${list//,/ }; do pick[$u]=1; done
            keep=()
            for u in "${cand[@]}"; do
                if { [ "$ans" = 2 ] && [ -z "${pick[$u]:-}" ]; } || { [ "$ans" = 3 ] && [ -n "${pick[$u]:-}" ]; }; then
                    keep+=("$u")
                else
                    echo "$u,${dom[$u]},excluded,,,,left out by the operator" >> "$plan"
                fi
            done
            cand=(${keep[@]+"${keep[@]}"})
            [ "${#cand[@]}" -gt 0 ] || { error "No user left to transfer."; return 1; } ;;
        4) info "Transfer cancelled."; return 1 ;;
    esac

    # ---- 2) where the source is (the source report gives the defaults)
    local host="${XFER_SRC_IP:-}" port="${XFER_SRC_PORT:-}"
    if [ -z "$host" ]; then
        read -r -p "Source server IP${SRC_IP:+ [$SRC_IP]}: " host
        host="${host:-$SRC_IP}"
    fi
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || { error "Invalid source IP/host: ${host:-<empty>}"; return 1; }
    if [ -z "$port" ]; then
        read -r -p "Source SSH port [${SRC_SSH_PORT:-22}]: " port
        port="${port:-${SRC_SSH_PORT:-22}}"
    fi
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { error "Invalid SSH port: $port"; return 1; }

    # ---- 3) prep: the pull only works on prepared servers
    local myip
    if [ "$PREP" = "skip" ]; then
        info "Prep skipped (--skip-prep): both servers are taken as prepared."
    else
        if [ "$PREP" = "yes" ]; then ans=2; else
            echo
            echo "  The pull connects to the SOURCE as root over SSH, so both servers must be"
            echo "  prepared first: SecCheck + scanners off, this server's IP whitelisted on the"
            echo "  source (CSF / hosts.deny), and root SSH login open on the source."
            echo "  1) already prepared — go on"
            echo "  2) prep now: this destination here + a ready-to-paste block for the source"
            echo "  3) cancel the transfer"
            ans=$(ask_num "Prep" 2 3) || return 1
        fi
        case "$ans" in
            2)  run_prep destination "$host" no || return 1
                myip=$(prep_source_ip source) || { error "Could not determine this server's IP for the source block."; return 1; }
                print_prep_block source "$myip" yes ;;
            3)  info "Transfer cancelled."; return 1 ;;
        esac
    fi
    while ! xfer_reach "$host" "$port"; do
        error "Cannot reach $host:$port over TCP (firewall / SSH port / prep?)."
        echo "  1) try again   2) go on anyway   3) cancel the transfer"
        ans=$(ask_num "Choice" 1 3) || return 1
        case "$ans" in 2) break ;; 3) info "Transfer cancelled."; return 1 ;; esac
    done

    # ---- 4) how to log in to the source as root
    local auth key="" keys=() f
    for f in /root/.ssh/*.pub; do
        [ -f "$f" ] && [ -f "${f%.pub}" ] && keys+=("$(basename "${f%.pub}")")
    done
    auth=1
    if [ "${#keys[@]}" -gt 0 ]; then
        echo "  Log in to the source as root with:"
        echo "  1) root's password"
        echo "  2) an SSH key of this server's root (${keys[*]})"
        auth=$(ask_num "Authentication" 1 2) || return 1
    fi
    if [ "$auth" = 2 ]; then
        if [ "${#keys[@]}" -gt 1 ]; then
            for i in "${!keys[@]}"; do printf '    %d) %s\n' "$((i+1))" "${keys[$i]}"; done
            i=$(ask_num "Key" 1 "${#keys[@]}") || return 1
            key="${keys[$((i-1))]}"
        else
            key="${keys[0]}"
        fi
        read -r -s -p "Passphrase of $key (Enter if none): " XFER_KEYPASS; echo
    else
        read -r -s -p "Root password of the source ($host): " XFER_PASS; echo
    fi

    # ---- 5) session options (WHM asks the same on its Transfer Tool page)
    echo
    local o_comp=1 o_low=0 o_tt=2 o_rt=2 o_bak=0
    ask_yn "Compress the data in transit?" y || o_comp=0
    ask_yn "Package on the source at low priority (gentler on its live sites, slower)?" n && o_low=1
    read -r -p "Transfer threads [2]: " ans; [[ "${ans:-2}" =~ ^[1-9][0-9]?$ ]] && o_tt="${ans:-2}"
    read -r -p "Restore threads [2]: " ans;  [[ "${ans:-2}" =~ ^[1-9][0-9]?$ ]] && o_rt="${ans:-2}"
    ask_yn "Use the source's existing account backups when under 24h old (instead of packaging fresh)?" n && o_bak=1

    # ---- 6) session + source check (credentials, versions, accounts)
    local -a sopt=(host="$host" port="$port" user=root comm_transport=ssh
                   compressed="$o_comp" low_priority="$o_low" transfer_threads="$o_tt"
                   restore_threads="$o_rt" use_backups="$o_bak" unencrypted=0
                   unrestricted_restore=0 enable_custom_pkgacct=0 copy_reseller_privs=1)
    [ -n "$key" ] && sopt+=(sshkey_name="$key")
    local tries=0
    while :; do
        if [ -z "$key" ] && [ -z "$XFER_PASS" ]; then
            read -r -s -p "Root password of the source ($host): " XFER_PASS; echo
        fi
        info "Creating the transfer session..."
        if xfer_create_session "${sopt[@]}"; then
            info "Session $XFER_SID — checking the source (login, versions, accounts)..."
            whm_call analyze_transfer_session_remote transfer_session_id="$XFER_SID" && break
            error "Source check failed: $WHM_REASON"
        else
            error "Could not create the session: $WHM_REASON"
        fi
        log "TRANSFER session setup failed: $WHM_REASON"
        tries=$((tries+1))
        [ "$tries" -ge 3 ] && { error "Giving up after 3 tries."; return 1; }
        echo "  1) try again with a new password/passphrase   2) try again as is   3) cancel"
        ans=$(ask_num "Choice" 1 3) || return 1
        case "$ans" in
            1) XFER_PASS=""
               [ -n "$key" ] && { read -r -s -p "Passphrase of $key (Enter if none): " XFER_KEYPASS; echo; } ;;
            3) info "Transfer cancelled."; return 1 ;;
        esac
    done
    log "TRANSFER session $XFER_SID created for root@$host:$port"

    # ---- 7) what the source has
    whm_call retrieve_transfer_session_remote_analysis transfer_session_id="$XFER_SID" \
        || { error "Could not read the source analysis: $WHM_REASON"; return 1; }
    install -m 600 "$WHM_JSON" "$OUT_DIR/transfer-analysis.json" 2>/dev/null
    local facts rver="" rhost="" rlive=0 nip=0 shared_db=0 tag a b c d e
    local -a srcpkgs=() resellers=()
    local -A pkg_fl=()
    facts=$(json_q "$WHM_JSON" '
        my $x = $d->{data} || {}; my $r = $x->{remote} || {}; my $l = $x->{local} || {};
        my $S = "\x1f";
        print "V$S", sv($r->{version}), "\n", "H$S", sv($r->{hostname}), "\n";
        print "L$S", sv($r->{supports_live_transfers}) || 0, "\n";
        print "S$S", sv(($x->{config} || {})->{shared_mysql_server}) || 0, "\n";
        my $ips = $l->{available_ips}; print "I$S", (ref $ips eq "ARRAY" ? scalar(@$ips) : 0), "\n";
        if (ref $r->{resellers} eq "HASH") { print "R$S$_\n" for grep { $_ ne "root" } sort keys %{ $r->{resellers} } }
        my $it = $x->{items} || {};
        my $acc = $it->{accounts}; my @acc;
        if (ref $acc eq "ARRAY") { @acc = @$acc }
        elsif (ref $acc eq "HASH") { @acc = map { my $h = $acc->{$_}; ref $h eq "HASH" ? { user => $_, %$h } : () } keys %$acc }
        for my $ac (@acc) {
            next unless ref $ac eq "HASH";
            my $u = sv($ac->{user}) || sv($ac->{username}); next if $u eq "";
            my $sz = sv($ac->{size}); $sz = "" unless $sz =~ /^\d+$/;
            print join($S, "A", $u, sv($ac->{owner}), sv($ac->{domain}), $sz, sv($ac->{plan}) || sv($ac->{package})), "\n";
        }
        my $pk = $it->{packages};
        for my $p (ref $pk eq "ARRAY" ? @$pk : ()) {
            next unless ref $p eq "HASH";
            my $n = sv($p->{name}) || sv($p->{package}); next if $n eq "";
            print join($S, "P", $n, sv($p->{featurelist}) || sv($p->{FEATURELIST})), "\n";
        }')
    while IFS=$'\x1f' read -r tag a b c d e; do
        case "$tag" in
            V) rver="$a" ;;  H) rhost="$a" ;;  L) rlive="$a" ;;  S) shared_db="$a" ;;  I) nip="$a" ;;
            R) is_res[$a]=1; resellers+=("$a") ;;
            A) src_has[$a]=1; owner[$a]="$b"; [ -n "$c" ] && [ -z "${dom[$a]:-}" ] && dom[$a]="$c"
               size[$a]="$d"; plan_of[$a]="$e" ;;
            P) srcpkgs+=("$a"); pkg_fl[$a]="$b" ;;
        esac
    done <<< "$facts"
    info "Source: cPanel ${rver:-?}${rhost:+ · $rhost} · ${#src_has[@]} account(s) · ${#resellers[@]} reseller(s)"
    log "TRANSFER source cPanel ${rver:-?} host=${rhost:-?} accounts=${#src_has[@]} resellers=${#resellers[@]}"

    # Users the source doesn't have can't be pulled (only checkable when the
    # analysis listed the accounts).
    if [ "${#src_has[@]}" -gt 0 ]; then
        keep=()
        for user in "${cand[@]}"; do
            if [ -n "${src_has[$user]:-}" ]; then keep+=("$user"); else
                echo -e "  ${YELLOW}$user${RESET}: not an account on the source — left out"
                echo "$user,${dom[$user]},excluded,,,,not on the source" >> "$plan"
            fi
        done
        cand=(${keep[@]+"${keep[@]}"})
        [ "${#cand[@]}" -gt 0 ] || { error "None of the users exists on the source."; return 1; }
    else
        info "The source did not list its accounts — each user is checked during the transfer."
    fi

    # ---- 8) owners: a reseller that owns one of these accounts but is neither in
    # the transfer nor on this server would leave the account owned by root here.
    local -A incand=() asked_owner=()
    for user in "${cand[@]}"; do incand[$user]=1; done
    for user in "${cand[@]}"; do
        local o="${owner[$user]:-}"
        [ -n "$o" ] && [ "$o" != "root" ] || continue
        [ -n "${incand[$o]:-}" ] || [ -f "/var/cpanel/users/$o" ] || [ -n "${asked_owner[$o]:-}" ] && continue
        asked_owner[$o]=1
        echo
        echo -e "  ${YELLOW}$user${RESET} is owned by reseller ${YELLOW}$o${RESET} on the source; $o is not in this"
        echo "  transfer and does not exist here."
        echo "  1) add $o to the transfer (its accounts keep their owner)"
        echo "  2) go on — $user (and any other account of $o) will be owned by root here"
        ans=$(ask_num "Owner $o" 1 2) || return 1
        if [ "$ans" = 1 ]; then
            if [ -n "$(xfer_exclude_reason "$o" "$uidmin")" ]; then
                error "$o cannot be transferred ($(xfer_exclude_reason "$o" "$uidmin"))."
            else
                cand=("$o" "${cand[@]}"); incand[$o]=1
                [ -n "${dom[$o]:-}" ] || dom[$o]=""
            fi
        fi
    done

    # Resellers first, so their accounts find their owner already there.
    keep=()
    for user in "${cand[@]}"; do [ -n "${is_res[$user]:-}" ] && keep+=("$user"); done
    for user in "${cand[@]}"; do [ -z "${is_res[$user]:-}" ] && keep+=("$user"); done
    cand=("${keep[@]}")

    # ---- 9) one by one: conflicts here, reseller privileges
    local conflict_all="" res_all="" owdbs="" lmain downer cf
    for user in "${cand[@]}"; do
        domain="${dom[$user]:-}"; lmain=""
        act[$user]="new"; luser[$user]="$user"; resmode[$user]="-"

        cf=""
        if [ -f "/var/cpanel/users/$user" ]; then
            lmain=$(awk -F= '$1=="DNS"{print $2; exit}' "/var/cpanel/users/$user")
            cf="account '$user' already exists here${lmain:+ (main domain: $lmain)}"
        fi
        downer=""
        [ -n "$domain" ] && downer=$(awk -F':[[:space:]]*' -v d="$domain" '$1==d{print $2; exit}' /etc/userdomains 2>/dev/null)
        if [ -n "$downer" ] && [ "$downer" != "$user" ] && [ "$downer" != "nobody" ]; then
            cf="${cf:+$cf; }domain $domain already belongs to account '$downer' here"
        fi

        if [ -n "$cf" ]; then
            if [ -n "$conflict_all" ]; then
                ans="$conflict_all"
                local lbl="ignore"
                [ "$ans" = 2 ] && lbl="overwrite"
                [ "$ans" = 3 ] && lbl="overwrite with delete"
                echo -e "  ${YELLOW}$user${RESET} (${domain:-?}): $cf -> $lbl (same answer as before)"
            else
                echo
                echo -e "  ${YELLOW}Conflict — $user${RESET} (${domain:-?}): $cf"
                echo "  1) ignore                 — skip $user, leave what is here untouched"
                echo "  2) overwrite              — restore over it (settings, files and databases are replaced)"
                echo "  3) overwrite with delete  — DELETE all of the existing account's files here first, then restore"
                local maxc=3
                if [ -f "/var/cpanel/users/$user" ] && { [ -z "$downer" ] || [ "$downer" = "$user" ]; }; then
                    echo "  4) restore under another username here (the existing '$user' stays as it is)"
                    maxc=4
                    # A same-named account here usually owns the same domain too; a
                    # second account cannot hold it, so renaming only helps when it doesn't.
                    if [ -n "$lmain" ] && [ "$lmain" = "$domain" ]; then
                        echo "     (note: '$user' here already holds $domain — a renamed copy could not get that domain)"
                    fi
                fi
                if [ -n "$downer" ] && [ "$downer" != "$user" ] && [ "$downer" != "nobody" ]; then
                    echo "     (note: '$downer' is NOT deleted by either overwrite — the restore ignores the"
                    echo "      conflict, but $domain stays with '$downer' until you remove it there)"
                fi
                ans=$(ask_num "$user" 1 "$maxc") || return 1
                if [ "$ans" = 4 ]; then
                    local nu=""
                    while :; do
                        read -r -p "New username here for $user: " nu
                        if [[ ! "$nu" =~ ^[a-z][a-z0-9]{0,15}$ ]]; then echo "  Not a valid cPanel username."
                        elif [ -f "/var/cpanel/users/$nu" ] || getent passwd "$nu" >/dev/null || [ -n "${incand[$nu]:-}" ]; then echo "  '$nu' is already taken."
                        else break; fi
                    done
                    luser[$user]="$nu"
                elif ask_yn "  Same answer for every remaining conflict?" n; then
                    conflict_all="$ans"
                    if [ "$ans" = 3 ]; then
                        read -r -p "  Type DELETE to confirm 'overwrite with delete' for all of them: " cf
                        [ "$cf" = "DELETE" ] || { conflict_all=""; ans=1; info "Not confirmed — $user is ignored."; }
                    fi
                fi
                if [ "$ans" = 3 ] && [ "$conflict_all" != 3 ]; then
                    read -r -p "  Type '$user' to confirm deleting the existing data here: " cf
                    [ "$cf" = "$user" ] || { ans=1; info "Not confirmed — $user is ignored."; }
                fi
            fi
            case "$ans" in
                1) act[$user]="skip" ;;
                2) act[$user]="overwrite" ;;
                3) act[$user]="overwrite-delete" ;;
                4) act[$user]="rename" ;;
            esac
            if { [ "$ans" = 2 ] || [ "$ans" = 3 ]; } && [ -z "$owdbs" ]; then
                ask_yn "  When overwriting, also replace the existing databases and DB users the account owns?" y \
                    && owdbs=1 || owdbs=0
            fi
        fi
        [ "${act[$user]}" = "skip" ] && continue

        if [ -n "${is_res[$user]:-}" ]; then
            local owned=0 u2
            for u2 in "${!owner[@]}"; do [ "${owner[$u2]}" = "$user" ] && owned=$((owned+1)); done
            if [ -n "$res_all" ]; then
                ans="$res_all"
            else
                echo
                echo -e "  ${YELLOW}$user${RESET} is a RESELLER on the source$([ "$owned" -gt 0 ] && echo " (owns $owned account(s))")."
                echo "  1) keep it a reseller with the same privileges (ACLs) as on the source"
                echo "  2) keep it a reseller, but WITHOUT its privileges (set them here later)"
                echo "  3) make it a plain cPanel account (not a reseller)"
                ans=$(ask_num "Reseller $user" 1 3) || return 1
                ask_yn "  Same answer for every remaining reseller?" n && res_all="$ans"
            fi
            case "$ans" in 1) resmode[$user]="same" ;; 2) resmode[$user]="no-privs" ;; 3) resmode[$user]="plain" ;; esac
        fi
    done

    # ---- 10) options for every account (WHM's per-account columns)
    echo
    local o_ip=0 o_rep="basic" o_xp=0 o_live=0 o_skh=0 o_skd=0 o_skb=0
    if [ "${nip:-0}" -gt 0 ]; then
        echo "  IP address for the accounts here:"
        echo "  1) the shared IP"
        echo "  2) a dedicated IP each ($nip free here; falls back to shared when they run out)"
        [ "$(ask_num "IP" 1 2)" = 2 ] && o_ip=1
    else
        info "No free dedicated IPs here — the accounts go on the shared IP."
    fi
    echo "  Which A records in the zones get the new IP?"
    echo "  1) basic — only the cPanel-managed records (main domain + service subdomains)"
    echo "  2) all   — every A record that points at the old IP, custom ones included"
    [ "$(ask_num "Zone IPs" 1 2)" = 2 ] && o_rep="all"
    ask_yn "Express Transfer (repoint the source's DNS here and proxy the old account when each one is done)?" n && o_xp=1
    if [ "${rlive:-0}" = 1 ]; then
        ask_yn "Live Transfer (keep the sites served from the source until each account is fully restored)?" n && o_live=1
    else
        info "The source does not support Live Transfer — not offered."
    fi
    ask_yn "Skip the home directory files (e.g. already copied with rsync)?" n && o_skh=1
    ask_yn "Skip the databases?" n && o_skd=1
    ask_yn "Skip the bandwidth history?" n && o_skb=1

    # Packages / feature lists the chosen accounts use and this server lacks.
    local -a pkgs=() fls=()
    local -A pk_seen=() fl_seen=()
    local p fl
    for user in "${cand[@]}"; do
        [ "${act[$user]}" = "skip" ] && continue
        p="${plan_of[$user]:-}"
        case "$p" in ""|default|undefined) continue ;; esac
        [ -n "${pk_seen[$p]:-}" ] && continue; pk_seen[$p]=1
        [ -f "/var/cpanel/packages/$p" ] && { info "Package '$p' already exists here — the local one is used."; continue; }
        pkgs+=("$p")
    done
    if [ "${#pkgs[@]}" -gt 0 ]; then
        echo "  Packages these accounts use that don't exist here: ${pkgs[*]}"
        if ask_yn "Transfer them (with their feature lists)?" y; then
            for p in "${pkgs[@]}"; do
                fl="${pkg_fl[$p]:-}"
                case "$fl" in ""|default|disabled) continue ;; esac
                [ -n "${fl_seen[$fl]:-}" ] && continue; fl_seen[$fl]=1
                [ -f "/var/cpanel/features/$fl" ] || fls+=("$fl")
            done
        else
            pkgs=()
        fi
    elif [ "${#srcpkgs[@]}" -gt 0 ] && [ "${#plan_of[@]}" -eq 0 ]; then
        info "The source didn't say which package each account uses — transfer packages from WHM if needed."
    fi

    # ---- 11) the plan, then one last yes
    local nq=0 res_label
    echo
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${RESET}"
    printf '  %-16s %-30s %-18s %s\n' "USER" "DOMAIN" "ACTION" "RESELLER"
    for user in "${cand[@]}"; do
        case "${act[$user]}" in
            rename) a="as ${luser[$user]}" ;;
            *)      a="${act[$user]}" ;;
        esac
        printf '  %-16s %-30s %-18s %s\n' "$user" "${dom[$user]:--}" "$a" "${resmode[$user]}"
        [ "${act[$user]}" != "skip" ] && nq=$((nq+1))
    done
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${RESET}"
    [ "${#pkgs[@]}" -gt 0 ] && echo "  + packages: ${pkgs[*]}${fls[0]:+  + feature lists: ${fls[*]}}"
    echo "  From root@$host:$port · IP: $([ "$o_ip" = 1 ] && echo dedicated || echo shared) · zones: $o_rep$([ "$o_xp" = 1 ] && echo ' · express')$([ "$o_live" = 1 ] && echo ' · live')$([ "$o_skh" = 1 ] && echo ' · no home files')$([ "$o_skd" = 1 ] && echo ' · no DBs')"
    if [ "$nq" -eq 0 ]; then
        info "Nothing left to transfer."
        for user in "${cand[@]}"; do echo "$user,${dom[$user]},skip,,${resmode[$user]},,ignored (conflict)" >> "$plan"; done
        return 1
    fi
    ask_yn "Queue $nq account(s) and start the transfer now?" n || { info "Transfer cancelled — nothing was queued."; return 1; }

    # ---- 12) queue: feature lists, packages, then the accounts (resellers first)
    local nok=0 nfail=0 note
    for fl in ${fls[@]+"${fls[@]}"}; do
        whm_call enqueue_transfer_item transfer_session_id="$XFER_SID" module=FeatureListRemoteRoot featurelist="$fl" \
            || error "Feature list $fl not queued: $WHM_REASON"
    done
    for p in ${pkgs[@]+"${pkgs[@]}"}; do
        whm_call enqueue_transfer_item transfer_session_id="$XFER_SID" module=PackageRemoteRoot package="$p" \
            || error "Package $p not queued: $WHM_REASON"
    done
    for user in "${cand[@]}"; do
        if [ "${act[$user]}" = "skip" ]; then
            echo "$user,${dom[$user]},skip,,${resmode[$user]},,ignored (conflict)" >> "$plan"; continue
        fi
        local -a it=(transfer_session_id="$XFER_SID" module=AccountRemoteRoot
                     user="$user" localuser="${luser[$user]}" size="${size[$user]:-1}"
                     ip="$o_ip" replaceip="$o_rep" xferpoint="$o_xp" live_transfer="$o_live"
                     skiphomedir="$o_skh" skipacctdb="$o_skd" skipbwdata="$o_skb"
                     shared_mysql_server="${shared_db:-0}")
        [ -n "${dom[$user]:-}" ] && it+=(domain="${dom[$user]}")
        case "${act[$user]}" in
            overwrite)        it+=(force=1 overwrite_sameowner_dbs="${owdbs:-1}" overwrite_sameowner_dbusers="${owdbs:-1}") ;;
            overwrite-delete) it+=(force=1 overwrite_with_delete=1 overwrite_sameowner_dbs="${owdbs:-1}" overwrite_sameowner_dbusers="${owdbs:-1}") ;;
        esac
        case "${resmode[$user]}" in
            same)     it+=(reseller=1 skipres=0) ;;
            no-privs) it+=(reseller=1 skipres=1) ;;
            plain)    it+=(reseller=0 skipres=1) ;;
        esac
        if whm_call enqueue_transfer_item "${it[@]}"; then
            nok=$((nok+1)); note="queued"
        else
            nfail=$((nfail+1)); note="not queued: $WHM_REASON"
            error "$user not queued: $WHM_REASON"
        fi
        echo "$user,${dom[$user]},${act[$user]},${luser[$user]},${resmode[$user]},,${note//,/;}" >> "$plan"
        log "TRANSFER $user (${dom[$user]}) action=${act[$user]} local=${luser[$user]} reseller=${resmode[$user]} -> $note"
    done
    if [ "$nok" -eq 0 ]; then
        error "No account could be queued — nothing started."
        whm_call abort_transfer_session transfer_session_id="$XFER_SID" >/dev/null 2>&1
        return 1
    fi

    # ---- 13) go, and watch
    whm_call start_transfer_session transfer_session_id="$XFER_SID" \
        || { error "Could not start the session: $WHM_REASON"; return 1; }
    success "Transfer started: $nok account(s), session $XFER_SID"
    echo -e "  Also visible in ${YELLOW}WHM » Transfers » Transfer Tool${RESET} (session $XFER_SID)."
    log "TRANSFER started session=$XFER_SID queued=$nok failed_to_queue=$nfail"
    local t0=$SECONDS
    xfer_watch "$XFER_SID"

    # ---- 14) the outcome: per account (does it exist here now?) + WHM's errors
    local present=0 missing=0 errs
    if [ "$XFER_STATE" != "DETACHED" ]; then
        if whm_call fetch_transfer_session_log transfer_session_id="$XFER_SID" logfile=master.error_log; then
            errs=$(json_q "$WHM_JSON" '
                for (split /\n/, sv($d->{data}{log})) {
                    my $e = eval { JSON::PP->new->decode($_) } or next;
                    my $c = $e->{contents}; my $m = ref $c eq "HASH" ? $c->{msg} : $c;
                    $m = join(" ", grep { !ref } @$m) if ref $m eq "ARRAY";
                    next if !defined $m || ref $m; $m =~ s/\s+$//; print "$m\n" if length $m;
                }')
            if [ -n "$errs" ]; then
                printf '%s\n' "$errs" > "$OUT_DIR/transfer-errors.log"
                echo -e "  ${YELLOW}WHM reported errors/warnings${RESET} (last 20; all in $OUT_DIR/transfer-errors.log):"
                printf '%s\n' "$errs" | tail -n 20 | sed 's/^/    /'
            fi
        fi
        local tmpplan; tmpplan=$(mktemp)
        while IFS=, read -r a b c d e f g; do
            if [ "$c" != "action" ] && [ "${g%%:*}" = "queued" ]; then
                if [ -f "/var/cpanel/users/$d" ]; then f="restored"; present=$((present+1))
                else f="missing"; missing=$((missing+1)); fi
            fi
            echo "$a,$b,$c,$d,$e,$f,$g" >> "$tmpplan"
        done < "$plan"
        mv "$tmpplan" "$plan"
    fi

    {
        echo "Date        : $(date +'%F %T')"
        echo "Method      : cPanel Transfer Tool (WHM API 1), pulled by this destination"
        echo "Source      : root@$host:$port (cPanel ${rver:-?}${rhost:+, $rhost})"
        echo "Session     : $XFER_SID"
        echo "Queued      : $nok$([ "$nfail" -gt 0 ] && echo " (not queued: $nfail)")"
        [ "${#pkgs[@]}" -gt 0 ] && echo "Packages    : ${pkgs[*]}"
        echo "State       : $XFER_STATE"
        [ "$XFER_STATE" != "DETACHED" ] && echo "Present now : $present of $nok (missing: $missing)"
        echo "Duration    : $(fmt_duration $((SECONDS-t0)))"
        echo "Plan        : $plan"
    } | report_set_section TRANSFER

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Transfer session : $XFER_SID"
    echo -e "  State            : $XFER_STATE"
    if [ "$XFER_STATE" != "DETACHED" ]; then
        echo -e "  Accounts here    : ${GREEN}$present${RESET} of $nok$([ "$missing" -gt 0 ] && echo -e "   ${RED}missing: $missing${RESET}")"
    fi
    echo -e "  Plan / results   : $plan"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    log "TRANSFER end session=$XFER_SID state=$XFER_STATE present=$present missing=$missing"

    case "$XFER_STATE" in
        COMPLETED) return 0 ;;
        DETACHED)  return 2 ;;
        *)         return 1 ;;
    esac
}

# Destination hook: offered whenever THIS server is cPanel — even when the
# source report says nothing about the source's panel. Returns run_transfer's
# code, or 3 when the Transfer Tool was not run at all.
maybe_transfer() {   # $1 = rows "user<TAB>domain"   $2 = the operator's own --dry-run
    [ "$TRANSFER" = "no" ] && return 3
    if [ ! -d /usr/local/cpanel ] || [ ! -x "$WHMAPI" ]; then
        [ "$TRANSFER" = "yes" ] && error "--transfer needs a cPanel destination; this server is not cPanel."
        return 3
    fi
    if [ -n "$SRC_PANEL" ]; then
        info "Source (from the report): $(panel_label "$SRC_PANEL")${SRC_PANEL_VER:+ $SRC_PANEL_VER}${SRC_HOST:+ · $SRC_HOST}${SRC_IP:+ · $SRC_IP}"
    else
        info "Source panel: not in the report — the Transfer Tool checks it when it connects."
    fi
    if [ "$SRC_PANEL" = "directadmin" ]; then
        info "The source runs DirectAdmin — WHM's Transfer Tool can't pull from it (use --sync on the source)."
        return 3
    fi
    if [ -n "$2" ]; then
        info "Dry-run: the Transfer Tool is not offered."
        return 3
    fi
    if [ -z "$TRANSFER" ]; then
        [ -t 0 ] || return 3
        echo
        ask_yn "This destination is cPanel. Pull these accounts from the source with cPanel's own Transfer Tool first?" n \
            || return 3
    fi
    run_transfer "$1"
}

# ════════════════════════════════════════════════════════════
#   SYNC ONLY
# ════════════════════════════════════════════════════════════
run_sync() {
    select_accounts
    info "Accounts selected: $(printf '%s\n' "$ROWS" | grep -c .)"
    start_sync "$ROWS" || exit 1
}

# ════════════════════════════════════════════════════════════
#   PREP ONLY
# ════════════════════════════════════════════════════════════
run_prep_mode() {
    local side="$PREP_SIDE" ans srcip
    if [ -z "$side" ]; then
        echo -e "${CYAN}Which side is THIS server?${RESET}"
        echo "  1) source       — stop SecCheck & scanners, whitelist the destination"
        echo "  2) destination  — the same, plus open SSH root login for the rsync"
        read -r -p "Enter choice (1-2): " ans
        case "$ans" in
            1) side="source" ;;
            2) side="destination" ;;
            *) error "Invalid choice."; exit 1 ;;
        esac
    fi
    info "Prep mode: $side side"
    if [ -z "$PEER_IP" ]; then
        read -r -p "IP of the other server ($([ "$side" = source ] && echo destination || echo source)): " PEER_IP
    fi
    [ -n "$PEER_IP" ] || { error "No peer IP given."; exit 1; }
    [[ "$PEER_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || { error "Invalid peer IP: $PEER_IP"; exit 1; }
    # A cPanel destination may pull the accounts with its Transfer Tool instead
    # of us pushing an rsync — then it is THIS source that gets connected to as
    # root, so root SSH has to open here.
    local ssh=""
    if [ "$side" = "source" ] && [ -t 0 ]; then
        read -r -p "Will the destination pull accounts with cPanel's Transfer Tool (opens root SSH on THIS source)? [y/N]: " ans
        case "$ans" in [Yy]*) ssh="yes" ;; esac
    fi
    run_prep "$side" "$PEER_IP" "$ssh" || exit 1
    # On the source, the destination block belongs with the prep: generate and
    # print it too (no sync follows here, so no wait for Enter).
    if [ "$side" = "source" ]; then
        srcip=$(prep_source_ip) || { error "Could not determine this server's IP for the destination block."; exit 1; }
        print_destination_block "$srcip" no
    fi
}

# ════════════════════════════════════════════════════════════
#   SOURCE PASS
# ════════════════════════════════════════════════════════════
run_source() {
    local rows
    select_accounts
    rows="$ROWS"

    local total i=0 ok=0 fail=0 start=$SECONDS
    total=$(printf '%s\n' "$rows" | grep -c .)
    [ "$LIST_ONLY" = "yes" ] || mkdir -p "$SNAP_DIR/before"
    : > "$OUT_CSV"
    local csv_header="user,domain,status_before,status_after"
    [ "$NS_LOOKUP" = "yes" ] && csv_header="$csv_header,ns1,ns2,ns3,ns4"
    echo "$csv_header" >> "$OUT_CSV"
    if [ "$LIST_ONLY" = "yes" ]; then
        info "Accounts found: $total"
    else
        info "Accounts to snapshot: $total"
    fi
    echo

    local owner user domain NS_CSV="" ns1
    while IFS=$'\t' read -r owner user domain; do
        [ -z "$domain" ] && continue
        i=$((i+1))
        # Looked up once per domain, then appended to whichever row is written
        # below; NS_CSV is empty when the feature is off, so no columns are added.
        [ "$NS_LOOKUP" = "yes" ] && lookup_ns "$domain"
        # List-only: the account list is the whole deliverable. status_before is
        # left empty — the CSV still feeds the destination pass, that pass just
        # has no "before" to compare its result against.
        if [ "$LIST_ONLY" = "yes" ]; then
            if [ "$NS_LOOKUP" = "yes" ]; then
                ns1="${NS_CSV%%,*}"
                printf '[%3d/%3d] %-20s %-32s %s\n' "$i" "$total" "$user" "$domain" "${ns1:--}"
            else
                printf '[%3d/%3d] %-20s %s\n' "$i" "$total" "$user" "$domain"
            fi
            echo "$user,$domain,,${NS_CSV:+,$NS_CSV}" >> "$OUT_CSV"
            log "SOURCE $domain (user=$user) listed${NS_CSV:+ ns=$NS_CSV}"
            continue
        fi
        printf '[%3d/%3d] %-35s' "$i" "$total" "$domain"
        health "$domain" "$(snap_path before "$domain")"
        if [ "$H_STATUS" = "OK" ]; then
            printf ' -> %b%s%b' "$GREEN" "$H_STATUS" "$RESET"; ok=$((ok+1))
        else
            printf ' -> %b%s%b' "$YELLOW" "$H_STATUS" "$RESET"; fail=$((fail+1))
        fi
        echo
        echo "$user,$domain,$H_STATUS,${NS_CSV:+,$NS_CSV}" >> "$OUT_CSV"
        log "SOURCE $domain (user=$user) $H_STATUS${NS_CSV:+ ns=$NS_CSV}"
    done <<< "$rows"

    local dur; dur=$(fmt_duration $((SECONDS-start)))

    # Plain-text report kept alongside the data. The server facts feed the
    # destination (its Transfer Tool defaults to this IP and SSH port). The panel
    # line is written only when a panel was actually detected — with a -f list
    # and no panel on the box, there is nothing true to say about it.
    local rpanel="$PANEL" rver="" rip="$SERVER_IP" rhost ros
    [ -n "$rpanel" ] || { detect_panel >/dev/null 2>&1 && rpanel="$PANEL"; }
    [ -n "$rpanel" ] && rver=$(panel_version "$rpanel")
    [ -n "$rip" ] || rip=$(detect_server_ip)
    rhost=$(hostname -f 2>/dev/null || hostname 2>/dev/null)
    ros=$(os_name)
    rm -f "$REPORT_FILE"            # a new source pass starts a new job report
    {
        echo "Date       : $(date +'%F %T')"
        if [ "$LIST_ONLY" = "yes" ]; then
            echo "Pass       : list only (accounts extracted; no health checks)"
        else
            echo "Pass       : full (health check + snapshots)"
        fi
        [ -n "$rpanel" ] && echo "Panel      : $(panel_label "$rpanel")${rver:+ $rver}"
        [ -n "$rhost" ]  && echo "Hostname   : $rhost"
        [ -n "$rip" ]    && echo "Source IP  : $rip"
        echo "SSH port   : $(local_ssh_port)"
        [ -n "$ros" ]    && echo "OS         : $ros"
        command -v selectorctl >/dev/null 2>&1 && echo "CloudLinux : yes"
        [ -n "$RESELLER" ] && echo "Reseller   : $RESELLER"
        echo "Accounts   : $i"
        if [ "$LIST_ONLY" != "yes" ]; then
            echo "Healthy    : $ok"
            echo "Problems   : $fail"
        fi
        echo "Duration   : $dur"
    } | report_set_section SOURCE

    if [ "$LIST_ONLY" = "yes" ]; then
        echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
        echo -e "  Account list written : $OUT_CSV"
        echo -e "  Report               : $REPORT_FILE"
        echo -e "  Accounts             : $i"
        echo -e "  Duration             : $dur"
        echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
        echo -e "  Health-check these accounts later with:  magic-move.sh --source --snapshot"
        log "SOURCE list-only done: $i accounts, ${dur} -> $OUT_CSV"
        maybe_sync "$rows"
        return 0
    fi

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Source snapshot written : $OUT_CSV"
    echo -e "  Page snapshots          : $SNAP_DIR/before/"
    echo -e "  Report                  : $REPORT_FILE"
    echo -e "  Accounts                : $i    (${GREEN}OK $ok${RESET} / ${YELLOW}Fail $fail${RESET})"
    echo -e "  Duration                : $dur"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Copy the ${YELLOW}$OUT_DIR/${RESET} folder to the destination, then:  magic-move.sh --destination"
    log "SOURCE done: $i accounts, OK=$ok Fail=$fail, ${dur} -> $OUT_CSV"

    maybe_sync "$rows"
    offer_zip
}

# ════════════════════════════════════════════════════════════
#   DESTINATION PASS
# ════════════════════════════════════════════════════════════
run_destination() {
    # Input CSV: a local path or an http(s) URL (downloaded to a temp file).
    [ -n "$CSV_IN" ] || { read -r -p "Source CSV to verify [$OUT_CSV]: " CSV_IN; CSV_IN="${CSV_IN:-$OUT_CSV}"; }
    local user_dry="$DRY_RUN"       # the operator's own --dry-run (not the no-CloudLinux fallback)

    local tmp="" rtmp="" srcrep=""
    if [[ "$CSV_IN" =~ ^https?:// ]]; then
        tmp=$(mktemp) || { error "Could not create temp file."; exit 1; }
        info "Downloading source CSV: $CSV_IN"
        curl -kLsS --max-time 30 -o "$tmp" "$CSV_IN" || { error "Download failed."; rm -f "$tmp"; exit 1; }
        # The source report usually sits next to the CSV — fetch it too (optional).
        rtmp=$(mktemp) && curl -kfLsS --max-time 30 -o "$rtmp" "${CSV_IN%/*}/report.txt" 2>/dev/null && srcrep="$rtmp"
        CSV_IN="$tmp"
    fi
    [ -f "$CSV_IN" ] || { error "Source CSV not found: $CSV_IN"; exit 1; }

    # Source facts (panel, IP, SSH port) from the report the source pass wrote.
    # Old reports work too; a missing report just means "unknown".
    local rf found=""
    for rf in "$srcrep" "$REPORT_FILE" "$([ -z "$tmp" ] && dirname "$CSV_IN")/report.txt"; do
        [ -n "$rf" ] && [ "$rf" != "/report.txt" ] && read_source_report "$rf" && { found="$rf"; break; }
    done
    rf="$found"
    # Keep those facts in THIS job's report when they came from elsewhere.
    if [ -n "$rf" ] && [ "$rf" != "$REPORT_FILE" ] && \
       ! grep -q '^Magic Move — SOURCE report' "$REPORT_FILE" 2>/dev/null; then
        awk '/^Magic Move — SOURCE report/{on=1; next} /^Magic Move — [A-Z]+ report/{on=0} on' "$rf" \
            | report_set_section SOURCE
    fi
    [ -n "$rtmp" ] && rm -f "$rtmp"

    if [ -z "$DRY_RUN" ] && ! command -v selectorctl >/dev/null 2>&1; then
        error "selectorctl not found — not a CloudLinux box. Falling back to report-only."
        DRY_RUN="yes"
    fi
    [ -n "$DRY_RUN" ] && info "Dry-run: PHP versions will NOT be changed."

    # Read the source CSV fully first, so we can safely rewrite it in place.
    # Anything past status_after (the ns1-ns4 columns) is kept verbatim and
    # written back out: it belongs to the source pass, not to this one.
    local U=() D=() SB=() EX=()
    local user domain sbefore _safter extra
    local csv_header; csv_header=$(head -n1 "$CSV_IN")
    case "$csv_header" in user,domain,*) ;; *) csv_header="user,domain,status_before,status_after" ;; esac
    while IFS=, read -r user domain sbefore _safter extra; do
        user="${user//[[:space:]]/}"; domain="${domain//[[:space:]]/}"
        [ -z "$domain" ] && continue
        [ "$user" = "user" ] && continue          # header
        case "$user" in \#*) continue ;; esac
        U+=("$user"); D+=("$domain"); SB+=("$sbefore"); EX+=("$extra")
    done < "$CSV_IN"

    [ -f "$tmp" ] && rm -f "$tmp"

    # cPanel destination: offer WHM's Transfer Tool to pull the accounts first.
    local xrows="" k xrc
    for ((k=0; k<${#U[@]}; k++)); do xrows+="${U[$k]}"$'\t'"${D[$k]}"$'\n'; done
    maybe_transfer "$xrows" "$user_dry"; xrc=$?
    case "$xrc" in
        2)  info "The transfer is still running. Verify once WHM shows it finished:"
            echo -e "      magic-move.sh --destination --no-transfer -f $OUT_CSV"
            return 0 ;;
        1)  if [ -t 0 ]; then
                ask_yn "The transfer did not complete. Verify the accounts on this server anyway?" n || return 0
            fi ;;
    esac

    local total=${#D[@]} i=0 okc=0 fixedc=0 failc=0 regress=0 bfail=0 plugc=0 start=$SECONDS
    mkdir -p "$SNAP_DIR/after"
    local out_tmp; out_tmp=$(mktemp)
    echo "$csv_header" >> "$out_tmp"
    info "Accounts to verify: $total"
    echo

    local snap sa orig ver before_status DISABLED_PLUGINS
    for ((idx=0; idx<total; idx++)); do
        user="${U[$idx]}"; domain="${D[$idx]}"; before_status="${SB[$idx]}"; extra="${EX[$idx]}"
        i=$((i+1))
        snap=$(snap_path after "$domain")
        DISABLED_PLUGINS=""          # reset per account so counts never carry over
        printf '[%3d/%3d] %-35s' "$i" "$total" "$domain"

        health "$domain" "$snap"
        if [ "$H_STATUS" = "OK" ]; then
            printf ' -> %bOK%b' "$GREEN" "$RESET"
        else
            printf ' -> %b%s%b' "$YELLOW" "$H_STATUS" "$RESET"
        fi
        sa="$H_STATUS"

        # Heal only fixable failures, only here, only with a known user.
        if [ "$H_BROKEN" = "yes" ] && [ -n "$user" ]; then
            before_fix="$H_STATUS"

            # 1) Plugin-fatal healing first: a plugin code fatal (the common
            #    "critical error" WSOD) is not something a PHP switch can fix.
            case "$H_STATUS" in
                "Fail(php fatal)"|"Fail(wp error)"|"Fail(500)")
                    heal_plugin_fatal "$user" "$domain"
                    [ -n "$DISABLED_PLUGINS" ] && health "$domain" "$snap"
                    ;;
            esac

            if [ "$H_STATUS" = "OK" ] && [ -n "$DISABLED_PLUGINS" ]; then
                sa="OK (disabled: $DISABLED_PLUGINS)"
                printf ' -> %bfixed%b' "$GREEN" "$RESET"
                log "DEST FIXED $domain by disabling: $DISABLED_PLUGINS"
            else
                # 2) Fall back to stepping the PHP version down.
                orig=$(get_current_php "$user")
                [ -n "$orig" ] && printf ' (was PHP %s)' "$orig"
                for ver in $PHP_VERSIONS; do
                    [ "$ver" = "$orig" ] && continue
                    switch_php "$user" "$ver"; sleep "$SETTLE"
                    health "$domain" "$snap"
                    printf ' -> PHP %s -> %s' "$ver" "$H_STATUS"
                    [ "$H_BROKEN" != "yes" ] && break
                done
                if [ "$H_STATUS" = "OK" ]; then
                    sa="OK (fixed PHP $ver${DISABLED_PLUGINS:+, disabled: $DISABLED_PLUGINS})"
                    printf ' -> %bfixed%b' "$GREEN" "$RESET"
                    log "DEST FIXED $domain -> PHP $ver (was ${orig:-?})${DISABLED_PLUGINS:+, disabled: $DISABLED_PLUGINS}"
                elif [ -n "$orig" ]; then
                    switch_php "$user" "$orig"
                    health "$domain" "$snap"      # snapshot the restored state
                    sa="$before_fix (restored PHP $orig${DISABLED_PLUGINS:+, disabled: $DISABLED_PLUGINS})"
                    printf ' -> %bnot fixed, restored PHP %s%b' "$RED" "$orig" "$RESET"
                    log "DEST UNRESOLVED $domain — restored PHP $orig${DISABLED_PLUGINS:+, disabled: $DISABLED_PLUGINS}"
                else
                    sa="$before_fix${DISABLED_PLUGINS:+ (disabled: $DISABLED_PLUGINS)}"
                    printf ' -> %bnot fixed (user/version unknown)%b' "$RED" "$RESET"
                    log "DEST UNRESOLVED $domain — original version unknown"
                fi
            fi
        fi
        echo

        # Tally against the source baseline.
        if [ -n "$DISABLED_PLUGINS" ]; then
            plugc=$((plugc + $(printf '%s' "$DISABLED_PLUGINS" | tr ',' '\n' | grep -c .)))
        fi
        [ "$before_status" != "OK" ] && bfail=$((bfail+1))
        case "$sa" in
            OK) okc=$((okc+1)) ;;
            "OK "*) fixedc=$((fixedc+1)); okc=$((okc+1)) ;;
            *) failc=$((failc+1)); [ "$before_status" = "OK" ] && regress=$((regress+1)) ;;
        esac
        echo "$user,$domain,$before_status,$sa${extra:+,$extra}" >> "$out_tmp"
    done

    mv "$out_tmp" "$OUT_CSV"
    local dur; dur=$(fmt_duration $((SECONDS-start)))

    # Only this pass's section is replaced: the SOURCE facts (and a TRANSFER
    # section, when the Transfer Tool ran) stay in the same report.
    {
        echo "Date            : $(date +'%F %T')"
        echo "Server IP       : $SERVER_IP"
        echo "Accounts        : $i"
        echo "Problems before : $bfail"
        echo "Problems now    : $failc"
        echo "  fixed here    : $fixedc"
        echo "  regressions   : $regress"
        echo "Plugins disabled: $plugc"
        echo "Healthy now     : $okc"
        echo "Duration        : $dur"
    } | report_set_section DESTINATION

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Verified CSV written : $OUT_CSV"
    echo -e "  Page snapshots       : $SNAP_DIR/after/"
    echo -e "  Report               : $REPORT_FILE"
    echo -e "  Accounts             : $i"
    echo -e "  Problems  ${YELLOW}before $bfail${RESET}  ->  ${GREEN}now $failc${RESET}   (fixed here: $fixedc)"
    [ "$plugc" -gt 0 ] && echo -e "  ${YELLOW}Plugins disabled${RESET}     : $plugc"
    echo -e "  ${GREEN}Healthy now${RESET}          : $okc"
    [ "$regress" -gt 0 ] && echo -e "  ${RED}Regressions vs source${RESET}: $regress"
    echo -e "  Duration             : $dur"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    log "DEST done: $i accounts, before_fail=$bfail now_fail=$failc fixed=$fixedc regress=$regress, ${dur} -> $OUT_CSV"

    offer_zip
}

# ---------- Dispatch ----------
case "$MODE" in
    source)        run_source ;;
    destination)   run_destination ;;
    sync)          run_sync ;;
    prep)          run_prep_mode ;;
    *)             error "Unknown mode: $MODE"; exit 1 ;;
esac
# finish_log (EXIT trap) prints the log path.
