#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  WP Core Manager
#   Repair, update, install WordPress core, or provision a fresh site.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.2.0
# ════════════════════════════════════════════════════════════
VERSION="1.2.0"

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

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}WP Core Manager${N}"
    echo -e "  Repair, update, install core, or provision a fresh site."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}

#############################################
#  HELPERS
#############################################

# Strong-ish random password that satisfies common panel policies.
gen_password() {
    local base
    base=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14)
    printf '%sXy9@#' "$base"
}

# 64-char salt for wp-config secret keys (no quote/backslash chars).
gen_salt() {
    tr -dc 'A-Za-z0-9!@#%^*()_+=-' < /dev/urandom | head -c 64
}

# Escape a value for safe use on the replacement side of `sed s|...|VALUE|`.
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Locate a usable PHP CLI binary; sets PHP_BIN on success.
detect_php() {
    local c
    for c in php /usr/local/bin/php /opt/cpanel/ea-php83/root/usr/bin/php \
             /opt/cpanel/ea-php82/root/usr/bin/php /opt/cpanel/ea-php81/root/usr/bin/php; do
        if command -v "$c" >/dev/null 2>&1; then
            PHP_BIN="$c"
            return 0
        fi
    done
    return 1
}

# Map a requested version to IR-mirror + official URLs (sets URL_IR / URL_ORG).
version_urls() {
    local v="$1"
    if [[ -z "$v" || "$v" == "latest" ]]; then
        URL_IR="http://mirror-ir.iswps.ir/core/latest.zip"
        URL_ORG="https://wordpress.org/latest.zip"
    else
        URL_IR="http://mirror-ir.iswps.ir/core/wp$v.zip"
        URL_ORG="https://wordpress.org/wordpress-$v.zip"
    fi
}

# Download + extract a WordPress package, leaving an extracted `wordpress/` dir.
fetch_wp() {
    local url_ir="$1" url_org="$2"
    echo -e "${BLUE}↓ Downloading WordPress package...${NC}"
    if ! wget -O wp.zip "$url_ir"; then
        echo -e "${YELLOW}IR mirror failed, trying official source...${NC}"
        wget -O wp.zip "$url_org" || { echo -e "${RED}Download failed!${NC}"; return 1; }
    fi
    echo -e "${BLUE}Extracting...${NC}"
    unzip -q -o wp.zip || { echo -e "${RED}✘ Extraction failed!${NC}"; return 1; }
    [[ -d "wordpress" ]] || { echo -e "${RED}✘ Extraction failed!${NC}"; return 1; }
    return 0
}

# Apply standard ownership + permissions to the whole webroot.
apply_permissions() {
    echo -e "${MAGENTA}Applying permissions...${NC}"
    find . \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)
    chmod 640 wp-config.php 2>/dev/null
    if [[ -n "$OWNER" ]]; then
        chown -R "$OWNER:$GROUP" . 2>/dev/null
    fi
}

#############################################
#  STEP 1 — Get Domain / Webroot
#############################################

print_header

PANEL=""
CP_USER=""
DOMAIN_FOUND=""

read -p "$(echo -e ${YELLOW}'Enter domain (or press Enter to use current directory as public_html): '${NC})" DOMAIN

if [ -z "$DOMAIN" ]; then
    WEBROOT="$(pwd)"
    echo -e "${GREEN}✔ No domain entered. Using current directory:${NC}"
    echo -e "${BLUE}Public Webroot:${NC} $WEBROOT"
else
    #############################################
    # Detect cPanel
    #############################################
    if [ -d "/usr/local/cpanel" ]; then
        echo -e "${MAGENTA}Control Panel Detected: cPanel${NC}"
        PANEL="cPanel"

        for USER in /var/cpanel/users/*; do
            [ -f "$USER" ] || continue
            U=$(basename "$USER")

            # Main domain
            MAINDOMAIN=$(grep "^DNS=" "$USER" | cut -d= -f2)
            if [ "$MAINDOMAIN" = "$DOMAIN" ]; then
                WEBROOT="/home/$U/public_html"
                CP_USER="$U"
                break
            fi

            # Addon domains
            if [ -f "/var/cpanel/userdata/$U/$DOMAIN" ]; then
                WEBROOT=$(grep "documentroot:" "/var/cpanel/userdata/$U/$DOMAIN" | awk '{print $2}')
                CP_USER="$U"
                break
            fi
        done

        if [ -z "$WEBROOT" ]; then
            echo -e "${RED}✘ Domain not found in cPanel${NC}"
            exit 1
        fi
    fi

    #############################################
    # Detect DirectAdmin
    #############################################
    if [ -d "/usr/local/directadmin" ] && [ -z "$WEBROOT" ]; then
        echo -e "${MAGENTA}Control Panel Detected: DirectAdmin${NC}"
        PANEL="DirectAdmin"

        for USER in /usr/local/directadmin/data/users/*; do
            U=$(basename "$USER")

            if [ -d "$USER/domains" ]; then
                for CONF in "$USER/domains"/*.conf; do
                    CONF_DOMAIN=$(basename "$CONF" .conf)

                    if [ "$CONF_DOMAIN" = "$DOMAIN" ]; then
                        DOCROOT=$(grep "^document_root=" "$CONF" | cut -d= -f2)
                        WEBROOT=${DOCROOT:-"/home/$U/domains/$DOMAIN/public_html"}
                        CP_USER="$U"
                        break
                    fi
                done
            fi
        done

        if [ -z "$WEBROOT" ]; then
            echo -e "${RED}✘ Domain not found in DirectAdmin${NC}"
            exit 1
        fi
    fi

    DOMAIN_FOUND="$DOMAIN"
fi

#############################################
#  Change directory
#############################################

echo -e "${BLUE}Using Webroot:${NC} $WEBROOT"
cd "$WEBROOT" || { echo -e "${RED}Cannot access webroot!${NC}"; exit 1; }


#############################################
#  Shared core file list (used by replace & rollback)
#############################################
CORE_FILES=(
  index.php wp-activate.php wp-blog-header.php wp-comments-post.php
  wp-cron.php wp-links-opml.php wp-load.php wp-login.php
  wp-mail.php wp-settings.php wp-signup.php wp-trackback.php
  xmlrpc.php license.txt readme.html wp-config-sample.php
)


#############################################
#  Detect currently installed version / presence
#############################################
WP_VERSION=""
if [[ -f "wp-includes/version.php" ]]; then
    WP_VERSION=$(grep "\$wp_version =" wp-includes/version.php | cut -d"'" -f2)
fi

WP_PRESENT=false
if [[ -f "wp-config.php" || -f "wp-includes/version.php" ]]; then
    WP_PRESENT=true
fi


#############################################
#  Detect Owner / Group
#############################################
OWNER=""
GROUP=""

if [[ -f "wp-config.php" ]]; then
    OWNER=$(stat -c '%U' wp-config.php 2>/dev/null)
    GROUP=$(stat -c '%G' wp-config.php 2>/dev/null)
fi
if [[ -z "$OWNER" && -n "$CP_USER" ]]; then
    OWNER="$CP_USER"
    GROUP="$CP_USER"
fi
if [[ -z "$OWNER" ]]; then
    OWNER=$(stat -c '%U' . 2>/dev/null)
    GROUP=$(stat -c '%G' . 2>/dev/null)
fi


#############################################
#  FRESH INSTALL — provision a brand new site
#############################################
create_database() {
    # Sets DB_NAME / DB_USER / DB_PASS on success.
    DB_PASS=$(gen_password)

    if [[ "$PANEL" == "DirectAdmin" && -n "$CP_USER" ]]; then
        DB_NAME="${CP_USER}_wp"
        DB_USER="${CP_USER}_wp"
        local da_pass
        da_pass=$(grep "^passwd=" /usr/local/directadmin/conf/mysql.conf | cut -d= -f2)
        echo -en "${BLUE}Creating database... ${NC}"
        mysql -u da_admin -p"$da_pass" -e "
            CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
            CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
            ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
            GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
            FLUSH PRIVILEGES;" 2>/tmp/wpc-db-err.$$
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}SUCCESS${NC}"
            rm -f /tmp/wpc-db-err.$$
            return 0
        fi
        echo -e "${RED}ERROR${NC}"
        cat /tmp/wpc-db-err.$$ 2>/dev/null
        rm -f /tmp/wpc-db-err.$$
        return 1

    elif [[ "$PANEL" == "cPanel" && -n "$CP_USER" ]]; then
        DB_NAME="${CP_USER}_wp"
        DB_USER="${CP_USER}_wp"
        local out
        echo -en "${BLUE}Creating database... ${NC}"
        out=$(uapi --output=json --user="$CP_USER" Mysql create_database name="$DB_NAME" 2>&1)
        if ! echo "$out" | grep -q '"errors":null'; then
            echo -e "${RED}ERROR${NC}"; echo "$out"; return 1
        fi
        out=$(uapi --output=json --user="$CP_USER" Mysql create_user name="$DB_USER" password="$DB_PASS" 2>&1)
        if ! echo "$out" | grep -q '"errors":null'; then
            echo -e "${RED}ERROR${NC}"; echo "$out"; return 1
        fi
        out=$(uapi --output=json --user="$CP_USER" Mysql set_privileges_on_database \
              user="$DB_USER" database="$DB_NAME" privileges=ALL 2>&1)
        if ! echo "$out" | grep -q '"errors":null'; then
            echo -e "${RED}ERROR${NC}"; echo "$out"; return 1
        fi
        echo -e "${GREEN}SUCCESS${NC}"
        return 0

    else
        # No panel/user context — the operator supplies an existing database.
        echo -e "${YELLOW}No control-panel user detected — enter existing database details.${NC}"
        read -p "$(echo -e ${CYAN}'Database name: '${NC})" DB_NAME
        read -p "$(echo -e ${CYAN}'Database user: '${NC})" DB_USER
        read -p "$(echo -e ${CYAN}'Database password: '${NC})" DB_PASS
        [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { echo -e "${RED}✘ Database name/user required.${NC}"; return 1; }
        return 0
    fi
}

fresh_install() {
    echo
    echo -e "${YELLOW}Fresh WordPress installation into:${NC} $WEBROOT"
    read -p "$(echo -e ${CYAN}'Version to install [default 6.9.5, type a version, or "latest"]: '${NC})" INSTALL_VERSION
    INSTALL_VERSION=${INSTALL_VERSION:-6.9.5}

    echo -e "${RED}⚠ This moves EVERY existing file in the webroot into old-files/.${NC}"
    read -p "$(echo -e ${YELLOW}'Proceed with fresh install? [y/N]: '${NC})" CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; exit 0; }

    # 1) Provision the database first (abort before touching files if it fails).
    create_database || { echo -e "${RED}✘ Database setup failed. Aborting.${NC}"; exit 1; }

    # 2) Move everything currently in the webroot aside.
    echo -e "${BLUE}Moving existing files into old-files/...${NC}"
    mkdir -p old-files
    shopt -s dotglob nullglob
    for item in *; do
        [[ "$item" == "old-files" ]] && continue
        mv "$item" old-files/ 2>/dev/null
    done
    shopt -u dotglob nullglob
    rmdir old-files 2>/dev/null   # remove if nothing was moved

    # 3) Download + extract WordPress.
    version_urls "$INSTALL_VERSION"
    fetch_wp "$URL_IR" "$URL_ORG" || exit 1

    # 4) Lay down the core.
    echo -e "${BLUE}Installing WordPress core...${NC}"
    cp -R wordpress/* ./
    rm -rf wordpress wp.zip

    # 5) Build wp-config.php from the sample.
    echo -e "${BLUE}Writing wp-config.php...${NC}"
    cp wp-config-sample.php wp-config.php
    sed -i "s|database_name_here|$(sed_escape "$DB_NAME")|g" wp-config.php
    sed -i "s|username_here|$(sed_escape "$DB_USER")|g" wp-config.php
    sed -i "s|password_here|$(sed_escape "$DB_PASS")|g" wp-config.php

    # Unique secret keys/salts (generated locally so it works offline).
    local k salt
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
             AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        salt=$(sed_escape "$(gen_salt)")
        sed -i "s|define( *'$k'.*|define( '$k', '$salt' );|" wp-config.php
    done

    # 6) Permissions + ownership.
    apply_permissions

    local site_url=""
    [[ -n "$DOMAIN_FOUND" ]] && site_url="https://$DOMAIN_FOUND"

    echo
    echo -e "${GREEN}✔ WordPress installation completed successfully!${NC}"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    [[ -n "$site_url" ]] && echo -e "  ${BLUE}Website URL   :${NC} $site_url"
    echo -e "  ${BLUE}Webroot       :${NC} $WEBROOT"
    echo -e "  ${BLUE}Database name :${NC} $DB_NAME"
    echo -e "  ${BLUE}Database user :${NC} $DB_USER"
    echo -e "  ${BLUE}Database pass :${NC} $DB_PASS"
    echo -e "  ${BLUE}Old files kept:${NC} ${WEBROOT}/old-files (if any existed)"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo -e "${GREEN}✔ Open the site in a browser to finish the WordPress setup wizard.${NC}"
    echo
}


#############################################
#  ADMINISTRATOR USER MANAGEMENT
#############################################
HELPER=""

write_admin_helper() {
    HELPER="$WEBROOT/.wpc-admin-$$.php"
    cat > "$HELPER" <<'PHP'
<?php
define('WP_USE_THEMES', false);
$root = getenv('WPC_ROOT');
if (!$root || !file_exists($root . '/wp-load.php')) {
    fwrite(STDERR, "wp-load.php not found\n");
    exit(10);
}
require $root . '/wp-load.php';

$action = getenv('WPC_ACTION');

if ($action === 'list') {
    $admins = get_users(array('role' => 'administrator', 'orderby' => 'ID'));
    if (empty($admins)) {
        echo "(no administrator accounts found)\n";
        exit(0);
    }
    printf("%-5s  %-24s  %-32s  %s\n", 'ID', 'LOGIN', 'EMAIL', 'REGISTERED');
    foreach ($admins as $u) {
        printf("%-5d  %-24s  %-32s  %s\n",
            $u->ID, $u->user_login, $u->user_email, $u->user_registered);
    }
    exit(0);
}

if ($action === 'passwd') {
    $login = getenv('WPC_LOGIN');
    $user  = get_user_by('login', $login);
    if (!$user) { fwrite(STDERR, "User '$login' not found\n"); exit(2); }
    wp_set_password(getenv('WPC_PASS'), $user->ID);
    echo "Password updated for '$login' (ID {$user->ID})\n";
    exit(0);
}

if ($action === 'create') {
    $login = getenv('WPC_LOGIN');
    $email = getenv('WPC_EMAIL');
    if (username_exists($login)) { fwrite(STDERR, "Login '$login' already exists\n"); exit(3); }
    if ($email && email_exists($email)) { fwrite(STDERR, "Email '$email' already exists\n"); exit(3); }
    $uid = wp_insert_user(array(
        'user_login' => $login,
        'user_pass'  => getenv('WPC_PASS'),
        'user_email' => $email,
        'role'       => 'administrator',
    ));
    if (is_wp_error($uid)) { fwrite(STDERR, $uid->get_error_message() . "\n"); exit(4); }
    echo "Administrator '$login' created (ID $uid)\n";
    exit(0);
}

fwrite(STDERR, "Unknown action\n");
exit(9);
PHP
    chmod 644 "$HELPER"
}

# php_run VAR=val VAR=val ...  — runs the helper as the site owner when possible.
php_run() {
    if [[ $EUID -eq 0 && -n "$OWNER" ]] && command -v sudo >/dev/null 2>&1; then
        sudo -u "$OWNER" env "$@" "$PHP_BIN" "$HELPER"
    else
        env "$@" "$PHP_BIN" "$HELPER"
    fi
}

manage_admins() {
    if [[ ! -f "wp-config.php" ]]; then
        echo -e "${RED}✘ wp-config.php not found — cannot reach the database.${NC}"
        return 1
    fi
    if ! detect_php; then
        echo -e "${RED}✘ No PHP CLI binary found; admin management needs PHP.${NC}"
        return 1
    fi

    write_admin_helper
    # Always clean the helper up, even on Ctrl-C.
    trap 'rm -f "$HELPER"' RETURN

    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}      Administrator User Management     ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}1) List administrator accounts${NC}"
    echo -e "${YELLOW}2) Change an administrator's password${NC}"
    echo -e "${YELLOW}3) Create a new administrator${NC}"
    echo
    read -p "$(echo -e ${GREEN}"Enter choice [1-3]: "${NC})" achoice

    case $achoice in
        1)
            echo
            php_run WPC_ROOT="$WEBROOT" WPC_ACTION=list
            ;;
        2)
            echo
            echo -e "${BLUE}Current administrators:${NC}"
            php_run WPC_ROOT="$WEBROOT" WPC_ACTION=list
            echo
            read -p "$(echo -e ${CYAN}'Login to update: '${NC})" A_LOGIN
            [[ -n "$A_LOGIN" ]] || { echo -e "${RED}✘ Login required.${NC}"; return 1; }
            read -s -p "$(echo -e ${CYAN}'New password (blank = auto-generate): '${NC})" A_PASS; echo
            if [[ -z "$A_PASS" ]]; then
                A_PASS=$(gen_password)
                echo -e "${BLUE}Generated password:${NC} $A_PASS"
            fi
            php_run WPC_ROOT="$WEBROOT" WPC_ACTION=passwd WPC_LOGIN="$A_LOGIN" WPC_PASS="$A_PASS" \
                && echo -e "${GREEN}✔ Done.${NC}"
            ;;
        3)
            echo
            read -p "$(echo -e ${CYAN}'New admin login: '${NC})" A_LOGIN
            [[ -n "$A_LOGIN" ]] || { echo -e "${RED}✘ Login required.${NC}"; return 1; }
            read -p "$(echo -e ${CYAN}'Email: '${NC})" A_EMAIL
            read -s -p "$(echo -e ${CYAN}'Password (blank = auto-generate): '${NC})" A_PASS; echo
            if [[ -z "$A_PASS" ]]; then
                A_PASS=$(gen_password)
                echo -e "${BLUE}Generated password:${NC} $A_PASS"
            fi
            php_run WPC_ROOT="$WEBROOT" WPC_ACTION=create WPC_LOGIN="$A_LOGIN" \
                    WPC_EMAIL="$A_EMAIL" WPC_PASS="$A_PASS" \
                && echo -e "${GREEN}✔ Login: ${A_LOGIN}  ·  Password: ${A_PASS}${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return 1
            ;;
    esac
}


#############################################
#  STEP 2 — Menu
#############################################

echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}      Select WordPress Operation      ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ -n "$WP_VERSION" ]]; then
    echo -e "  ${BLUE}Current version:${NC} ${GREEN}$WP_VERSION${NC}"
elif [[ "$WP_PRESENT" == true ]]; then
    echo -e "  ${BLUE}Current version:${NC} ${YELLOW}not detected${NC}"
else
    echo -e "  ${BLUE}WordPress      :${NC} ${YELLOW}not installed in this webroot${NC}"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

if [[ "$WP_PRESENT" != true ]]; then
    #############################################
    #  No WordPress here — offer a fresh install
    #############################################
    echo -e "${YELLOW}No WordPress installation found in this webroot.${NC}"
    echo
    echo -e "${YELLOW}1) Fresh install WordPress (move existing files to old-files)${NC}"
    echo -e "${YELLOW}0) Cancel${NC}"
    echo
    read -p "$(echo -e ${GREEN}"Enter choice [0-1]: "${NC})" choice
    case $choice in
        1) fresh_install; exit 0 ;;
        *) echo -e "${BLUE}Cancelled.${NC}"; exit 0 ;;
    esac
fi

echo -e "${YELLOW}1) Repair existing version${NC}"
echo -e "${YELLOW}2) Update to latest version${NC}"
echo -e "${YELLOW}3) Install WordPress 6.9.5${NC}"
echo -e "${YELLOW}4) Install custom version${NC}"
echo -e "${YELLOW}5) Rollback to previous core (old-core)${NC}"
echo -e "${YELLOW}6) Manage administrator users${NC}"
echo

read -p "$(echo -e ${GREEN}"Enter choice [1-6]: "${NC})" choice

case $choice in
    1) action="repair" ;;
    2) action="update" ;;
    3) action="v695" ;;
    4) action="custom" ;;
    5) action="rollback" ;;
    6) manage_admins; exit $? ;;
    *) echo -e "${RED}Invalid choice!${NC}"; exit 1 ;;
esac


#############################################
#  STEP 3 — Validate WP installation
#############################################
if [[ ! -f "wp-config.php" ]]; then
    echo -e "${RED}✘ Error: WordPress not found in this directory.${NC}"
    exit 1
fi


#############################################
#  ROLLBACK — Restore previous core from old-core
#############################################
if [[ "$action" == "rollback" ]]; then
    if [[ ! -d "old-core" ]] || { [[ ! -d "old-core/wp-admin" ]] && [[ ! -d "old-core/wp-includes" ]]; }; then
        echo -e "${RED}✘ No old-core backup found. Nothing to roll back.${NC}"
        exit 1
    fi

    OLD_VERSION=$(grep "\$wp_version =" old-core/wp-includes/version.php 2>/dev/null | cut -d"'" -f2)

    echo -e "${BLUE}Current version :${NC} ${WP_VERSION:-unknown}"
    echo -e "${BLUE}Rollback target :${NC} ${OLD_VERSION:-unknown}"
    read -p "$(echo -e ${YELLOW}'Restore the previous core? This replaces the current core [y/N]: '${NC})" CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; exit 0; }

    echo -e "${BLUE}Removing current core files...${NC}"
    rm -rf wp-admin wp-includes
    for f in "${CORE_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done

    echo -e "${BLUE}Restoring core from old-core...${NC}"
    mv old-core/wp-admin ./ 2>/dev/null
    mv old-core/wp-includes ./ 2>/dev/null
    for f in "${CORE_FILES[@]}"; do
        [[ -f "old-core/$f" ]] && mv "old-core/$f" ./
    done
    rmdir old-core 2>/dev/null

    echo -e "${MAGENTA}Applying permissions...${NC}"
    find wp-admin wp-includes -type d -exec chmod 755 {} + 2>/dev/null
    find wp-admin wp-includes -type f -exec chmod 644 {} + 2>/dev/null
    for f in "${CORE_FILES[@]}"; do
        [[ -f "$f" ]] && chmod 644 "$f" 2>/dev/null
    done
    if [[ -n "$OWNER" ]]; then
        chown -R "$OWNER:$GROUP" wp-admin wp-includes 2>/dev/null
        for f in "${CORE_FILES[@]}"; do
            [[ -e "$f" ]] && chown "$OWNER:$GROUP" "$f" 2>/dev/null
        done
    fi

    echo
    echo -e "${GREEN}✔ Rollback completed. Restored version: ${OLD_VERSION:-unknown}${NC}"
    echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
    echo
    exit 0
fi


#############################################
#  STEP 4 — Determine package URL
#############################################

if [[ "$action" == "repair" ]]; then
    if [[ -z "$WP_VERSION" ]]; then
        echo -e "${RED}✘ Could not detect installed version to repair.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✔ Installed Version: $WP_VERSION${NC}"
    version_urls "$WP_VERSION"

elif [[ "$action" == "update" ]]; then
    version_urls "latest"

elif [[ "$action" == "v695" ]]; then
    version_urls "6.9.5"

elif [[ "$action" == "custom" ]]; then
    read -p "Enter custom WP version (example: 6.8.3): " CUSTOM_VERSION
    version_urls "$CUSTOM_VERSION"
fi


#############################################
#  STEP 5 — Download & Replace Core
#############################################

fetch_wp "$URL_IR" "$URL_ORG" || exit 1


#############################################
#  MOVE OLD CORE INSTEAD OF REMOVING
#############################################

echo -e "${BLUE}Creating old-core directory...${NC}"
mkdir -p old-core

echo -e "${BLUE}Moving old WordPress core files into old-core...${NC}"

mv wp-admin old-core/ 2>/dev/null
mv wp-includes old-core/ 2>/dev/null

for f in "${CORE_FILES[@]}"; do
    [[ -f "$f" ]] && mv "$f" old-core/
done


#############################################
# Copy new core
#############################################

echo -e "${BLUE}Copying new WordPress core...${NC}"
cp -R wordpress/* ./


echo -e "${BLUE}Cleaning temporary files...${NC}"
rm -rf wordpress wp.zip


#############################################
#  STEP 6 — Fix permissions
#############################################

apply_permissions


#############################################
#  DONE
#############################################

echo
echo -e "${GREEN}✔ WordPress core updated/repaired successfully!${NC}"
echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
echo
