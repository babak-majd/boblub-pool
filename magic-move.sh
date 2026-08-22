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
#   Version   : 2.2.0
# ════════════════════════════════════════════════════════════
VERSION="2.2.0"

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
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
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
MODE=""                       # source | destination — prompted when unset
PANEL=""                      # cpanel | directadmin — auto-detected / forced
SERVER_IP=""                  # this server's IP; auto-detected default, prompted
RESELLER=""                   # source: only accounts owned by this reseller
USERS=""                      # source: only these specific users (space/comma)
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

# ---------- Usage ----------
usage() {
    cat <<EOF
Usage: magic-move.sh [options]

A migration is verified in two passes:

  1. SOURCE       Detect every account (cPanel/DirectAdmin), health-check each
                  domain, and record it as status_before in $OUT_CSV. Snapshots
                  each page to $SNAP_DIR/before/<domain>.html. No changes made.
  2. DESTINATION  Take that CSV, re-check every domain against THIS server, and
                  heal any broken site. For a plugin fatal it turns on WP_DEBUG,
                  reads the culprit plugin from the error and disables it (renames
                  <slug> to <slug>.dis) — Elementor and WooCommerce are never
                  touched. Otherwise it steps the PHP version down. Records
                  status_after and snapshots to $SNAP_DIR/after/<domain>.html.

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
  -u, --users <list>      SOURCE: only these users (space/comma separated).
  -o, --outdir <dir>      Output folder for migration.csv + snapshots/.
                          (default: magic-move-source / magic-move-dest)
  -p, --php-versions <v>  DESTINATION: cascade to try, in order. (default: "$PHP_VERSIONS")
  -n, --dry-run           DESTINATION: check & record only; never switch PHP,
                          never disable a plugin.
      --no-plugin-heal    DESTINATION: do not disable plugins on a fatal; only
                          step the PHP version.
      --protect <list>    DESTINATION: extra plugin slugs never to disable
                          (space/comma separated; added to the built-in
                          "$PROTECTED_PLUGINS").
      --cpanel            Force the cPanel account detector.
      --directadmin       Force the DirectAdmin account detector.
  -h, --help              Show this help and exit.

Examples:
  magic-move.sh --source
  magic-move.sh --source -r bob
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
start_log ""          # whole-server run: no per-domain/user key
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

# ---------- Output Layout ----------
# One folder holds the whole job, so it can be copied (or zipped) between servers
# in a single move and both passes accumulate into it:
#   magic-move/
#     snapshots/before/   (source)   snapshots/after/  (destination)
#     migration.csv       report.txt
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

# ════════════════════════════════════════════════════════════
#   SOURCE PASS
# ════════════════════════════════════════════════════════════
run_source() {
    local rows

    # Accounts: an explicit "user,domain" list wins; otherwise auto-detect and
    # let the operator narrow the set (all / specific users / a reseller). Flags
    # (-u / -r) skip the prompt for non-interactive runs.
    if [ -n "$CSV_IN" ]; then
        [ -f "$CSV_IN" ] || { error "List not found: $CSV_IN"; exit 1; }
        rows=$(awk -F, 'NF>=2 && $1!~/^#/ && $1!="" {print "?\t"$1"\t"$2}' "$CSV_IN")
    else
        [ -n "$PANEL" ] || detect_panel || { error "No cPanel/DirectAdmin found. Use --cpanel/--directadmin or -f."; exit 1; }
        info "Detecting accounts via: $PANEL"
        rows=$("${PANEL}_rows")
        [ -n "$rows" ] || { error "No accounts detected."; exit 1; }

        if [ -n "$USERS" ]; then
            rows=$(filter_users "$rows" "$USERS")
            [ -n "$rows" ] || { error "None of the given users matched."; exit 1; }
        elif [ -n "$RESELLER" ]; then
            rows=$(filter_reseller "$rows" "$RESELLER")
            [ -n "$rows" ] || { error "No accounts found for reseller: $RESELLER"; exit 1; }
        else
            local total_all
            total_all=$(printf '%s\n' "$rows" | grep -c .)
            echo -e "${CYAN}Which accounts do you want to snapshot?${RESET}"
            echo "  1) all accounts ($total_all)"
            echo "  2) specific users"
            echo "  3) a reseller's accounts"
            read -r -p "Enter choice (1-3): " SEL
            case "$SEL" in
                1) : ;;
                2) read -r -p "Usernames (space/comma separated): " USERS
                   rows=$(filter_users "$rows" "$USERS")
                   [ -n "$rows" ] || { error "None of the given users matched."; exit 1; } ;;
                3) echo -e "${CYAN}Resellers with accounts:${RESET}"
                   local reslist=() rline rnum rc rn ridx
                   mapfile -t reslist < <(printf '%s\n' "$rows" | cut -f1 | sort | uniq -c | awk '{print $1" "$2}')
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
                   rows=$(filter_reseller "$rows" "$RESELLER")
                   [ -n "$rows" ] || { error "No accounts found for reseller: $RESELLER"; exit 1; } ;;
                *) error "Invalid choice."; exit 1 ;;
            esac
        fi
    fi

    local total i=0 ok=0 fail=0 start=$SECONDS
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

    local dur; dur=$(fmt_duration $((SECONDS-start)))

    # Plain-text report kept alongside the data.
    {
        echo "Magic Move — SOURCE report"
        echo "Date       : $(date +'%F %T')"
        echo "Server IP  : $SERVER_IP"
        echo "Panel      : ${PANEL:-list}"
        [ -n "$RESELLER" ] && echo "Reseller   : $RESELLER"
        echo "Accounts   : $i"
        echo "Healthy    : $ok"
        echo "Problems   : $fail"
        echo "Duration   : $dur"
    } > "$REPORT_FILE"

    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Source snapshot written : $OUT_CSV"
    echo -e "  Page snapshots          : $SNAP_DIR/before/"
    echo -e "  Report                  : $REPORT_FILE"
    echo -e "  Accounts                : $i    (${GREEN}OK $ok${RESET} / ${YELLOW}Fail $fail${RESET})"
    echo -e "  Duration                : $dur"
    echo -e "${CYAN}════════════════════════════════════════════════${RESET}"
    echo -e "  Copy the ${YELLOW}$OUT_DIR/${RESET} folder to the destination, then:  magic-move.sh --destination"
    log "SOURCE done: $i accounts, OK=$ok Fail=$fail, ${dur} -> $OUT_CSV"

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

    local total=${#D[@]} i=0 okc=0 fixedc=0 failc=0 regress=0 bfail=0 plugc=0 start=$SECONDS
    mkdir -p "$SNAP_DIR/after"
    local out_tmp; out_tmp=$(mktemp)
    echo "user,domain,status_before,status_after" >> "$out_tmp"
    info "Accounts to verify: $total"
    echo

    local snap sa orig ver before_status DISABLED_PLUGINS
    for ((idx=0; idx<total; idx++)); do
        user="${U[$idx]}"; domain="${D[$idx]}"; before_status="${SB[$idx]}"
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
        echo "$user,$domain,$before_status,$sa" >> "$out_tmp"
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
    *)             error "Unknown mode: $MODE"; exit 1 ;;
esac
# finish_log (EXIT trap) prints the log path.
