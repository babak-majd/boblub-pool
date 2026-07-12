#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Plugin Hunter
#   Scan a WordPress install for plugins and log results.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
# ════════════════════════════════════════════════════════════

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
    read -r -p "Enter domain (or press Enter to use the current directory): " DOMAIN

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
WP_DIR=""
if [ -n "$1" ]; then
    WP_DIR="$1"
else
    resolve_webroot || exit 1
fi

PLUGINS="$WP_DIR/wp-content/plugins"
PLUGINS_OFF="$WP_DIR/wp-content/plugins.off"

info "Target WordPress path: $WP_DIR"

# ---------- Mode Selection ----------
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

info "Mode selected: $MODE"

# ---------- Strategy Selection ----------
echo -e "${CYAN}Select search strategy:${RESET}"
echo "1) linear  (test plugins one-by-one — Phase 1, then Phase 2)"
echo "2) binary  (bisection — disables half at a time, much faster)"
read -r -p "Enter choice (1 or 2): " STRATEGY_CHOICE

if [[ "$STRATEGY_CHOICE" == "1" ]]; then
    STRATEGY="linear"
elif [[ "$STRATEGY_CHOICE" == "2" ]]; then
    STRATEGY="binary"
else
    error "Invalid strategy selection."
    exit 1
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

# ---------- Confirm Problematic Plugin ----------
confirm_problem() {
    read -r -p "Plugin \"$1\" seems to fix the issue. Mark it as problematic and keep it disabled? [y/N, c=cancel]: " CHOICE
    [[ "$CHOICE" =~ ^[Cc]$ ]] && cancel_scan
    [[ "$CHOICE" =~ ^[Yy]$ ]] && return 0 || return 1
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

#############################################
#             BINARY SEARCH                 #
#############################################
# Assumes a single problematic plugin. Each round disables half of the
# remaining candidates and checks whether the issue is resolved:
#   - resolved  -> culprit is in the disabled half  (narrow to that half)
#   - unresolved-> culprit is in the still-active half (narrow to it)
# Odd counts are fine: the split uses floor(n/2), so a group never empties.
binary_search() {
    local -a candidates=()
    local NAME
    for NAME in "${PLUGS[@]}"; do
        [[ "$NAME" == *.off ]] && continue
        candidates+=("$NAME")
    done

    echo
    info "Binary search over ${#candidates[@]} plugin(s)..."
    info "(At any prompt, enter 'c' to cancel and restore all plugins.)"

    while [ "${#candidates[@]}" -gt 1 ]; do
        local n=${#candidates[@]}
        local half=$(( n / 2 ))
        local -a groupA=("${candidates[@]:0:half}")
        local -a groupB=("${candidates[@]:half}")

        # Disable group A, keep group B (and everything else) active.
        for NAME in "${groupA[@]}"; do
            mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off" || error "Failed to disable $NAME"
        done
        testmsg "Disabled ${#groupA[@]} of $n candidates; ${#groupB[@]} still active. Test the site."

        ask_resolved

        # Re-enable group A regardless; we only narrow the candidate set.
        for NAME in "${groupA[@]}"; do
            [ -d "$PLUGINS/$NAME.off" ] && mv "$PLUGINS/$NAME.off" "$PLUGINS/$NAME"
        done

        if [[ "$RESOLVED" == "yes" ]]; then
            info "Culprit is among the ${#groupA[@]} disabled plugin(s)."
            candidates=("${groupA[@]}")
        else
            info "Culprit is among the ${#groupB[@]} active plugin(s)."
            candidates=("${groupB[@]}")
        fi
    done

    local CULPRIT="${candidates[0]}"
    local P="$PLUGINS/$CULPRIT"

    echo
    info "Binary search narrowed down to: $CULPRIT"
    mv "$P" "$P.off" || { error "Failed to disable $CULPRIT"; exit 1; }
    testmsg "Disabled: $CULPRIT — verify the site one last time."

    ask_resolved
    if [[ "$RESOLVED" == "yes" ]]; then
        if confirm_problem "$CULPRIT"; then
            success "Problematic plugin found: $CULPRIT"
            info "Left disabled at: $P.off"
            exit 0
        fi
    else
        error "Disabling $CULPRIT did not resolve the issue."
        info "The problem may involve multiple plugins; try linear mode."
    fi

    mv "$P.off" "$P"
    info "Restored: $CULPRIT"
    exit 0
}

if [[ "$STRATEGY" == "binary" ]]; then
    binary_search
fi

#############################################
#                PHASE 1                   #
#############################################

echo
info "Phase 1 - Testing plugins individually..."
info "(At any prompt, enter 'c' to cancel and restore all plugins.)"

for NAME in "${PLUGS[@]}"; do
    [[ "$NAME" == *.off ]] && continue

    P="$PLUGINS/$NAME"

    mv "$P" "$P.off" || { error "Failed to disable $NAME"; continue; }
    testmsg "Disabled: $NAME"

    if [[ "$MODE" == "manual" ]]; then
        read -r -p "Check your site manually. Is the issue resolved? [y/N, c=cancel]: " MAN
        [[ "$MAN" =~ ^[Cc]$ ]] && cancel_scan
        if [[ "$MAN" =~ ^[Yy]$ ]]; then
            if confirm_problem "$NAME"; then
                success "Problematic plugin found: $NAME"
                info "Left disabled at: $P.off"
                exit 0
            else
                mv "$P.off" "$P"
                info "Restored: $NAME"
            fi
            continue
        fi
    else
        RESULT=$(check_site)
        info "Site status: $RESULT"

        if [[ "$RESULT" == "OK" ]]; then
            if confirm_problem "$NAME"; then
                success "Problematic plugin found: $NAME"
                info "Left disabled at: $P.off"
                exit 0
            else
                mv "$P.off" "$P"
                info "Restored: $NAME"
            fi
            continue
        fi
    fi

    mv "$P.off" "$P"
    info "Restored: $NAME"
done

#############################################
#                PHASE 2                   #
#############################################

echo
info "Phase 1 did not find a problem. Starting Phase 2..."
info "(At any prompt, enter 'c' to cancel and restore all plugins.)"

read -r -p "Proceed with Phase 2 (disable all, enable one-by-one)? [Y/n, c=cancel]: " P2
[[ "$P2" =~ ^[Cc]$ ]] && cancel_scan
if [[ "$P2" =~ ^[Nn]$ ]]; then
    info "Phase 2 skipped by user."
else
    # Disable ALL
    for NAME in "${PLUGS[@]}"; do
        [[ "$NAME" == *.off ]] && continue
        mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off" || error "Failed to disable $NAME"
    done
    success "All plugins disabled."

    # Enable one-by-one
    for NAME in "${PLUGS[@]}"; do
        P="$PLUGINS/$NAME"

        if [ -d "$P.off" ]; then
            mv "$P.off" "$P"
            testmsg "Testing plugin: $NAME"
            sleep 2
        fi

        if [[ "$MODE" == "manual" ]]; then
            read -r -p "Enabled \"$NAME\". Did the issue come back? [y/N, c=cancel]: " MAN
            [[ "$MAN" =~ ^[Cc]$ ]] && cancel_scan
            if [[ "$MAN" =~ ^[Yy]$ ]]; then
                error "$NAME is problematic. Disabling again."
                mv "$P" "$P.off"
            else
                success "$NAME is OK."
            fi
        else
            RESULT=$(check_site)
            info "Site status: $RESULT"

            if [[ "$RESULT" == "FAIL" ]]; then
                error "$NAME is problematic. Disabling again."
                mv "$P" "$P.off"
            else
                success "$NAME is OK."
            fi
        fi
    done
fi

echo
success "Scan complete."
info "Problematic plugins remain disabled (*.off)."
info "Log file: $LOG_FILE"
echo
#############################################
