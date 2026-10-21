#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Pro Plugin Manager
#   Menu-driven WordPress plugin operations.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.8.0
# ════════════════════════════════════════════════════════════
VERSION="1.8.0"


#############################################
#  COLOR PALETTE (Professional Terminal UI)
#############################################
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
NC='\033[0m'

#############################################
#  LOGGING  (standard block — identical across all bobclub scripts)
#############################################
# One directory per script under /var/log, a sub-directory per target (the domain
# or user; empty for whole-server scripts), and one timestamped file per run.
# start_log <key> begins capturing the whole run to that file (colors stripped)
# via tee once the target key is known; it falls back to /tmp when /var/log is
# not writable (e.g. not root). finish_log() prints the final path on any exit.
# Self-contained (literal colors, set -u safe) so the block stays byte-identical
# between scripts.
SCRIPT_NAME="pro-plugin-manager"
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

# Globals filled in by helpers
WEBROOT=""
ControlPanel=""
OWNER=""
GROUP=""
WP_CMD=""
START_DIR="$PWD"    # where the script was started (relative --from paths)
DB_CLI="mysql"      # prefer the mariadb client when present (detect_db_client)

# Prefer the mariadb client over the deprecated 'mysql' name when present.
detect_db_client() {
    command -v mariadb >/dev/null 2>&1 && DB_CLI="mariadb"
}

# DB credentials (filled by parse_wp_config)
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST=""
DB_PORT=""
DB_PREFIX=""

# CLI flags (filled by the argument parser below)
DOMAIN=""
WP_PATH=""
FEATURE=""          # woocommerce | elementor | search | blueguard | plugins
PLUGIN_ACTION=""    # repair | update | install | rollback
REQ_VERSION=""      # version for --install
ASSUME_YES=""       # auto-activate after install, auto-confirm rollback
NO_ACTIVATE=""      # skip activation without asking
SR_OLD=""           # search & replace: old value
SR_NEW=""           # search & replace: new value
SR_NEW_SET=""       # whether --new was given (an empty new value is valid)
SR_MODE=""          # search & replace mode: count | apply
PM_ACTION=""        # plugin manager (wp-cli): install | list | activate | deactivate | delete
PM_SRC=""           # plugin manager: zip URL or local path for install
PM_SLUG=""          # plugin manager: plugin slug for activate / deactivate / delete
PM_UNINSTALL=""     # plugin manager: run the plugin's uninstall routine on delete


#############################################
#  USAGE + ARGUMENT PARSING
#############################################
# Flags let every prompt be answered up-front for non-interactive runs; any
# value left unset simply falls back to its interactive prompt further down.
usage() {
    cat <<EOF
Usage: pro-plugin-manager.sh [options] [path]

Menu-driven WordPress plugin operations: manage WooCommerce or Elementor,
search & replace across the whole database, install Blue Guard, or manage
any plugin through wp-cli (install from a link or path, list, activate,
deactivate, delete).
Every option is optional; anything you omit is asked for interactively,
so the script stays fully usable with no arguments at all.

Options:
  -d, --domain <domain>   Domain used to resolve the webroot (cPanel/DirectAdmin).
  -p, --path <path>       Explicit path to the webroot (skips domain lookup).
                          A bare positional path works too.

  Feature (which menu item to run):
  -w, --woocommerce       Manage the WooCommerce plugin.
  -e, --elementor         Manage the Elementor plugin.
  -s, --search-replace    Search & replace across the whole database.
  -g, --blue-guard        Install the latest Blue Guard.
  -m, --plugins           Plugin manager (wp-cli) — any plugin, see below.

  Plugin action (with -w / -e):
  -r, --repair            Repair the current version.
  -u, --update            Update to the latest version.
  -i, --install           Install a specific version (see -V; asked if omitted).
  -b, --rollback          Roll back to the previous copy (old-<slug>/).
  -V, --version <ver>     Version for --install (e.g. 10.9.0).
  -y, --yes               Activate after install / confirm rollback without asking.
      --no-activate       Skip the post-install activation without asking.

  Search & replace (with -s):
  -o, --old <value>       Value to search for.
  -n, --new <value>       Value to replace it with.
      --dry-run           Count matches only, change nothing.
      --apply             Perform the replacement.

  Plugin manager (with -m; each of these also implies -m). Everything runs
  through wp-cli so WordPress loads normally and the plugin's own
  activation / deactivation / uninstall hooks fire:
      --from <url|path>   Install a plugin zip from a link or a local path.
      --list              List the installed plugins.
      --activate <slug>   Activate a plugin.
      --deactivate <slug> Deactivate a plugin.
      --delete <slug>     Delete a plugin (deactivated first; a copy is kept
                          in old-<slug>/). Asks whether to run its uninstall.
      --uninstall         With --delete: run the plugin's uninstall routine
                          (removes its settings / tables) without asking.
      -y also activates after install, overwrites an installed copy and
      confirms the delete; --no-activate skips the activation.

  -h, --help              Show this help and exit.

Examples:
  pro-plugin-manager.sh
  pro-plugin-manager.sh -d site.ir --woocommerce --update -y
  pro-plugin-manager.sh -p /home/u/public_html -e --install --version 3.21.0
  pro-plugin-manager.sh -d site.ir -s --old http://old.ir --new https://new.ir --dry-run
  pro-plugin-manager.sh -d site.ir --blue-guard
  pro-plugin-manager.sh -d site.ir --from https://example.com/plugin.zip -y
  pro-plugin-manager.sh -d site.ir --deactivate hello-dolly
EOF
}

# Only one feature / plugin action may be chosen at a time.
set_feature() {
    if [ -n "$FEATURE" ] && [ "$FEATURE" != "$1" ]; then
        echo -e "${RED}✘ Only one feature may be given at a time.${NC}" >&2
        exit 1
    fi
    FEATURE="$1"
}
set_pmaction() {
    if [ -n "$PM_ACTION" ] && [ "$PM_ACTION" != "$1" ]; then
        echo -e "${RED}✘ Only one plugin-manager action may be given at a time.${NC}" >&2
        exit 1
    fi
    PM_ACTION="$1"
    set_feature plugins
}
set_paction() {
    if [ -n "$PLUGIN_ACTION" ] && [ "$PLUGIN_ACTION" != "$1" ]; then
        echo -e "${RED}✘ Only one plugin action may be given at a time.${NC}" >&2
        exit 1
    fi
    PLUGIN_ACTION="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)        [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; DOMAIN="$2"; shift 2 ;;
        -p|--path)          [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; WP_PATH="$2"; shift 2 ;;
        -V|--version)       [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; REQ_VERSION="$2"; shift 2 ;;
        -o|--old)           [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; SR_OLD="$2"; shift 2 ;;
        -n|--new)           [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; SR_NEW="$2"; SR_NEW_SET="yes"; shift 2 ;;
        -w|--woocommerce)   set_feature woocommerce; shift ;;
        -e|--elementor)     set_feature elementor;   shift ;;
        -s|--search-replace) set_feature search;     shift ;;
        -g|--blue-guard)    set_feature blueguard;   shift ;;
        -m|--plugins)       set_feature plugins;     shift ;;
        --from)             [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; PM_SRC="$2"; set_pmaction install; shift 2 ;;
        --list)             set_pmaction list;       shift ;;
        --activate)         [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; PM_SLUG="$2"; set_pmaction activate;   shift 2 ;;
        --deactivate)       [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; PM_SLUG="$2"; set_pmaction deactivate; shift 2 ;;
        --delete)           [ -n "${2+x}" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; PM_SLUG="$2"; set_pmaction delete;     shift 2 ;;
        --uninstall)        PM_UNINSTALL="yes";      shift ;;
        -r|--repair)        set_paction repair;      shift ;;
        -u|--update)        set_paction update;      shift ;;
        -i|--install)       set_paction install;     shift ;;
        -b|--rollback)      set_paction rollback;    shift ;;
        -y|--yes)           ASSUME_YES="yes";        shift ;;
        --no-activate)      NO_ACTIVATE="yes";       shift ;;
        --dry-run)          SR_MODE="count";         shift ;;
        --apply)            SR_MODE="apply";         shift ;;
        -h|--help)          usage; exit 0 ;;
        --)                 shift; break ;;
        -*)                 echo -e "${RED}✘ Unknown option: $1${NC}" >&2; usage; exit 1 ;;
        *)                  WP_PATH="$1"; shift ;;   # bare positional path
    esac
done


#############################################
#  HELPERS
#############################################

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Pro Plugin Manager${N}"
    echo -e "  Menu-driven WordPress plugin operations."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}

# Resolve $WEBROOT from --path, a domain (cPanel / DirectAdmin), or current dir.
resolve_webroot() {
    # An explicit --path wins outright.
    if [ -n "$WP_PATH" ]; then
        WEBROOT="$WP_PATH"
        echo -e "${GREEN}✔ Using provided path:${NC}"
        echo -e "${BLUE}Public Webroot:${NC} $WEBROOT"
        return 0
    fi

    # Ask for a domain only when -d was not supplied.
    if [ -z "$DOMAIN" ]; then
        read -p "$(echo -e ${YELLOW}'Enter domain (or press Enter to use current directory as public_html): '${NC})" DOMAIN
    fi

    if [ -z "$DOMAIN" ]; then
        WEBROOT="$(pwd)"
        echo -e "${GREEN}✔ No domain entered. Using current directory:${NC}"
        echo -e "${BLUE}Public Webroot:${NC} $WEBROOT"
        return 0
    fi

    # cPanel
    if [ -d "/usr/local/cpanel" ]; then
        ControlPanel="Cpanel"
        echo -e "${MAGENTA}Control Panel Detected: cPanel${NC}"

        for USER in /var/cpanel/users/*; do
            U=$(basename "$USER")

            # Main domain
            MAINDOMAIN=$(grep "^DNS=" "$USER" | cut -d= -f2)
            if [ "$MAINDOMAIN" = "$DOMAIN" ]; then
                WEBROOT="/home/$U/public_html"
                break
            fi

            # Addon domains
            if [ -f "/var/cpanel/userdata/$U/$DOMAIN" ]; then
                WEBROOT=$(grep "documentroot:" "/var/cpanel/userdata/$U/$DOMAIN" | awk '{print $2}')
                break
            fi
        done

        if [ -z "$WEBROOT" ]; then
            echo -e "${RED}✘ Domain not found in cPanel${NC}"
            return 1
        fi
    fi

    # DirectAdmin
    if [ -d "/usr/local/directadmin" ] && [ -z "$WEBROOT" ]; then
        ControlPanel="DirectAdmin"
        echo -e "${MAGENTA}Control Panel Detected: DirectAdmin${NC}"

        for USER in /usr/local/directadmin/data/users/*; do
            U=$(basename "$USER")

            if [ -d "$USER/domains" ]; then
                for CONF in "$USER/domains"/*.conf; do
                    CONF_DOMAIN=$(basename "$CONF" .conf)

                    if [ "$CONF_DOMAIN" = "$DOMAIN" ]; then
                        DOCROOT=$(grep "^document_root=" "$CONF" | cut -d= -f2)
                        WEBROOT=${DOCROOT:-"/home/$U/domains/$DOMAIN/public_html"}
                        break
                    fi
                done
            fi
        done

        if [ -z "$WEBROOT" ]; then
            echo -e "${RED}✘ Domain not found in DirectAdmin${NC}"
            return 1
        fi
    fi

    return 0
}

# cd into webroot and confirm it's a WordPress install.
require_wordpress() {
    echo -e "${BLUE}Using Webroot:${NC} $WEBROOT"
    cd "$WEBROOT" || { echo -e "${RED}Cannot access webroot!${NC}"; return 1; }

    if [[ ! -f "wp-config.php" ]]; then
        echo -e "${RED}✘ Error: WordPress not found in this directory.${NC}"
        return 1
    fi
    return 0
}

# Read owner/group of wp-config.php into $OWNER / $GROUP.
detect_owner() {
    OWNER=""
    GROUP=""
    if command -v stat >/dev/null 2>&1; then
        OWNER=$(stat -c '%U' wp-config.php 2>/dev/null || stat -f '%Su' wp-config.php 2>/dev/null)
        GROUP=$(stat -c '%G' wp-config.php 2>/dev/null || stat -f '%Sg' wp-config.php 2>/dev/null)
    fi
}

# Parse DB credentials from wp-config.php into the DB_* globals.
parse_wp_config() {
    local cfg="wp-config.php"
    [[ -f "$cfg" ]] || { echo -e "${RED}✘ wp-config.php not found.${NC}"; return 1; }

    # Read a define('KEY', 'value') from wp-config (first match, single/double quotes).
    _wpc_define() {
        grep -E "define\(\s*['\"]$1['\"]" "$cfg" \
            | head -n1 \
            | sed -E "s/.*define\(\s*['\"]$1['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/"
    }

    DB_NAME=$(_wpc_define DB_NAME)
    DB_USER=$(_wpc_define DB_USER)
    DB_PASSWORD=$(_wpc_define DB_PASSWORD)
    DB_HOST=$(_wpc_define DB_HOST)
    DB_PREFIX=$(grep -E '^\s*\$table_prefix' "$cfg" | head -n1 | sed -E "s/.*=\s*['\"]([^'\"]*)['\"].*/\1/")

    [[ -z "$DB_HOST" ]] && DB_HOST="localhost"
    [[ -z "$DB_PREFIX" ]] && DB_PREFIX="wp_"

    # Split host:port if present
    DB_PORT=""
    if [[ "$DB_HOST" == *:* ]]; then
        DB_PORT="${DB_HOST##*:}"
        DB_HOST="${DB_HOST%%:*}"
    fi

    if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
        echo -e "${RED}✘ Could not parse DB credentials from wp-config.php${NC}"
        return 1
    fi
    return 0
}

# Find a usable wp-cli command for the current webroot and store it in $WP_CMD.
# Returns 0 if found, 1 otherwise.
resolve_wp_cli() {
    WP_CMD=""

    # 1) System wp
    if command -v wp >/dev/null 2>&1; then
        local cmd="$(command -v wp) --allow-root"
        if $cmd core version >/dev/null 2>&1; then
            WP_CMD="$cmd"
            echo -e "${GREEN}✔ Using system wp${NC}"
            return 0
        fi
    fi

    # 2) Portable wp binary (downloaded to /tmp)
    echo -e "${MAGENTA}Downloading portable wp binary to /tmp...${NC}"
    local zip="/tmp/wp.zip"
    local wpcli="/tmp/wp"
    rm -f "$zip" "$wpcli" 2>/dev/null

    if wget -q -O "$zip" "http://dl.iswps.ir/cli/wp.zip"; then
        if unzip -j -o "$zip" 'wp' -d /tmp >/dev/null 2>&1 || unzip -j -o "$zip" '*wp' -d /tmp >/dev/null 2>&1; then
            if [[ -f "$wpcli" ]]; then
                chmod +x "$wpcli"
                local cmd="$wpcli --allow-root"
                if $cmd core version >/dev/null 2>&1; then
                    WP_CMD="$cmd"
                    echo -e "${GREEN}✔ Using portable wp${NC}"
                    return 0
                fi
            fi
        fi
    fi
    rm -f "$zip" 2>/dev/null

    # 3) Control-panel specific paths
    if [[ "$ControlPanel" = "DirectAdmin" ]]; then
        local da_phar="/usr/local/directadmin/custombuild/cache/wp-cli-2.12.0.phar"
        if [[ -x "/usr/local/php81/bin/php" && -f "$da_phar" ]]; then
            local cmd="/usr/local/php81/bin/php $da_phar --allow-root"
            if $cmd core version >/dev/null 2>&1; then
                WP_CMD="$cmd"
                echo -e "${GREEN}✔ Using DirectAdmin wp-cli phar${NC}"
                return 0
            fi
        fi
    fi

    if [[ "$ControlPanel" = "Cpanel" ]]; then
        local cp_wp="/usr/local/bin/wp"
        if [[ -x "$cp_wp" ]]; then
            local cmd="$cp_wp --allow-root"
            if $cmd core version >/dev/null 2>&1; then
                WP_CMD="$cmd"
                echo -e "${GREEN}✔ Using cPanel wp binary${NC}"
                return 0
            fi
        fi
    fi

    echo -e "${YELLOW}⚠ No usable wp-cli found.${NC}"
    return 1
}


#############################################
#  FEATURE: Install latest Blue Guard
#############################################
install_blue_guard() {
    require_wordpress || return 1
    detect_owner

    # Download & extract
    echo -e "${BLUE}↓ Downloading Blue Guard...${NC}"
    wget -O blue-guard.zip "http://guard.iswps.ir/blue-guard/Blue-guard.zip" \
        || { echo -e "${RED}Download failed!${NC}"; return 1; }

    echo -e "${BLUE}Extracting...${NC}"
    unzip -q blue-guard.zip

    if [[ ! -d "blue-guard" ]]; then
        echo -e "${RED}✘ Extraction failed!${NC}"
        return 1
    fi

    # Keep old core instead of removing it
    echo -e "${BLUE}Backing up old Blue Guard core into old-blue-guard/...${NC}"
    mkdir -p old-blue-guard
    mv wp-content/plugins/blue-guard old-blue-guard/ 2>/dev/null
    chmod -R 600 old-blue-guard/
    chown -R "$OWNER:$GROUP" old-blue-guard/ 2>/dev/null

    # Copy new core
    echo -e "${BLUE}Copying new Blue Guard core...${NC}"
    cp -R blue-guard wp-content/plugins

    echo -e "${BLUE}Cleaning temporary files...${NC}"
    rm -rf blue-guard blue-guard.zip

    # Fix permissions
    echo -e "${MAGENTA}Applying permissions...${NC}"
    find wp-content/plugins \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
    if [[ -n "$OWNER" ]]; then
        chown -R "$OWNER:$GROUP" wp-content/plugins/blue-guard 2>/dev/null
    fi

    # Activate
    echo -e "${MAGENTA}Activating plugin...${NC}"
    if resolve_wp_cli; then
        if $WP_CMD plugin activate blue-guard >/dev/null 2>&1; then
            echo -e "${GREEN}✔ Plugin activated${NC}"
        else
            echo -e "${YELLOW}✘ Activation failed — activate manually from WP-Admin.${NC}"
        fi

        # Verify
        echo -e "${MAGENTA}Checking plugin status...${NC}"
        if $WP_CMD plugin is-active blue-guard >/dev/null 2>&1; then
            echo -e "${GREEN}✔ blue-guard is ACTIVE${NC}"
        else
            echo -e "${YELLOW}✘ blue-guard is NOT active${NC}"
        fi
        echo
        $WP_CMD plugin status blue-guard 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ No wp-cli available. Please activate blue-guard from WP-Admin.${NC}"
    fi

    echo
    echo -e "${GREEN}✔ Blue Guard installed/updated/repaired successfully!${NC}"
    echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
    echo
}


# Read a plugin's version from a plugin directory (dir + slug).
# Mirrors how WordPress get_file_data() reads the "Version:" header: leading
# whitespace / tabs / * / # / @ are tolerated. Falls back to readme.txt
# "Stable tag:". Prints the version (empty if none found).
read_plugin_header_version() {
    local dir="$1" slug="$2" ver="" main="$1/$2.php"

    if [[ -f "$main" ]]; then
        ver=$(sed -n '1,50p' "$main" \
            | grep -iE '^[[:space:]/*#@]*Version:[[:space:]]*[0-9]' \
            | head -n1 \
            | sed -E 's/^[[:space:]/*#@]*[Vv]ersion:[[:space:]]*//' \
            | sed -E 's/[[:space:]].*$//' \
            | tr -d '\r')
    fi

    if [[ -z "$ver" && -f "$dir/readme.txt" ]]; then
        ver=$(grep -iE '^[[:space:]]*Stable tag:' "$dir/readme.txt" \
            | head -n1 | sed -E 's/^[[:space:]]*[Ss]table tag:[[:space:]]*//' | tr -d '\r')
    fi

    printf '%s' "$ver"
}

#############################################
#  FEATURE: Generic plugin manager
#  Repair / Update / Install version / Rollback for a single
#  wordpress.org plugin (official source first, whodns.ir fallback).
#############################################
manage_plugin() {
    local slug="$1"
    require_wordpress || return 1
    detect_owner

    local PLUGIN_DIR="wp-content/plugins/$slug"
    local BACKUP_DIR="old-$slug"

    # Detect currently installed version (header/readme, then wp-cli if handy).
    local CUR_VER
    CUR_VER=$(read_plugin_header_version "$PLUGIN_DIR" "$slug")
    if [[ -z "$CUR_VER" ]] && command -v wp >/dev/null 2>&1; then
        CUR_VER=$(wp --allow-root plugin get "$slug" --field=version 2>/dev/null | tr -d '\r')
    fi

    # Menu
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}      Manage plugin: ${slug}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ -n "$CUR_VER" ]]; then
        echo -e "  ${BLUE}Current version:${NC} ${GREEN}$CUR_VER${NC}"
    else
        echo -e "  ${BLUE}Current version:${NC} ${YELLOW}not detected${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${YELLOW}1) Repair current version${NC}"
    echo -e "${YELLOW}2) Update to latest version${NC}"
    echo -e "${YELLOW}3) Install specific version${NC}"
    echo -e "${YELLOW}4) Rollback to previous ($BACKUP_DIR)${NC}"
    echo

    # A --repair/--update/--install/--rollback flag skips this prompt.
    local p_choice=""
    case "$PLUGIN_ACTION" in
        repair)   p_choice=1 ;;
        update)   p_choice=2 ;;
        install)  p_choice=3 ;;
        rollback) p_choice=4 ;;
        *)        read -p "$(echo -e ${GREEN}"Enter choice [1-4]: "${NC})" p_choice ;;
    esac

    local TARGET_VER=""
    case "$p_choice" in
        1)
            if [[ -z "$CUR_VER" ]]; then
                echo -e "${RED}✘ Could not detect installed version to repair.${NC}"
                return 1
            fi
            TARGET_VER="$CUR_VER"
            ;;
        2)
            TARGET_VER=""   # latest
            ;;
        3)
            if [[ -n "$REQ_VERSION" ]]; then
                TARGET_VER="$REQ_VERSION"
            else
                read -p "$(echo -e ${YELLOW}"Enter version (example: 10.9.0): "${NC})" TARGET_VER
            fi
            if [[ -z "$TARGET_VER" ]]; then
                echo -e "${RED}✘ Version cannot be empty.${NC}"
                return 1
            fi
            ;;
        4)
            plugin_rollback "$slug"
            return $?
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac

    # Build download URLs (official primary, whodns.ir fallback)
    local OFFICIAL_URL FALLBACK_URL
    if [[ -z "$TARGET_VER" ]]; then
        OFFICIAL_URL="https://downloads.wordpress.org/plugin/$slug.zip"
        FALLBACK_URL="https://whodns.ir/?r=plugins&dl=$slug"
    else
        OFFICIAL_URL="https://downloads.wordpress.org/plugin/$slug.$TARGET_VER.zip"
        FALLBACK_URL="https://whodns.ir/?r=plugins&dl=$slug&ver=$TARGET_VER"
    fi

    # Download (official first, then fallback)
    echo -e "${BLUE}↓ Downloading $slug package...${NC}"
    if ! wget -O plugin.zip "$OFFICIAL_URL"; then
        echo -e "${YELLOW}Official source failed, trying whodns.ir mirror...${NC}"
        wget -O plugin.zip "$FALLBACK_URL" || {
            echo -e "${RED}Download failed!${NC}"
            rm -f plugin.zip
            return 1
        }
    fi

    # Extract
    echo -e "${BLUE}Extracting...${NC}"
    rm -rf "$slug" 2>/dev/null
    unzip -q plugin.zip

    if [[ ! -d "$slug" ]]; then
        echo -e "${RED}✘ Extraction failed (expected '$slug/' directory).${NC}"
        rm -f plugin.zip
        return 1
    fi

    # Backup old plugin instead of deleting
    if [[ -d "$PLUGIN_DIR" ]]; then
        echo -e "${BLUE}Backing up current plugin into $BACKUP_DIR/...${NC}"
        rm -rf "$BACKUP_DIR"
        mv "$PLUGIN_DIR" "$BACKUP_DIR"
    fi

    # Move new plugin into place
    echo -e "${BLUE}Installing new plugin core...${NC}"
    mv "$slug" wp-content/plugins/

    echo -e "${BLUE}Cleaning temporary files...${NC}"
    rm -f plugin.zip

    # Fix permissions
    echo -e "${MAGENTA}Applying permissions...${NC}"
    find "$PLUGIN_DIR" \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
    if [[ -n "$OWNER" ]]; then
        chown -R "$OWNER:$GROUP" "$PLUGIN_DIR" 2>/dev/null
    fi

    # Activate + verify (optional, ask first).
    # --yes activates without asking; --no-activate skips without asking.
    echo
    local ACT_CONFIRM=""
    if [[ "$NO_ACTIVATE" == "yes" ]]; then
        ACT_CONFIRM="n"
    elif [[ "$ASSUME_YES" == "yes" ]]; then
        ACT_CONFIRM="y"
    else
        read -p "$(echo -e ${YELLOW}"Activate $slug now with wp-cli? [y/N]: "${NC})" ACT_CONFIRM
    fi
    if [[ "$ACT_CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${MAGENTA}Activating plugin...${NC}"
        if resolve_wp_cli; then
            if $WP_CMD plugin activate "$slug" >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Plugin activated${NC}"
            else
                echo -e "${YELLOW}✘ Activation failed — activate manually from WP-Admin.${NC}"
            fi

            echo -e "${MAGENTA}Checking plugin status...${NC}"
            if $WP_CMD plugin is-active "$slug" >/dev/null 2>&1; then
                echo -e "${GREEN}✔ $slug is ACTIVE${NC}"
            else
                echo -e "${YELLOW}✘ $slug is NOT active${NC}"
            fi
            echo
            $WP_CMD plugin status "$slug" 2>/dev/null || true
        else
            echo -e "${YELLOW}⚠ No wp-cli available. Please activate $slug from WP-Admin.${NC}"
        fi
    else
        echo -e "${BLUE}Skipped activation. Activate $slug from WP-Admin when ready.${NC}"
    fi

    echo
    echo -e "${GREEN}✔ $slug installed/updated/repaired successfully!${NC}"
    echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
    echo
}

# Restore a plugin from its old-<slug> backup directory.
plugin_rollback() {
    local slug="$1"
    local PLUGIN_DIR="wp-content/plugins/$slug"
    local BACKUP_DIR="old-$slug"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}✘ No $BACKUP_DIR backup found. Nothing to roll back.${NC}"
        return 1
    fi

    local OLD_VER
    OLD_VER=$(read_plugin_header_version "$BACKUP_DIR" "$slug")

    echo -e "${BLUE}Rollback target :${NC} ${OLD_VER:-unknown}"
    if [[ "$ASSUME_YES" != "yes" ]]; then
        read -p "$(echo -e ${YELLOW}'Restore the previous plugin? This replaces the current one [y/N]: '${NC})" CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; return 0; }
    fi

    echo -e "${BLUE}Removing current plugin...${NC}"
    rm -rf "$PLUGIN_DIR"

    echo -e "${BLUE}Restoring plugin from $BACKUP_DIR...${NC}"
    mv "$BACKUP_DIR" "$PLUGIN_DIR"

    echo -e "${MAGENTA}Applying permissions...${NC}"
    find "$PLUGIN_DIR" \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
    if [[ -n "$OWNER" ]]; then
        chown -R "$OWNER:$GROUP" "$PLUGIN_DIR" 2>/dev/null
    fi

    echo
    echo -e "${GREEN}✔ Rollback completed. Restored version: ${OLD_VER:-unknown}${NC}"
    echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
    echo
}

#############################################
#  FEATURE STUBS (develop these gradually)
#############################################
manage_woocommerce() {
    manage_plugin woocommerce
}

manage_elementor() {
    manage_plugin elementor
}

#############################################
#  FEATURE: Search And Replace (whole DB)
#############################################

# Escape a value for safe use inside a single-quoted MySQL string literal.
sql_escape() {
    local s="$1"
    s="${s//\\/\\\\}"    # backslash -> double backslash
    s="${s//\'/\\\'}"    # ' -> \'
    printf '%s' "$s"
}

# Direct MySQL fallback across every text column of every table, using the
# DB_* globals and the OLD/NEW values, with per-table progress.
#   $1 = mode:  "count" (dry run, no changes)  |  "apply" (perform replace)
db_search_replace() {
    local mode="$1"
    local deffile
    deffile=$(mktemp /tmp/wpdb.XXXXXX) || { echo -e "${RED}✘ mktemp failed${NC}"; return 1; }
    chmod 600 "$deffile"
    {
        echo "[client]"
        echo "user=$DB_USER"
        echo "password=$DB_PASSWORD"
        echo "host=$DB_HOST"
        [[ -n "$DB_PORT" ]] && echo "port=$DB_PORT"
    } > "$deffile"

    local MYSQL="$DB_CLI --defaults-extra-file=$deffile"

    if ! $MYSQL -e "USE \`$DB_NAME\`;" >/dev/null 2>&1; then
        echo -e "${RED}✘ Cannot connect to database '$DB_NAME'.${NC}"
        rm -f "$deffile"
        return 1
    fi

    local OLD_ESC NEW_ESC
    OLD_ESC=$(sql_escape "$OLD")
    NEW_ESC=$(sql_escape "$NEW")

    local tables total i grand
    tables=$($MYSQL -N -e "SHOW TABLES" "$DB_NAME")
    total=$(echo "$tables" | grep -c .)
    i=0
    grand=0

    echo -e "${BLUE}Scanning $total tables...${NC}"
    echo

    while IFS= read -r table; do
        [[ -z "$table" ]] && continue
        i=$((i + 1))

        local cols changed
        cols=$($MYSQL -N -e "SELECT COLUMN_NAME FROM information_schema.COLUMNS \
            WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$table' \
            AND DATA_TYPE IN ('char','varchar','text','tinytext','mediumtext','longtext')")
        changed=0

        while IFS= read -r col; do
            [[ -z "$col" ]] && continue
            local n
            if [[ "$mode" = "count" ]]; then
                # Count rows that contain OLD (exact substring, no wildcards).
                n=$($MYSQL "$DB_NAME" -N -e \
                    "SELECT COUNT(*) FROM \`$table\` WHERE INSTR(\`$col\`, '$OLD_ESC') > 0;" \
                    2>/dev/null | tail -n1)
            else
                n=$($MYSQL "$DB_NAME" -N -e \
                    "UPDATE \`$table\` SET \`$col\`=REPLACE(\`$col\`,'$OLD_ESC','$NEW_ESC'); SELECT ROW_COUNT();" \
                    2>/dev/null | tail -n1)
            fi
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            changed=$((changed + n))
        done <<< "$cols"

        grand=$((grand + changed))
        if [[ "$mode" = "count" ]]; then
            printf "${CYAN}[%d/%d]${NC} %-45s ${YELLOW}%d match(es)${NC}\n" "$i" "$total" "$table" "$changed"
        else
            printf "${CYAN}[%d/%d]${NC} %-45s ${GREEN}%d replaced${NC}\n" "$i" "$total" "$table" "$changed"
        fi
    done <<< "$tables"

    rm -f "$deffile"
    echo
    if [[ "$mode" = "count" ]]; then
        echo -e "${YELLOW}► Dry run: $grand row(s) contain the value across $total tables. Nothing changed.${NC}"
    else
        echo -e "${GREEN}✔ Done. $grand value(s) replaced across $total tables.${NC}"
    fi
}

search_and_replace() {
    require_wordpress || return 1
    parse_wp_config || return 1

    echo -e "${BLUE}Target database:${NC} $DB_NAME ${BLUE}on${NC} $DB_HOST${DB_PORT:+:$DB_PORT}"
    echo

    # --old / --new answer these prompts up-front (an empty --new is valid).
    if [[ -n "$SR_OLD" ]]; then OLD="$SR_OLD"; else read -p "$(echo -e ${YELLOW}'Search for (old value): '${NC})" OLD; fi
    if [[ "$SR_NEW_SET" == "yes" ]]; then NEW="$SR_NEW"; else read -p "$(echo -e ${YELLOW}'Replace with (new value): '${NC})" NEW; fi

    if [[ -z "$OLD" ]]; then
        echo -e "${RED}✘ Search value cannot be empty.${NC}"
        return 1
    fi

    echo
    echo -e "${MAGENTA}Operation${NC}"
    echo -e "  ${RED}$OLD${NC}  →  ${GREEN}$NEW${NC}"
    echo -e "${YELLOW}across the entire '$DB_NAME' database.${NC}"
    echo

    # Mode selection — --dry-run / --apply skip this menu.
    local mode
    if [[ -n "$SR_MODE" ]]; then
        mode="$SR_MODE"
    else
        echo -e "${CYAN}Select mode:${NC}"
        echo -e "${YELLOW}1) Dry run (count matches only, no changes)${NC}"
        echo -e "${YELLOW}2) Replace now${NC}"
        echo
        read -p "$(echo -e ${GREEN}"Enter choice [1-2]: "${NC})" mode_choice
        case "$mode_choice" in
            1) mode="count" ;;
            2) mode="apply" ;;
            *) echo -e "${RED}Invalid choice!${NC}"; return 1 ;;
        esac
    fi
    echo

    # Direct MySQL using credentials from wp-config.
    echo -e "${YELLOW}⚠ Note: serialized values (arrays/objects) are NOT length-fixed.${NC}"
    echo
    db_search_replace "$mode"
}


#############################################
#  FEATURE: Plugin manager (wp-cli)
#  Install from a link or path, list, activate, deactivate, delete — for
#  ANY plugin. Everything goes through wp-cli on purpose: WordPress is
#  loaded normally, so a plugin's activation / deactivation / uninstall
#  hooks run exactly as they would from WP-Admin. Moving folders by hand
#  skips those hooks and leaves the site in a state WordPress didn't make.
#############################################

# Ask for (or take from the flag) a plugin slug; prints it, empty on bad input.
pm_ask_slug() {
    local verb="$1" slug="$PM_SLUG"
    if [[ -z "$slug" ]]; then
        $WP_CMD plugin list --fields=name,status,version 2>/dev/null >&2
        echo >&2
        read -p "$(echo -e ${YELLOW}"Plugin slug to $verb: "${NC})" slug
    fi
    if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "${RED}✘ Invalid plugin slug: '$slug'${NC}" >&2
        return 1
    fi
    printf '%s' "$slug"
}

# Fix permissions / ownership of the plugin folders wp-cli just wrote (as root).
pm_fix_perms() {
    local marker="$1" d
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        find "$d" \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
        [[ -n "$OWNER" ]] && chown -R "$OWNER:$GROUP" "$d" 2>/dev/null
        echo -e "${GREEN}✔ Permissions applied:${NC} $d"
    done < <(find wp-content/plugins -mindepth 1 -maxdepth 1 -type d -newer "$marker" 2>/dev/null)
}

pm_install() {
    local src="$PM_SRC" act="" out marker
    if [[ -z "$src" ]]; then
        read -p "$(echo -e ${YELLOW}"Plugin zip — URL or local path: "${NC})" src
    fi
    if [[ -z "$src" ]]; then
        echo -e "${RED}✘ Source cannot be empty.${NC}"; return 1
    fi
    if [[ ! "$src" =~ ^https?:// ]]; then
        [[ "$src" = /* ]] || src="$START_DIR/$src"  # relative to where the script was started
        [[ -f "$src" ]] || { echo -e "${RED}✘ File not found: $src${NC}"; return 1; }
    fi

    # Activate afterwards? --yes / --no-activate answer up-front.
    local ACT_CONFIRM=""
    if   [[ "$NO_ACTIVATE" == "yes" ]]; then ACT_CONFIRM="n"
    elif [[ "$ASSUME_YES" == "yes" ]];  then ACT_CONFIRM="y"
    else read -p "$(echo -e ${YELLOW}"Activate it after install? [y/N]: "${NC})" ACT_CONFIRM
    fi
    [[ "$ACT_CONFIRM" =~ ^[Yy]$ ]] && act="--activate"

    marker=$(mktemp /tmp/ppm-mark.XXXXXX)
    echo -e "${BLUE}↓ Installing from:${NC} $src"
    out=$($WP_CMD plugin install "$src" $act 2>&1); echo "$out"

    # Already there? Offer to overwrite (wp-cli's --force).
    if grep -qiE 'already exists|already installed' <<<"$out"; then
        local OW="n"
        if [[ "$ASSUME_YES" == "yes" ]]; then OW="y"
        else read -p "$(echo -e ${YELLOW}"That plugin is already installed. Overwrite it? [y/N]: "${NC})" OW
        fi
        if [[ "$OW" =~ ^[Yy]$ ]]; then
            out=$($WP_CMD plugin install "$src" $act --force 2>&1); echo "$out"
        else
            echo -e "${BLUE}Left the installed copy as it is.${NC}"; rm -f "$marker"; return 0
        fi
    fi

    if grep -qiE 'success' <<<"$out"; then
        pm_fix_perms "$marker"
        rm -f "$marker"
        echo
        echo -e "${GREEN}✔ Plugin installed${act:+ and activated}.${NC}"
    else
        rm -f "$marker"
        echo -e "${RED}✘ Install failed — see the wp-cli output above.${NC}"; return 1
    fi
}

pm_toggle() {   # $1 = activate | deactivate
    local verb="$1" slug
    slug=$(pm_ask_slug "$verb") || return 1
    echo -e "${MAGENTA}Running: wp plugin $verb $slug${NC}"
    if $WP_CMD plugin "$verb" "$slug" 2>&1; then
        echo -e "${GREEN}✔ Done.${NC}"
        $WP_CMD plugin status "$slug" 2>/dev/null || true
    else
        echo -e "${RED}✘ wp plugin $verb failed — see the output above.${NC}"; return 1
    fi
}

pm_delete() {
    local slug UN="" CONFIRM=""
    slug=$(pm_ask_slug delete) || return 1
    if ! $WP_CMD plugin is-installed "$slug" >/dev/null 2>&1; then
        echo -e "${RED}✘ Plugin '$slug' is not installed.${NC}"; return 1
    fi

    if [[ "$ASSUME_YES" != "yes" ]]; then
        read -p "$(echo -e ${YELLOW}"Delete plugin '$slug'? [y/N]: "${NC})" CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; return 0; }
    fi
    if [[ "$PM_UNINSTALL" == "yes" ]]; then
        UN="y"
    else
        read -p "$(echo -e ${YELLOW}"Also run its uninstall routine? It removes the plugin's settings/tables [y/N]: "${NC})" UN
    fi

    # Keep a copy of the files (same old-<slug>/ convention as the other features).
    if [[ -d "wp-content/plugins/$slug" ]]; then
        rm -rf "old-$slug"
        cp -a "wp-content/plugins/$slug" "old-$slug" && chmod -R go-rwx "old-$slug" \
            && echo -e "${BLUE}Copy of the plugin files kept in old-$slug/${NC}"
    fi

    if [[ "$UN" =~ ^[Yy]$ ]]; then
        echo -e "${MAGENTA}Running: wp plugin uninstall $slug --deactivate${NC}"
        $WP_CMD plugin uninstall "$slug" --deactivate 2>&1 \
            || { echo -e "${RED}✘ Uninstall failed — see the output above.${NC}"; return 1; }
    else
        if $WP_CMD plugin is-active "$slug" >/dev/null 2>&1; then
            echo -e "${MAGENTA}Running: wp plugin deactivate $slug${NC}"
            $WP_CMD plugin deactivate "$slug" 2>&1
        fi
        echo -e "${MAGENTA}Running: wp plugin delete $slug${NC}"
        $WP_CMD plugin delete "$slug" 2>&1 \
            || { echo -e "${RED}✘ Delete failed — see the output above.${NC}"; return 1; }
    fi
    echo -e "${GREEN}✔ Plugin '$slug' removed.${NC}"
}

manage_plugins_wpcli() {
    require_wordpress || return 1
    detect_owner
    resolve_wp_cli || { echo -e "${RED}✘ The plugin manager needs wp-cli and none could be found.${NC}"; return 1; }

    local c=""
    case "$PM_ACTION" in
        install)    c=1 ;;
        list)       c=2 ;;
        activate)   c=3 ;;
        deactivate) c=4 ;;
        delete)     c=5 ;;
        *)
            echo
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}      Plugin Manager (wp-cli)          ${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo
            echo -e "${YELLOW}1) Install from a link or path (.zip)${NC}"
            echo -e "${YELLOW}2) List plugins${NC}"
            echo -e "${YELLOW}3) Activate a plugin${NC}"
            echo -e "${YELLOW}4) Deactivate a plugin${NC}"
            echo -e "${YELLOW}5) Delete a plugin${NC}"
            echo
            read -p "$(echo -e ${GREEN}"Enter choice [1-5]: "${NC})" c
            ;;
    esac

    case "$c" in
        1) pm_install ;;
        2) $WP_CMD plugin list 2>&1 ;;
        3) pm_toggle activate ;;
        4) pm_toggle deactivate ;;
        5) pm_delete ;;
        *) echo -e "${RED}Invalid choice!${NC}"; return 1 ;;
    esac
}


#############################################
#  MENU + DISPATCH
#############################################
show_menu() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}      Select WP Plugin Operation       ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${YELLOW}1) WooCommerce Manager${NC}"
    echo -e "${YELLOW}2) Elementor Manager${NC}"
    echo -e "${YELLOW}3) Search And Replace${NC}"
    echo -e "${YELLOW}4) Install latest Blue Guard${NC}"
    echo -e "${YELLOW}5) Plugin Manager (wp-cli: install / list / activate / deactivate / delete)${NC}"
    echo
}

main() {
    print_header
    resolve_webroot || exit 1
    detect_db_client
    start_log "${DOMAIN:-$(basename "$WEBROOT")}"

    # A feature flag skips the main menu; otherwise ask.
    local feat="$FEATURE"
    if [ -z "$feat" ]; then
        show_menu
        read -p "$(echo -e ${GREEN}"Enter choice [1-5]: "${NC})" choice
        case $choice in
            1) feat="woocommerce" ;;
            2) feat="elementor" ;;
            3) feat="search" ;;
            4) feat="blueguard" ;;
            5) feat="plugins" ;;
            *) echo -e "${RED}Invalid choice!${NC}"; exit 1 ;;
        esac
    fi

    case "$feat" in
        woocommerce) manage_woocommerce ;;
        elementor)   manage_elementor ;;
        search)      search_and_replace ;;
        blueguard)   install_blue_guard ;;
        plugins)     manage_plugins_wpcli ;;
        *)           echo -e "${RED}Invalid choice!${NC}"; exit 1 ;;
    esac
}

main "$@"
# 12