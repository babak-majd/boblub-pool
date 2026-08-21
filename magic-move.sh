#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Magic Move
#   Two-pass migration verifier. Run on the SOURCE to snapshot
#   every account's status, then on the DESTINATION to re-check
#   and heal broken PHP sites — proving the move came across clean.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 2.0.0
# ════════════════════════════════════════════════════════════
VERSION="2.0.0"

set -u

# ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------- Logging ----------
LOG_FILE="/var/log/magic-move.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="./magic-move.log"

log() {
    echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"
}

info(){ echo -e "${YELLOW}[INFO]${RESET} $*"; log "[INFO] $*"; }
success(){ echo -e "${GREEN}[OK]${RESET} $*"; log "[OK] $*"; }
error(){ echo -e "${RED}[ERROR]${RESET} $*"; log "[ERROR] $*"; }

# ---------- Defaults ----------
MODE=""                       # source | destination — prompted when unset
PANEL=""                      # cpanel | directadmin — auto-detected / forced
SERVER_IP=""                  # this server's IP; auto-detected default, prompted
RESELLER=""                   # source: only accounts owned by this reseller
CSV_IN=""                     # destination: the CSV produced on the source
OUT_CSV="migration.csv"       # written by both passes
SNAP_DIR="snapshots"          # snapshots/before (source), snapshots/after (dest)
PHP_VERSIONS="8.3 8.1 7.4"    # cascade tried, in order, on a fixable failure
TIMEOUTS="10 20 35 60"        # attempt 1 + three escalating retries on a 000
SETTLE=2                      # pause after a version switch before re-checking
DRY_RUN=""                    # destination: check & record, never switch PHP

# ---------- Usage ----------
usage() {
    cat <<EOF
Usage: magic-move.sh [options]

A migration is verified in two passes:

  1. SOURCE       Detect every account (cPanel/DirectAdmin), health-check each
                  domain, and record it as status_before in $OUT_CSV. Snapshots
                  each page to $SNAP_DIR/before/<domain>.html. No changes made.
  2. DESTINATION  Take that CSV, re-check every domain against THIS server, and
                  heal any broken PHP site (500 / WordPress / ionCube) by
                  stepping its version down — recording status_after and
                  snapshotting to $SNAP_DIR/after/<domain>.html.

Every domain is probed with all hostnames pinned to this server, so a redirect
to www/a subdomain follows onto the box we are testing, not wherever DNS points.

Options:
      --source            This is the source server (snapshot only).
      --destination       This is the destination server (verify + heal).
  -i, --ip <ip>           Server IP to pin every domain to. Prompted for, with
                          the auto-detected IP as default, when omitted.
  -f, --file <path|url>   DESTINATION: the CSV from the source pass (path or URL).
                          SOURCE: optional "user,domain" list to use instead of
                          auto-detecting accounts.
  -r, --reseller <name>   SOURCE: only accounts owned by this reseller.
  -o, --output <path>     Output CSV name. (default: $OUT_CSV)
  -p, --php-versions <v>  DESTINATION: cascade to try, in order. (default: "$PHP_VERSIONS")
  -n, --dry-run           DESTINATION: check & record only; never switch PHP.
      --cpanel            Force the cPanel account detector.
      --directadmin       Force the DirectAdmin account detector.
  -h, --help              Show this help and exit.

Examples:
  magic-move.sh --source
  magic-move.sh --source -r bob
  magic-move.sh --destination -f migration.csv
  magic-move.sh --destination -f https://host/migration.csv --dry-run
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
        -o|--output)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            OUT_CSV="$2"; shift 2 ;;
        -p|--php-versions)
            [ -n "${2:-}" ] || { error "$1 requires a value."; exit 1; }
            PHP_VERSIONS="$2"; shift 2 ;;
        -n|--dry-run)    DRY_RUN="yes"; shift ;;
        --cpanel)        PANEL="cpanel"; shift ;;
        --directadmin)   PANEL="directadmin"; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; break ;;
        -*)              error "Unknown option: $1"; usage; exit 1 ;;
        *)               error "Unexpected argument: $1"; usage; exit 1 ;;
    esac
done

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
print_header

# ---------- Prompt: Mode ----------
# The whole run hinges on this: the source only records, the destination heals.
if [ -z "$MODE" ]; then
    echo -e "${CYAN}Is this the source or the destination server?${RESET}"
    echo "  1) source       — snapshot every account's status (no changes)"
    echo "  2) destination  — re-check and heal broken PHP sites"
    read -r -p "Enter choice (1 or 2): " MODE_CHOICE
    case "$MODE_CHOICE" in
        1) MODE="source" ;;
        2) MODE="destination" ;;
        *) error "Invalid choice."; exit 1 ;;
    esac
fi
info "Mode: $MODE"

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

    H_BROKEN="no"
    if [ "$code" = "000" ]; then
        H_STATUS="Fail(timeout)"
    elif [ "$code" = "500" ]; then
        H_STATUS="Fail(500)"; H_BROKEN="yes"
    elif [ "$code" = "200" ]; then
        if grep -qiE 'there has been a critical error|WordPress database error' <<<"$body"; then
            H_STATUS="Fail(wp error)"; H_BROKEN="yes"
        elif grep -qiE 'the ionCube Loader for PHP needs to be installed' <<<"$body"; then
            H_STATUS="Fail(ioncube)"; H_BROKEN="yes"
        elif grep -qiE '<b>Fatal error' <<<"$body"; then
            H_STATUS="Fail(php fatal)"; H_BROKEN="yes"
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

# ---------- Snapshot Helper ----------
snap_path() {   # $1 = subdir (before|after), $2 = domain
    printf '%s/%s/%s.html' "$SNAP_DIR" "$1" "$2"
}

# ════════════════════════════════════════════════════════════
#   SOURCE PASS
# ════════════════════════════════════════════════════════════
run_source() {
    local rows

    # Accounts: an explicit "user,domain" list wins; otherwise auto-detect.
    if [ -n "$CSV_IN" ]; then
        [ -f "$CSV_IN" ] || { error "List not found: $CSV_IN"; exit 1; }
        rows=$(awk -F, 'NF>=2 && $1!~/^#/ && $1!="" {print "?\t"$1"\t"$2}' "$CSV_IN")
    else
        [ -n "$PANEL" ] || detect_panel || { error "No cPanel/DirectAdmin found. Use --cpanel/--directadmin or -f."; exit 1; }
        info "Detecting accounts via: $PANEL"
        rows=$("${PANEL}_rows")
        if [ -n "$RESELLER" ]; then
            rows=$(printf '%s\n' "$rows" | awk -F'\t' -v r="$RESELLER" '$1==r')
            [ -n "$rows" ] || { error "No accounts found for reseller: $RESELLER"; exit 1; }
        fi
    fi

    local total i=0 ok=0 fail=0
    total=$(printf '%s\n' "$rows" | grep -c .)
    mkdir -p "$SNAP_DIR/before"
    : > "$OUT_CSV"
    echo "user,domain,status_before,status_after" >> "$OUT_CSV"
    info "Accounts to snapshot: $total"
    echo

    local owner user domain
    while IFS=$'\t' read -r owner user domain; do
        [ -z "$domain" ] && continue
        i=$((i+1))
        printf '[%3d/%3d] %-35s' "$i" "$total" "$domain"
        health "$domain" "$(snap_path before "$domain")"
        if [ "$H_STATUS" = "OK" ]; then
            printf ' -> %b%s%b' "$GREEN" "$H_STATUS" "$RESET"; ok=$((ok+1))
        else
            printf ' -> %b%s%b' "$YELLOW" "$H_STATUS" "$RESET"; fail=$((fail+1))
        fi
        echo
        echo "$user,$domain,$H_STATUS," >> "$OUT_CSV"
        log "SOURCE $domain (user=$user) $H_STATUS"
    done <<< "$rows"

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Source snapshot written : $OUT_CSV"
    echo -e "  Page snapshots          : $SNAP_DIR/before/"
    echo -e "  Accounts                : $i    (${GREEN}OK $ok${RESET} / ${YELLOW}Fail $fail${RESET})"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Copy $OUT_CSV to the destination and run:  magic-move.sh --destination -f $OUT_CSV"
    log "SOURCE done: $i accounts, OK=$ok Fail=$fail -> $OUT_CSV"
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
    local U=() D=() SB=()
    local user domain sbefore _rest
    while IFS=, read -r user domain sbefore _rest; do
        user="${user//[[:space:]]/}"; domain="${domain//[[:space:]]/}"
        [ -z "$domain" ] && continue
        [ "$user" = "user" ] && continue          # header
        case "$user" in \#*) continue ;; esac
        U+=("$user"); D+=("$domain"); SB+=("$sbefore")
    done < "$CSV_IN"

    [ -f "$tmp" ] && rm -f "$tmp"

    local total=${#D[@]} i=0 okc=0 fixedc=0 failc=0 regress=0
    mkdir -p "$SNAP_DIR/after"
    local out_tmp; out_tmp=$(mktemp)
    echo "user,domain,status_before,status_after" >> "$out_tmp"
    info "Accounts to verify: $total"
    echo

    local snap sa orig ver before_status
    for ((idx=0; idx<total; idx++)); do
        user="${U[$idx]}"; domain="${D[$idx]}"; before_status="${SB[$idx]}"
        i=$((i+1))
        snap=$(snap_path after "$domain")
        printf '[%3d/%3d] %-35s' "$i" "$total" "$domain"

        health "$domain" "$snap"
        if [ "$H_STATUS" = "OK" ]; then
            printf ' -> %bOK%b' "$GREEN" "$RESET"
        else
            printf ' -> %b%s%b' "$YELLOW" "$H_STATUS" "$RESET"
        fi
        sa="$H_STATUS"

        # Heal only PHP-fixable failures, only here, only with a known user.
        if [ "$H_BROKEN" = "yes" ] && [ -n "$user" ]; then
            before_fix="$H_STATUS"
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
                sa="OK (fixed PHP $ver)"
                printf ' -> %bfixed%b' "$GREEN" "$RESET"
                log "DEST FIXED $domain -> PHP $ver (was ${orig:-?})"
            else
                if [ -n "$orig" ]; then
                    switch_php "$user" "$orig"
                    health "$domain" "$snap"      # snapshot the restored state
                    sa="$before_fix (restored PHP $orig)"
                    printf ' -> %bnot fixed, restored PHP %s%b' "$RED" "$orig" "$RESET"
                    log "DEST UNRESOLVED $domain — restored PHP $orig"
                else
                    sa="$before_fix"
                    printf ' -> %bnot fixed (user/version unknown)%b' "$RED" "$RESET"
                    log "DEST UNRESOLVED $domain — original version unknown"
                fi
            fi
        fi
        echo

        # Tally against the source baseline.
        case "$sa" in
            OK) okc=$((okc+1)) ;;
            "OK "*) fixedc=$((fixedc+1)); okc=$((okc+1)) ;;
            *) failc=$((failc+1)); [ "$before_status" = "OK" ] && regress=$((regress+1)) ;;
        esac
        echo "$user,$domain,$before_status,$sa" >> "$out_tmp"
    done

    mv "$out_tmp" "$OUT_CSV"

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Verified CSV written : $OUT_CSV"
    echo -e "  Page snapshots       : $SNAP_DIR/after/"
    echo -e "  Accounts             : $i"
    echo -e "  ${GREEN}OK now${RESET}               : $okc   (of which fixed: $fixedc)"
    echo -e "  ${RED}Still failing${RESET}        : $failc   (${RED}regressions vs source: $regress${RESET})"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    log "DEST done: $i accounts, OK=$okc fixed=$fixedc fail=$failc regress=$regress -> $OUT_CSV"
}

# ---------- Dispatch ----------
case "$MODE" in
    source)        run_source ;;
    destination)   run_destination ;;
    *)             error "Unknown mode: $MODE"; exit 1 ;;
esac
