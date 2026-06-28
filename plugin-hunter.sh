#!/bin/bash

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

banner(){
echo -e "${CYAN}
===========================================
     WP Plugin Hunter – Optimized Edition
===========================================
${RESET}"
}
banner

# ---------- WP Path ----------
if [ -n "$1" ]; then
    WP_DIR="$1"
else
    WP_DIR="$(pwd -P)"
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

# ---------- Cleanup on Interrupt ----------
CURRENT=""
cleanup(){
    if [ -n "$CURRENT" ] && [ -d "$CURRENT.off" ]; then
        mv "$CURRENT.off" "$CURRENT"
        info "Restored: $(basename "$CURRENT")"
    fi
}
trap cleanup INT TERM

# ---------- Domain ----------
read -r -p "Enter domain (without https://): " DOMAIN
BASE_URL="https://$DOMAIN/wp-json/"
info "API endpoint: $BASE_URL"

# ---------- API Check ----------
check_wp_api() {
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL")
    [[ "$HTTP_CODE" == "200" ]] && echo "OK" || echo "FAIL"
}

# ---------- Confirm Problematic Plugin ----------
confirm_problem() {
    read -r -p "Plugin \"$1\" seems to fix the issue. Mark it as problematic and keep it disabled? [y/N]: " CHOICE
    [[ "$CHOICE" =~ ^[Yy]$ ]] && return 0 || return 1
}

#############################################
#                PHASE 1                   #
#############################################

echo
info "Phase 1 – Testing plugins individually..."

for NAME in "${PLUGS[@]}"; do
    [[ "$NAME" == *.off ]] && continue

    P="$PLUGINS/$NAME"
    CURRENT="$P"

    mv "$P" "$P.off" || { error "Failed to disable $NAME"; continue; }
    testmsg "Disabled: $NAME"

    if [[ "$MODE" == "manual" ]]; then
        read -r -p "Check your site manually. Is the issue resolved? [y/N]: " MAN
        if [[ "$MAN" =~ ^[Yy]$ ]]; then
            if confirm_problem "$NAME"; then
                success "Problematic plugin found: $NAME"
                exit 0
            else
                mv "$P.off" "$P"
                info "Restored: $NAME"
                CURRENT=""
            fi
            continue
        fi
    else
        RESULT=$(check_wp_api)
        info "API Status: $RESULT"

        if [[ "$RESULT" == "OK" ]]; then
            if confirm_problem "$NAME"; then
                success "Problematic plugin found: $NAME"
                info "Left disabled at: $P.off"
                exit 0
            else
                mv "$P.off" "$P"
                info "Restored: $NAME"
                CURRENT=""
            fi
            continue
        fi
    fi

    mv "$P.off" "$P"
    info "Restored: $NAME"
    CURRENT=""
done

#############################################
#                PHASE 2                   #
#############################################

# echo
# info "Phase 1 did not find a problem. Starting Phase 2..."

# # Disable ALL
# for NAME in "${PLUGS[@]}"; do
#     [[ "$NAME" == *.off ]] && continue
#     mv "$PLUGINS/$NAME" "$PLUGINS/$NAME.off" || error "Failed to disable $NAME"
# done
# success "All plugins disabled."

# # Enable one-by-one
# for NAME in "${PLUGS[@]}"; do
#     P="$PLUGINS/$NAME"

#     if [ -d "$P.off" ]; then
#         mv "$P.off" "$P"
#         testmsg "Testing plugin: $NAME"
#         sleep 2
#     fi

#     RESULT=$(check_wp_api)
#     info "API Status: $RESULT"

#     if [[ "$RESULT" == "FAIL" ]]; then
#         error "$NAME is problematic. Disabling again."
#         mv "$P" "$P.off"
#     else
#         success "$NAME is OK."
#     fi
# done

echo
success "Scan complete."
info "Problematic plugins remain disabled (*.off)."
info "Log file: $LOG_FILE"
echo
#############################################
