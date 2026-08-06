#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Plugin Hunter
#   Scan a WordPress install for plugins and log results.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.7.0
# ════════════════════════════════════════════════════════════
VERSION="1.7.0"

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

# ---------- Culprit / Pinned Bookkeeping ----------
CULPRITS=()      # plugins confirmed to break the site; left disabled
PINNED=()        # plugins force-enabled as dependencies (e.g. WooCommerce)

is_culprit() { local x; for x in "${CULPRITS[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
is_pinned()  { local x; for x in "${PINNED[@]}";   do [[ "$x" == "$1" ]] && return 0; done; return 1; }

# Announce a pinned-down culprit and, in manual mode, let the operator decide
# whether it really stays disabled. Automate mode is hands-off, so it keeps it.
# Returns 0 to keep disabled, 1 to put it back.
keep_disabled() {
    local NAME="$1" ANS
    error "Identified and disabled: $NAME"
    [[ "$MODE" == "automate" ]] && return 0
    read -r -p "Keep \"$NAME\" disabled? [Y/n, c=cancel]: " ANS
    [[ "$ANS" =~ ^[Cc]$ ]] && cancel_scan
    [[ "$ANS" =~ ^[Nn]$ ]] && return 1
    return 0
}

# ---------- Verify Baseline ----------
# With every plugin disabled the site MUST be healthy. If it is still broken it
# is usually one of two things:
#   1. A theme (or must-use code) that fatals when WooCommerce is absent. If
#      WooCommerce is installed we pin it back on and re-check, so its absence
#      cannot masquerade as a plugin fault throughout the hunt.
#   2. A genuinely non-plugin fault (server, database, core, theme) — nothing to
#      hunt, so restore everything and bail out instead of chasing a ghost.
verify_baseline() {
    testmsg "All plugins disabled — check the site now: is it healthy?"
    ask_resolved
    if [[ "$RESOLVED" == "yes" ]]; then
        success "Baseline healthy — beginning the hunt."
        return
    fi

    # Common gotcha: a WooCommerce-dependent theme fatals without WooCommerce.
    if [ -d "$PLUGINS/woocommerce.off" ]; then
        echo
        info "Still broken with everything off, but WooCommerce is installed."
        info "Many themes require it — enabling WooCommerce and re-checking..."
        mv "$PLUGINS/woocommerce.off" "$PLUGINS/woocommerce" && PINNED+=("woocommerce")
        ask_resolved
        if [[ "$RESOLVED" == "yes" ]]; then
            success "Baseline healthy with WooCommerce pinned on — beginning the hunt."
            info "WooCommerce stays enabled and is excluded from the hunt."
            return
        fi
    fi

    echo
    error "Site is still broken with every plugin disabled — the cause is not a plugin."
    info "Restoring all plugins..."
    restore_all
    info "Log file: $LOG_FILE"
    exit 1
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
        is_pinned "$NAME" && continue          # pinned dependency: already enabled
        P="$PLUGINS/$NAME"
        [ -d "$P.off" ] || continue

        mv "$P.off" "$P"
        testmsg "Enabled: $NAME"
        sleep 2

        local broke="no"
        if [[ "$MODE" == "manual" ]]; then
            read -r -p "Enabled \"$NAME\". Did the issue come back? [y/N, c=cancel]: " MAN
            [[ "$MAN" =~ ^[Cc]$ ]] && cancel_scan
            [[ "$MAN" =~ ^[Yy]$ ]] && broke="yes"
        else
            RESULT=$(check_site)
            info "Site status: $RESULT"
            [[ "$RESULT" == "FAIL" ]] && broke="yes"
        fi

        if [[ "$broke" == "yes" ]]; then
            mv "$P" "$P.off"
            if keep_disabled "$NAME"; then
                problematic+=("$NAME")
            else
                mv "$P.off" "$P"
                info "Re-enabled $NAME at your request."
            fi
        else
            success "$NAME is OK."
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
# Iterative "peel": re-enable every non-culprit plugin and test the WHOLE site
# at once. If it is healthy, there is nothing (more) to find — stop. If it is
# broken, bisect the enabled suspects (disabling halves) to pin down ONE culprit,
# disable it, and loop. Re-checking the whole site after every find short-circuits
# the common single-culprit case and confirms the site actually ends up healthy;
# looping until it does surfaces EVERY culprit, not just the first.
# Odd counts are fine: the split uses floor(n/2), so a group never empties.

# isolate_one NAME...
# Precondition: the named plugins are all DISABLED and the site is healthy, with
# at least one culprit among them (pinned plugins are never passed in). Bisects
# by ENABLING halves — building up from the healthy baseline so other culprits
# stay off and cannot muddy the signal — until one culprit remains. Leaves that
# one disabled and returns its name in the global ISOLATED (empty if the fault
# turns out to need a combination of plugins).
#
# Building up (rather than tearing down from all-enabled) is what makes this
# correct when several culprits are present at once: only the half under test is
# ever live, so a break can only come from a culprit inside it.
ISOLATED=""
isolate_one() {
    local -a cands=("$@") A
    local n half NAME

    while (( ${#cands[@]} > 1 )); do
        n=${#cands[@]}
        half=$(( n / 2 ))
        A=("${cands[@]:0:half}")

        # Enable the first half only; the rest stay disabled.
        for NAME in "${A[@]}"; do
            [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
        done
        testmsg "Enabled ${#A[@]} of $n suspects; test the site."
        ask_resolved

        if [[ "$RESOLVED" == "no" ]]; then
            # A culprit is inside this half. Disable it again and narrow to it.
            for NAME in "${A[@]}"; do
                [ -d "$PLUGINS/$NAME" ] && mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off"
            done
            info "Breakage is in that half — narrowing to ${#A[@]}."
            cands=("${A[@]}")
        else
            # This half is clean; leave it enabled and narrow to the rest.
            info "That half is clean — narrowing to the other $(( n - ${#A[@]} ))."
            cands=("${cands[@]:half}")
        fi
    done

    # Confirm the lone suspect really breaks the site on its own.
    ISOLATED="${cands[0]}"
    [ -d "$PLUGINS/$ISOLATED.off" ] && mv "$PLUGINS/$ISOLATED.off" "$PLUGINS/$ISOLATED"
    testmsg "Enabled only $ISOLATED; test the site."
    ask_resolved
    if [[ "$RESOLVED" == "no" ]]; then
        mv "$PLUGINS/$ISOLATED" "$PLUGINS/$ISOLATED.off"
    else
        info "$ISOLATED alone did not break the site — likely a plugin combination."
        ISOLATED=""
    fi
}

binary_search() {
    local -a candidates=() huntable declined=()
    local NAME on

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
    while : ; do
        # Re-enable every non-culprit (pinned ones are already on) and test the
        # whole site — maybe nothing (more) is wrong and we can stop right here.
        on=0
        for NAME in "${candidates[@]}"; do
            is_culprit "$NAME" && continue
            [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
            (( on++ ))
        done
        testmsg "Enabled all $on non-culprit plugin(s) — test the whole site."
        ask_resolved
        [[ "$RESOLVED" == "yes" ]] && break

        # Broken → collect the non-pinned suspects and reset them to the healthy
        # baseline (all off) so isolate_one can build up cleanly from there.
        huntable=()
        for NAME in "${candidates[@]}"; do
            is_culprit "$NAME" && continue
            is_pinned "$NAME" && continue
            huntable+=("$NAME")
            [ -d "$PLUGINS/$NAME" ] && mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off"
        done
        if [ "${#huntable[@]}" -eq 0 ]; then
            error "Site is broken but no plugins remain to test — a pinned dependency or a non-plugin fault."
            break
        fi

        info "Site broken — isolating the next culprit among ${#huntable[@]} suspect(s)..."
        isolate_one "${huntable[@]}"

        if [ -z "$ISOLATED" ]; then
            error "Could not pin down a single culprit — the site breaks only on a plugin combination."
            info "Try linear mode or inspect the remaining plugins by hand."
            break
        fi

        if keep_disabled "$ISOLATED"; then
            CULPRITS+=("$ISOLATED")
            info "Keeping $ISOLATED disabled."
        else
            [ -d "$PLUGINS/$ISOLATED.off" ] && mv "$PLUGINS/$ISOLATED.off" "$PLUGINS/$ISOLATED"
            info "Re-enabled $ISOLATED at your request — ending the scan."
            declined+=("$ISOLATED")
            break
        fi
    done

    # However the loop ended, re-enable every plugin that is not a confirmed
    # culprit so the site is left in a consistent, known state.
    for NAME in "${candidates[@]}"; do
        is_culprit "$NAME" && continue
        [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
    done

    echo
    if [ "${#CULPRITS[@]}" -eq 0 ]; then
        success "Scan complete. No plugin is left disabled."
    else
        success "Scan complete. ${#CULPRITS[@]} problematic plugin(s) left disabled:"
        for NAME in "${CULPRITS[@]}"; do
            info "  - $NAME  (at $PLUGINS/$NAME.off)"
        done
    fi
    [ "${#declined[@]}" -gt 0 ] && info "Flagged but kept enabled at your request: ${declined[*]}"
    [ "${#PINNED[@]}" -gt 0 ] && info "Pinned on (kept enabled): ${PINNED[*]}"
    info "Log file: $LOG_FILE"
    exit 0
}

if [[ "$STRATEGY" == "binary" ]]; then
    binary_search
else
    linear_search
fi
