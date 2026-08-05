#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Plugin Hunter
#   Scan a WordPress install for plugins and log results.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.6.0
# ════════════════════════════════════════════════════════════
VERSION="1.6.0"

# ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------- Logging ----------
LOG_FILE="/var/log/plugin-hunter.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="./plugin-hunter.log"

log() {
    echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"
}

info(){ echo -e "${YELLOW}[INFO]${RESET} $*"; log "[INFO] $*"; }
success(){ echo -e "${GREEN}[OK]${RESET} $*"; log "[OK] $*"; }
error(){ echo -e "${RED}[ERROR]${RESET} $*"; log "[ERROR] $*"; }
testmsg(){ echo -e "${BLUE}[TEST]${RESET} $*"; log "[TEST] $*"; }

# ---------- Usage ----------
usage() {
    cat <<EOF
Usage: plugin-hunter.sh [options] [path]

Scan a WordPress install to find the plugin(s) that break the site.
Every option is optional; anything you omit is asked for interactively,
so the script stays fully usable with no arguments at all.

Options:
  -d, --domain <domain>   Domain used to resolve the webroot and, in automate
                          mode, to build the health-check URL.
  -p, --path <path>       Explicit path to the WordPress install (skips domain
                          lookup). A bare positional path works too.
  -m, --manual            Manual mode  — you verify the site by hand.
  -a, --automate          Automate mode — HTTP health check does the verifying.
  -l, --linear            Linear strategy — disable all, enable one-by-one.
  -b, --binary            Binary strategy — disable all, bisect by enabling.
  -h, --help              Show this help and exit.

Examples:
  plugin-hunter.sh
  plugin-hunter.sh -d bob.ir --automate --binary
  plugin-hunter.sh -p /home/u/public_html --manual --linear
EOF
}

# ---------- Parse Arguments ----------
# Flags let every prompt be answered up-front for non-interactive runs; any
# value left unset simply falls back to its interactive prompt further down.
DOMAIN=""
WP_DIR=""
MODE=""
STRATEGY=""

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)
            [ -n "$2" ] || { error "$1 requires a value."; exit 1; }
            DOMAIN="$2"; shift 2 ;;
        -p|--path)
            [ -n "$2" ] || { error "$1 requires a value."; exit 1; }
            WP_DIR="$2"; shift 2 ;;
        -m|--manual)   MODE="manual"; shift ;;
        -a|--automate) MODE="automate"; shift ;;
        -l|--linear)   STRATEGY="linear"; shift ;;
        -b|--binary)   STRATEGY="binary"; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            error "Unknown option: $1"; usage; exit 1 ;;
        *)             WP_DIR="$1"; shift ;;   # bare positional path
    esac
done

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Plugin Hunter${N}"
    echo -e "  Scan a WordPress install for plugins and log results."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}
print_header

# ---------- Resolve WordPress Path ----------
# An explicit path as $1 always wins. Otherwise ask for a domain and locate its
# webroot on the server (cPanel / DirectAdmin); an empty answer falls back to
# the current directory. A resolved domain is reused for the automate health
# check below, so it is never asked for twice.
resolve_webroot() {
    local USER U MAINDOMAIN CONF CONF_DOMAIN DOCROOT
    if [ -z "$DOMAIN" ]; then
        read -r -p "Enter domain (or press Enter to use the current directory): " DOMAIN
    fi

    if [ -z "$DOMAIN" ]; then
        WP_DIR="$(pwd -P)"
        info "No domain entered. Using current directory: $WP_DIR"
        return 0
    fi

    # cPanel
    if [ -d "/usr/local/cpanel" ]; then
        info "Control panel detected: cPanel"
        for USER in /var/cpanel/users/*; do
            [ -f "$USER" ] || continue
            U=$(basename "$USER")

            # Main domain
            MAINDOMAIN=$(grep "^DNS=" "$USER" | cut -d= -f2)
            if [ "$MAINDOMAIN" = "$DOMAIN" ]; then
                WP_DIR="/home/$U/public_html"
                break
            fi

            # Addon / parked domains
            if [ -f "/var/cpanel/userdata/$U/$DOMAIN" ]; then
                WP_DIR=$(grep "documentroot:" "/var/cpanel/userdata/$U/$DOMAIN" | awk '{print $2}')
                break
            fi
        done
    fi

    # DirectAdmin
    if [ -d "/usr/local/directadmin" ] && [ -z "$WP_DIR" ]; then
        info "Control panel detected: DirectAdmin"
        for USER in /usr/local/directadmin/data/users/*; do
            [ -d "$USER/domains" ] || continue
            U=$(basename "$USER")
            for CONF in "$USER/domains"/*.conf; do
                [ -f "$CONF" ] || continue
                CONF_DOMAIN=$(basename "$CONF" .conf)
                if [ "$CONF_DOMAIN" = "$DOMAIN" ]; then
                    DOCROOT=$(grep "^document_root=" "$CONF" | cut -d= -f2)
                    WP_DIR=${DOCROOT:-"/home/$U/domains/$DOMAIN/public_html"}
                    break 2
                fi
            done
        done
    fi

    if [ -z "$WP_DIR" ]; then
        error "Domain '$DOMAIN' not found on this server (cPanel/DirectAdmin)."
        return 1
    fi

    info "Resolved webroot: $WP_DIR"
    return 0
}

# ---------- WP Path ----------
# A path from -p / positional wins outright; otherwise resolve from the domain
# (which resolve_webroot prompts for only when -d was not supplied).
if [ -z "$WP_DIR" ]; then
    resolve_webroot || exit 1
fi

PLUGINS="$WP_DIR/wp-content/plugins"
PLUGINS_OFF="$WP_DIR/wp-content/plugins.off"

info "Target WordPress path: $WP_DIR"

# ---------- Mode Selection ----------
# Skip the prompt when -m/-a already set the mode.
if [ -z "$MODE" ]; then
    echo -e "${CYAN}Select mode:${RESET}"
    echo "1) manual"
    echo "2) automate"
    read -r -p "Enter choice (1 or 2): " MODE_CHOICE

    if [[ "$MODE_CHOICE" == "1" ]]; then
        MODE="manual"
    elif [[ "$MODE_CHOICE" == "2" ]]; then
        MODE="automate"
    else
        error "Invalid mode selection."
        exit 1
    fi
fi

info "Mode selected: $MODE"

# ---------- Strategy Selection ----------
# Both strategies start from the same baseline: every plugin disabled, a healthy
# site. They differ only in how they re-enable plugins to pin down the culprit.
# Skip the prompt when -l/-b already set the strategy.
if [ -z "$STRATEGY" ]; then
    echo -e "${CYAN}Select search strategy:${RESET}"
    echo "1) linear  (disable all, then enable one-by-one — finds every culprit)"
    echo "2) binary  (disable all, then bisect by enabling — faster, one culprit)"
    read -r -p "Enter choice (1 or 2): " STRATEGY_CHOICE

    if [[ "$STRATEGY_CHOICE" == "1" ]]; then
        STRATEGY="linear"
    elif [[ "$STRATEGY_CHOICE" == "2" ]]; then
        STRATEGY="binary"
    else
        error "Invalid strategy selection."
        exit 1
    fi
fi

info "Strategy selected: $STRATEGY"

# ---------- Validate WP Directories ----------
if [ ! -d "$PLUGINS" ] && [ ! -d "$PLUGINS_OFF" ]; then
    error "Neither plugins nor plugins.off directory exists."
    exit 1
fi

if [ ! -d "$PLUGINS" ] && [ -d "$PLUGINS_OFF" ]; then
    info "Restoring plugins directory"
    mv "$PLUGINS_OFF" "$PLUGINS" || { error "Restore failed."; exit 1; }
fi

[ -d "$PLUGINS" ] || { error "Plugins directory missing."; exit 1; }

# ---------- Build Plugin List ----------
mapfile -d '' PLUGS < <(find "$PLUGINS" -mindepth 1 -maxdepth 1 -type d -printf '%f\0' | sort -z)

if [ ${#PLUGS[@]} -eq 0 ]; then
    error "No plugins found."
    exit 1
fi

# ---------- Restore / Cancel ----------
restore_all(){
    shopt -s nullglob
    for OFF in "$PLUGINS"/*.off; do
        [ -d "$OFF" ] || continue
        ORIG="${OFF%.off}"
        mv "$OFF" "$ORIG" && info "Restored: $(basename "$ORIG")"
    done
    shopt -u nullglob
}

cancel_scan(){
    echo
    info "Cancelling scan — restoring all plugins to their original state..."
    restore_all
    success "All plugins restored. Scan cancelled."
    exit 0
}

# On Ctrl+C / TERM, leave the site exactly as we found it.
trap cancel_scan INT TERM

# ---------- Domain (automate mode only) ----------
# Automate mode needs a domain for the HTTP health check. Reuse the one entered
# during webroot resolution if we have it; only prompt when it is still unknown
# (e.g. a path was passed as $1). Manual mode inspects the site by hand and
# never needs it.
if [[ "$MODE" == "automate" ]]; then
    if [ -z "$DOMAIN" ]; then
        read -r -p "Enter domain (without https://): " DOMAIN
    fi
    CHECK_URL="https://$DOMAIN/"
    info "Health-check URL: $CHECK_URL"
fi

# ---------- Site Health Check ----------
# A working WordPress front page responds with HTTP 200 AND a fully rendered
# page. HTTP 200 alone is not enough: a broken plugin often triggers a PHP fatal
# error *after* wp_head() has already flushed the <head>, so the status line
# stays 200 while the body is cut off mid-render (no </html>) or replaced by
# WordPress's critical-error notice. Checking only the code would mark such a
# "200-but-broken" homepage OK — exactly the failure this guards against.
#
# We probe the real front page, NOT /wp-json/: the REST endpoint keeps
# returning 200 even while the public site is broken, which would make automate
# mode declare the first disabled plugin "the fix" on every run.
check_site() {
    local resp code body
    # Fetch body + status in one request; -w appends the code on its own line.
    resp=$(curl -s -L -w '\n%{http_code}' \
        --connect-timeout 10 --max-time 25 "$CHECK_URL")
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    if [[ "$code" != "200" ]]; then
        echo "FAIL"
    elif grep -qiE 'there has been a critical error|<b>Fatal error|WordPress database error' <<<"$body"; then
        echo "FAIL"
    elif ! grep -qi '</html>' <<<"$body"; then
        echo "FAIL"
    else
        echo "OK"
    fi
}

# ---------- Resolved Check (sets RESOLVED to yes/no) ----------
# Manual mode asks the user; automate mode probes the site's front page.
ask_resolved() {
    RESOLVED="no"
    if [[ "$MODE" == "manual" ]]; then
        read -r -p "Is the issue resolved now? [y/N, c=cancel]: " ANS
        [[ "$ANS" =~ ^[Cc]$ ]] && cancel_scan
        [[ "$ANS" =~ ^[Yy]$ ]] && RESOLVED="yes"
    else
        local RESULT
        RESULT=$(check_site)
        info "Site status: $RESULT"
        [[ "$RESULT" == "OK" ]] && RESOLVED="yes"
    fi
}

# ---------- Disable Every Plugin ----------
# Both strategies begin from a clean baseline — all plugins off, site healthy —
# and then re-enable plugins to find what breaks it. This surfaces cases the old
# "disable one at a time" flow missed, where two or three plugins only break the
# site when they are active together.
disable_all() {
    local NAME
    for NAME in "${PLUGS[@]}"; do
        [[ "$NAME" == *.off ]] && continue
        mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off" || error "Failed to disable $NAME"
    done
    success "All plugins disabled — starting from a clean baseline."
}

# ---------- Verify Baseline ----------
# With every plugin disabled the site MUST be healthy. If it is still broken,
# the fault is not a plugin (theme, server, database, core...) and there is
# nothing to hunt — restore everything and bail out instead of chasing a ghost.
verify_baseline() {
    testmsg "All plugins disabled — check the site now: is it healthy?"
    ask_resolved
    if [[ "$RESOLVED" != "yes" ]]; then
        echo
        error "Site is still broken with every plugin disabled — the cause is not a plugin."
        info "Restoring all plugins..."
        restore_all
        info "Log file: $LOG_FILE"
        exit 1
    fi
    success "Baseline healthy — beginning the hunt."
}

#############################################
#             LINEAR SEARCH                 #
#############################################
# Disable everything, then re-enable plugins one-by-one. After each is enabled
# we check the site; if it breaks, that plugin is problematic — it is disabled
# again and recorded, and the scan moves on. This reports EVERY culprit, not
# just the first, so independent breakages are all caught in a single run.
linear_search() {
    local NAME P RESULT
    local -a problematic=()

    echo
    info "Linear search over ${#PLUGS[@]} plugin(s)."
    info "(At any prompt, enter 'c' to cancel and restore all plugins.)"

    disable_all
    verify_baseline

    for NAME in "${PLUGS[@]}"; do
        [[ "$NAME" == *.off ]] && continue
        P="$PLUGINS/$NAME"
        [ -d "$P.off" ] || continue

        mv "$P.off" "$P"
        testmsg "Enabled: $NAME"
        sleep 2

        if [[ "$MODE" == "manual" ]]; then
            read -r -p "Enabled \"$NAME\". Did the issue come back? [y/N, c=cancel]: " MAN
            [[ "$MAN" =~ ^[Cc]$ ]] && cancel_scan
            if [[ "$MAN" =~ ^[Yy]$ ]]; then
                error "$NAME is problematic. Disabling again."
                mv "$P" "$P.off"
                problematic+=("$NAME")
            else
                success "$NAME is OK."
            fi
        else
            RESULT=$(check_site)
            info "Site status: $RESULT"
            if [[ "$RESULT" == "FAIL" ]]; then
                error "$NAME is problematic. Disabling again."
                mv "$P" "$P.off"
                problematic+=("$NAME")
            else
                success "$NAME is OK."
            fi
        fi
    done

    echo
    if [ "${#problematic[@]}" -eq 0 ]; then
        success "Scan complete. No problematic plugin found — all re-enabled."
    else
        success "Scan complete. ${#problematic[@]} problematic plugin(s) left disabled:"
        for NAME in "${problematic[@]}"; do
            info "  - $NAME  (at $PLUGINS/$NAME.off)"
        done
    fi
    info "Log file: $LOG_FILE"
    exit 0
}

#############################################
#             BINARY SEARCH                 #
#############################################
# Disable everything, then bisect by ENABLING — and, unlike a single-culprit
# search, always explore BOTH halves so every problematic plugin is found:
#
#   bisect(group):                       # group starts fully disabled, site OK
#     enable the whole group, test the site
#       healthy -> the group is clean; leave it enabled and return
#       broken  -> a culprit is inside; disable the group again, split in two,
#                  and bisect each half. The second half is never dropped, so
#                  culprits hiding there are found too.
#     a group of one that breaks the site is itself a culprit: keep it disabled.
#
# Whenever a half is cleared the search moves on to the other half, but it never
# forgets that other half — the goal is to surface ALL culprits, not just one.
# Odd counts are fine: the split uses floor(n/2), so a group never empties.

CULPRITS=()

# bisect NAME...
# Precondition: every plugin in the list is disabled and the site is healthy.
# On return the group's safe plugins are enabled, its culprits are disabled and
# appended to CULPRITS, and the site is healthy again.
bisect() {
    local -a group=("$@")
    local n=${#group[@]} NAME half

    (( n == 0 )) && return

    if (( n == 1 )); then
        NAME="${group[0]}"
        [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
        testmsg "Enabled: $NAME — test the site."
        ask_resolved
        if [[ "$RESOLVED" == "yes" ]]; then
            success "$NAME is OK."
        else
            error "$NAME is problematic. Disabling again."
            mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off"
            CULPRITS+=("$NAME")
        fi
        return
    fi

    # Enable the whole group at once; a healthy site clears all of them cheaply.
    for NAME in "${group[@]}"; do
        [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
    done
    testmsg "Enabled $n plugin(s) at once — test the site."
    ask_resolved
    if [[ "$RESOLVED" == "yes" ]]; then
        success "All $n plugin(s) in this group are OK."
        return
    fi

    # A culprit is inside this group. Disable it again, then dig into both halves.
    info "Breakage is inside this group of $n — narrowing into both halves..."
    for NAME in "${group[@]}"; do
        [ -d "$PLUGINS/$NAME" ] && mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off"
    done

    half=$(( n / 2 ))
    bisect "${group[@]:0:half}"
    bisect "${group[@]:half}"
}

binary_search() {
    local -a candidates=()
    local NAME n half

    for NAME in "${PLUGS[@]}"; do
        [[ "$NAME" == *.off ]] && continue
        candidates+=("$NAME")
    done

    echo
    info "Binary search over ${#candidates[@]} plugin(s)."
    info "(At any prompt, enter 'c' to cancel and restore all plugins.)"

    disable_all
    verify_baseline

    CULPRITS=()
    n=${#candidates[@]}
    half=$(( n / 2 ))
    # Split at the top: re-enabling the whole (already-broken) set proves nothing,
    # so we start one level down and let bisect explore each half.
    bisect "${candidates[@]:0:half}"
    bisect "${candidates[@]:half}"

    echo
    if [ "${#CULPRITS[@]}" -eq 0 ]; then
        success "Scan complete. No problematic plugin found — all re-enabled."
    else
        success "Scan complete. ${#CULPRITS[@]} problematic plugin(s) left disabled:"
        for NAME in "${CULPRITS[@]}"; do
            info "  - $NAME  (at $PLUGINS/$NAME.off)"
        done
    fi
    info "Log file: $LOG_FILE"
    exit 0
}

if [[ "$STRATEGY" == "binary" ]]; then
    binary_search
else
    linear_search
fi
