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
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 2.6.0
# ════════════════════════════════════════════════════════════
VERSION="2.6.0"

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
# the prep step instead of asking about it.
if [ "$PREP_GIVEN" = 1 ] && [ "$MODE" != "sync" ] && [ "$SYNC" != "yes" ]; then
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

run_prep() {   # $1 = side (source|destination)   $2 = peer IP to whitelist here
    [ "$(id -u)" = 0 ] || { error "Prep must run as root."; return 1; }
    local side="$1" peer="$2"
    echo
    info "Prep on this ${side} — whitelisting peer ${peer}"
    disable_seccheck
    stop_scanners
    allow_hosts_deny
    allow_in_firewall "$peer"
    if [ "$side" = "destination" ]; then
        open_ssh_root
    fi
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  ${GREEN}Prep done on this server${RESET}"
    echo -e "   - SecCheck stopped & disabled (cron entries quarantined)"
    echo -e "   - Scanners stopped & disabled (clamd@scan, freshclam, cxswatch, rspamd, spamd)"
    echo -e "   - hosts.deny checked"
    echo -e "   - CSF: $peer allowed"
    [ "$side" = "destination" ] && echo -e "   - SSH root login enabled"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    log "PREP done side=$side peer=$peer"
    echo
}

# This server's IP as the DESTINATION must see it (for the block's whitelist):
# panel record / route table first, and a public-IP lookup when only a private
# address is visible (NAT). Confirmed interactively — whitelisting the wrong IP
# would lock the sync out.
prep_source_ip() {
    local ip="$SERVER_IP" pub ans
    [ -z "$ip" ] && ip=$(detect_server_ip)
    case "$ip" in ""|10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
        if command -v curl >/dev/null 2>&1; then
            pub=$(curl -4ks --max-time 6 https://api.ipify.org 2>/dev/null) \
                || pub=$(curl -4ks --max-time 6 http://ifconfig.me 2>/dev/null)
            [ -n "$pub" ] && ip="$pub"
        fi
    ;; esac
    if [ -t 0 ]; then
        read -r -p "Source IP to whitelist on the destination [$ip]: " ans
        ip="${ans:-$ip}"
    fi
    case "$ip" in
        [0-9A-Fa-f]*|:[0-9A-Fa-f]*) [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] && { printf '%s' "$ip"; return 0; } ;;
    esac
    return 1
}

# The destination block: complete, prompt-free, idempotent, with the source IP
# already in it. Written once to a file (so it can be scp'd too) and printed for
# pasting. __SRC_IP__ is substituted after the quoted heredoc.
write_destination_block() {   # $1 = source IP   $2 = output path
    cat > "$2" <<'MMBLOCK'
#!/bin/bash
# ════════════════════════════════════════════════════════════
#   Magic Move — DESTINATION prep (generated on the source)
#   Whitelists the source, stops SecCheck + scanners, opens SSH root.
#   Safe to re-run; backups are kept next to every edited file.
# ════════════════════════════════════════════════════════════
SRC_IP="__SRC_IP__"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "── Magic Move — destination prep (source: $SRC_IP) ──"

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

# 4) Firewall — allow the source server
if command -v csf >/dev/null 2>&1; then
    if grep -qE "^${SRC_IP//./\\.}([[:space:]]|$)" /etc/csf/csf.allow 2>/dev/null; then
        echo "   CSF: $SRC_IP already allowed"
    else
        csf -a "$SRC_IP" >/dev/null 2>&1 && echo "   CSF: $SRC_IP allowed" \
            || echo "   ! CSF: could not add $SRC_IP — add it manually"
    fi
    csf -r >/dev/null 2>&1
    echo "   CSF reloaded"
else
    echo "   ! CSF not found — allow $SRC_IP in the firewall manually"
fi

# 5) SSH — allow root login for the rsync
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
echo "  DONE — destination is ready for Magic Move."
echo "  Now go back to the SOURCE and press Enter there."
echo "════════════════════════════════════════════════"
MMBLOCK
    sed -i "s/__SRC_IP__/$1/g" "$2"
    chmod +x "$2" 2>/dev/null
    log "PREP destination block written: $2 (source IP: $1)"
}

print_destination_block() {   # $1 = source IP   $2 = wait for Enter? (yes|no)
    local srcip="$1" wait="$2" block="$OUT_DIR/destination-prep.sh"
    write_destination_block "$srcip" "$block"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  ${YELLOW}Run this on the DESTINATION${RESET} (paste the whole block there, press Enter):"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    cat "$block"
    echo -e "${CYAN}────────────────────────────────────────────────${RESET}"
    echo -e "  Also saved for scp: ${YELLOW}$block${RESET}"
    if [ "$wait" = "yes" ] && [ -t 0 ]; then
        echo
        read -r -p "Press Enter here once the destination block has finished... " _
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
    run_prep "$side" "$PEER_IP" || exit 1
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

    # Plain-text report kept alongside the data.
    {
        echo "Magic Move — SOURCE report"
        echo "Date       : $(date +'%F %T')"
        if [ "$LIST_ONLY" = "yes" ]; then
            echo "Pass       : list only (accounts extracted; no health checks)"
        else
            echo "Server IP  : $SERVER_IP"
        fi
        echo "Panel      : ${PANEL:-list}"
        [ -n "$RESELLER" ] && echo "Reseller   : $RESELLER"
        echo "Accounts   : $i"
        if [ "$LIST_ONLY" != "yes" ]; then
            echo "Healthy    : $ok"
            echo "Problems   : $fail"
        fi
        echo "Duration   : $dur"
    } > "$REPORT_FILE"

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

    local tmp=""
    if [[ "$CSV_IN" =~ ^https?:// ]]; then
        tmp=$(mktemp) || { error "Could not create temp file."; exit 1; }
        info "Downloading source CSV: $CSV_IN"
        curl -kLsS --max-time 30 -o "$tmp" "$CSV_IN" || { error "Download failed."; rm -f "$tmp"; exit 1; }
        CSV_IN="$tmp"
    fi
    [ -f "$CSV_IN" ] || { error "Source CSV not found: $CSV_IN"; exit 1; }

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

    {
        echo "Magic Move — DESTINATION report"
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
    } > "$REPORT_FILE"

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
