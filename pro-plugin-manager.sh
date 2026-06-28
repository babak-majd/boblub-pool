#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Pro Plugin Manager
#   Menu-driven WordPress plugin operations.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
# ════════════════════════════════════════════════════════════


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

# Globals filled in by helpers
WEBROOT=""
ControlPanel=""
OWNER=""
GROUP=""
WP_CMD=""

# DB credentials (filled by parse_wp_config)
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST=""
DB_PORT=""
DB_PREFIX=""


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
    echo -e "${C}${hr}${N}"
    echo
}

# Resolve $WEBROOT from a domain (cPanel / DirectAdmin) or current dir.
resolve_webroot() {
    read -p "$(echo -e ${YELLOW}'Enter domain (or press Enter to use current directory as public_html): '${NC})" DOMAIN

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


#############################################
#  FEATURE STUBS (develop these gradually)
#############################################
manage_woocommerce() {
    echo -e "${YELLOW}WooCommerce Manager is not implemented yet. Coming soon.${NC}"
}

manage_elementor() {
    echo -e "${YELLOW}Elementor Manager is not implemented yet. Coming soon.${NC}"
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

    local MYSQL="mysql --defaults-extra-file=$deffile"

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

    read -p "$(echo -e ${YELLOW}'Search for (old value): '${NC})" OLD
    read -p "$(echo -e ${YELLOW}'Replace with (new value): '${NC})" NEW

    if [[ -z "$OLD" ]]; then
        echo -e "${RED}✘ Search value cannot be empty.${NC}"
        return 1
    fi

    echo
    echo -e "${MAGENTA}Operation${NC}"
    echo -e "  ${RED}$OLD${NC}  →  ${GREEN}$NEW${NC}"
    echo -e "${YELLOW}across the entire '$DB_NAME' database.${NC}"
    echo

    # Mode selection (no CLI switches — menu driven).
    echo -e "${CYAN}Select mode:${NC}"
    echo -e "${YELLOW}1) Dry run (count matches only, no changes)${NC}"
    echo -e "${YELLOW}2) Replace now${NC}"
    echo
    read -p "$(echo -e ${GREEN}"Enter choice [1-2]: "${NC})" mode_choice

    local mode
    case "$mode_choice" in
        1) mode="count" ;;
        2) mode="apply" ;;
        *) echo -e "${RED}Invalid choice!${NC}"; return 1 ;;
    esac
    echo

    # Direct MySQL using credentials from wp-config.
    echo -e "${YELLOW}⚠ Note: serialized values (arrays/objects) are NOT length-fixed.${NC}"
    echo
    db_search_replace "$mode"
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
    echo -e "${YELLOW}1) WooCommerce Manager (Soon)${NC}"
    echo -e "${YELLOW}2) Elementor Manager (Soon)${NC}"
    echo -e "${YELLOW}3) Search And Replace${NC}"
    echo -e "${YELLOW}4) Install latest Blue Guard${NC}"
    echo
}

main() {
    print_header
    resolve_webroot || exit 1
    show_menu

    read -p "$(echo -e ${GREEN}"Enter choice [1-4]: "${NC})" choice

    case $choice in
        1) manage_woocommerce ;;
        2) manage_elementor ;;
        3) search_and_replace ;;
        4) install_blue_guard ;;
        *) echo -e "${RED}Invalid choice!${NC}"; exit 1 ;;
    esac
}

main "$@"
