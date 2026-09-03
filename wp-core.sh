#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  WP Core Manager
#   Repair, update, install WordPress core, or provision a fresh site.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.6.1
# ════════════════════════════════════════════════════════════
VERSION="1.6.1"

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
SCRIPT_NAME="wp-core"
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

#############################################
#  USAGE + ARGUMENT PARSING
#############################################
# Flags let every prompt be answered up-front for non-interactive runs; any
# value left unset simply falls back to its interactive prompt further down.
usage() {
    cat <<EOF
Usage: wp-core.sh [options] [path]

Repair, update, or install WordPress core, or provision a fresh site.
Every option is optional; anything you omit is asked for interactively,
so the script stays fully usable with no arguments at all.

Options:
  -d, --domain <domain>   Domain used to resolve the webroot (cPanel/DirectAdmin).
  -p, --path <path>       Explicit path to the webroot (skips domain lookup).
                          A bare positional path works too.
  -r, --repair            Repair the currently installed version.
  -u, --update            Update the core to the latest version.
  -i, --install           Install a specific version (see -V; asked if omitted).
  -b, --rollback          Roll back to the previous core (old-core/).
  -f, --fresh             Fresh install — provision a brand-new site.
  -A, --admin             Manage administrator users.
      --admin-user <u>    Create that administrator without prompting. When
                          omitted, the next free "admin", "admin1", "admin2"…
                          login is used instead.
      --admin-email <e>   Email for the created administrator (optional).
      --admin-pass <p>    Password for it (default: auto-generated).
  -V, --version <ver>     Version for --install / --fresh (e.g. 6.9.5, latest).
  -z, --custom-url <url>  Use this URL as the core package instead of resolving
                          a version (works with --install/--fresh; skips -V).
  -Z, --custom-zip <path> Use this local zip file as the core package. Accepts
                          either layout: zip -> wordpress/ -> wp-config-sample.php,
                          etc. (default), or zip -> wp-config-sample.php, etc.
                          directly at the zip root.
  -y, --yes               Assume "yes" for confirmation prompts.
  -h, --help              Show this help and exit.

Examples:
  wp-core.sh
  wp-core.sh -d site.ir --update
  wp-core.sh -p /home/u/public_html --install --version 6.8.3 -y
  wp-core.sh -d site.ir --fresh --version latest -y
  wp-core.sh -d site.ir --admin-user bob --admin-email bob@site.ir
  wp-core.sh -d site.ir -A -y            # auto login + auto password
  wp-core.sh -d site.ir --install --custom-url https://example.com/core.zip -y
  wp-core.sh -p /home/u/public_html --install --custom-zip /root/core.zip -y
EOF
}

DOMAIN=""
WP_PATH=""
ACTION=""
REQ_VERSION=""
CUSTOM_URL=""
CUSTOM_ZIP=""
ASSUME_YES=""
ADMIN_USER=""
ADMIN_EMAIL=""
ADMIN_PASS=""
ADMIN_CREATE=""

# Only one action may be chosen at a time; a second one is a usage error.
set_action() {
    if [ -n "$ACTION" ] && [ "$ACTION" != "$1" ]; then
        echo -e "${RED}✘ Only one action may be given at a time.${NC}" >&2
        exit 1
    fi
    ACTION="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)   [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; DOMAIN="$2"; shift 2 ;;
        -p|--path)     [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; WP_PATH="$2"; shift 2 ;;
        -V|--version)  [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; REQ_VERSION="$2"; shift 2 ;;
        -z|--custom-url) [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; CUSTOM_URL="$2"; shift 2 ;;
        -Z|--custom-zip) [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; CUSTOM_ZIP="$2"; shift 2 ;;
        -r|--repair)   set_action repair;   shift ;;
        -u|--update)   set_action update;   shift ;;
        -i|--install)  set_action install;  shift ;;
        -b|--rollback) set_action rollback; shift ;;
        -f|--fresh)    set_action fresh;    shift ;;
        -A|--admin)    set_action admin;    shift ;;
        --admin-user)  [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; ADMIN_USER="$2";  ADMIN_CREATE="yes"; set_action admin; shift 2 ;;
        --admin-email) [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; ADMIN_EMAIL="$2"; ADMIN_CREATE="yes"; set_action admin; shift 2 ;;
        --admin-pass)  [ -n "$2" ] || { echo -e "${RED}✘ $1 requires a value.${NC}" >&2; exit 1; }; ADMIN_PASS="$2";  ADMIN_CREATE="yes"; set_action admin; shift 2 ;;
        -y|--yes)      ASSUME_YES="yes";    shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            echo -e "${RED}✘ Unknown option: $1${NC}" >&2; usage; exit 1 ;;
        *)             WP_PATH="$1"; shift ;;   # bare positional path
    esac
done

if [ "$ACTION" = "admin" ] && [ -n "$ASSUME_YES" ]; then
    ADMIN_CREATE="yes"
fi

if [ -n "$CUSTOM_URL" ] && [ -n "$CUSTOM_ZIP" ]; then
    echo -e "${RED}✘ Use either --custom-url or --custom-zip, not both.${NC}" >&2
    exit 1
fi

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

# Fully random password — every character is drawn from /dev/urandom, with no
# fixed prefix/suffix. Retries until the result contains at least one lowercase,
# uppercase, digit and symbol, so common panel/WordPress policies are satisfied.
# The first character is always alphanumeric: cPanel's apitool reads an argument
# value that starts with "@" as "@filename" and dies trying to load that file,
# and a leading "-" can be mistaken for a flag by other tools.
gen_password() {
    local len="${1:-20}" pool='A-Za-z0-9@#%^*_+=-' pass i
    for ((i = 0; i < 32; i++)); do
        pass=$(LC_ALL=C tr -dc "$pool" < /dev/urandom | head -c "$len")
        if [[ $pass == [A-Za-z0-9]* && $pass == *[a-z]* && $pass == *[A-Z]* \
              && $pass == *[0-9]* && $pass == *[@\#%^*_+=-]* ]]; then
            printf '%s' "$pass"
            return 0
        fi
    done
    [[ $pass == [A-Za-z0-9]* ]] || pass="P${pass:1}"
    printf '%s' "$pass"
}

# 64-char salt for wp-config secret keys (no quote/backslash chars).
gen_salt() {
    tr -dc 'A-Za-z0-9!@#%^*()_+=-' < /dev/urandom | head -c 64
}

# Escape a value for safe use on the replacement side of `sed s|...|VALUE|`.
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
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

# Extract wp.zip and normalize its contents into ./wordpress, whether the zip
# wraps the core in a top-level wordpress/ folder (the wordpress.org layout) or
# drops it flat at the zip root (some custom/mirror packages) — either way the
# rest of the script only ever deals with a ./wordpress directory.
extract_wp_zip() {
    local zip_file="$1" stage
    echo -e "${BLUE}Extracting...${NC}"
    stage=$(mktemp -d) || { echo -e "${RED}✘ Could not create a staging directory.${NC}"; return 1; }
    if ! unzip -q -o "$zip_file" -d "$stage"; then
        echo -e "${RED}✘ Extraction failed!${NC}"; rm -rf "$stage"; return 1
    fi

    rm -rf wordpress   # clear any stale leftover before we (re)populate it
    if [[ -d "$stage/wordpress" ]]; then
        mv "$stage/wordpress" ./wordpress
        rm -rf "$stage"
    elif [[ -f "$stage/wp-settings.php" || -f "$stage/wp-load.php" ]]; then
        mv "$stage" ./wordpress   # flat zip — the staged dir itself becomes wordpress/
    else
        echo -e "${RED}✘ Zip does not look like a WordPress core package${NC} (no wordpress/ folder and no wp-load.php at its root)."
        rm -rf "$stage"
        return 1
    fi

    [[ -d "wordpress" ]] || { echo -e "${RED}✘ Extraction failed!${NC}"; return 1; }
    return 0
}

# Download + extract a WordPress package, leaving a normalized `wordpress/` dir.
fetch_wp() {
    local url_ir="$1" url_org="$2"
    echo -e "${BLUE}↓ Downloading WordPress package...${NC}"
    if ! wget -O wp.zip "$url_ir"; then
        echo -e "${YELLOW}IR mirror failed, trying official source...${NC}"
        wget -O wp.zip "$url_org" || { echo -e "${RED}Download failed!${NC}"; return 1; }
    fi
    extract_wp_zip wp.zip
}

# Resolve the WordPress core package to use: an operator-supplied local zip
# (--custom-zip) or URL (--custom-url) take priority over the normal
# IR-mirror/official version lookup.
get_wp_package() {
    local version="$1"
    if [[ -n "$CUSTOM_ZIP" ]]; then
        echo -e "${BLUE}Using custom core zip:${NC} $CUSTOM_ZIP"
        [[ -f "$CUSTOM_ZIP" ]] || { echo -e "${RED}✘ Zip file not found: $CUSTOM_ZIP${NC}"; return 1; }
        cp -- "$CUSTOM_ZIP" wp.zip || { echo -e "${RED}✘ Could not stage zip file.${NC}"; return 1; }
        extract_wp_zip wp.zip
        return $?
    fi
    if [[ -n "$CUSTOM_URL" ]]; then
        echo -e "${BLUE}↓ Downloading custom WordPress package...${NC} $CUSTOM_URL"
        wget -O wp.zip "$CUSTOM_URL" || { echo -e "${RED}Download failed!${NC}"; return 1; }
        extract_wp_zip wp.zip
        return $?
    fi
    version_urls "$version"
    fetch_wp "$URL_IR" "$URL_ORG"
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
WEBROOT=""

# An explicit --path wins outright. Otherwise resolve from a domain (asked for
# only when -d was not supplied); an empty answer falls back to the current dir.
if [ -n "$WP_PATH" ]; then
    WEBROOT="$WP_PATH"
    echo -e "${GREEN}✔ Using provided path:${NC}"
    echo -e "${BLUE}Public Webroot:${NC} $WEBROOT"
fi

if [ -z "$WEBROOT" ] && [ -z "$DOMAIN" ]; then
    read -p "$(echo -e ${YELLOW}'Enter domain (or press Enter to use current directory as public_html): '${NC})" DOMAIN
fi

if [ -n "$WEBROOT" ]; then
    :   # resolved from --path above
elif [ -z "$DOMAIN" ]; then
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

# Webroot/domain is resolved — begin capturing the run to the log.
start_log "${DOMAIN:-$(basename "$WEBROOT")}"

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
        # An earlier run that aborted half-way can leave the database or the user
        # behind, so both are reused rather than treated as a failure; the
        # existing user is simply given the new password.
        out=$(uapi --output=json --user="$CP_USER" Mysql create_database name="$DB_NAME" 2>&1)
        if ! echo "$out" | grep -q '"errors":null'; then
            if echo "$out" | grep -qi 'already exists'; then
                echo -en "${YELLOW}database already exists, reusing... ${NC}"
            else
                echo -e "${RED}ERROR${NC}"; echo "$out"; return 1
            fi
        fi
        out=$(uapi --output=json --user="$CP_USER" Mysql create_user name="$DB_USER" password="$DB_PASS" 2>&1)
        if ! echo "$out" | grep -q '"errors":null'; then
            if echo "$out" | grep -qi 'already exists'; then
                echo -en "${YELLOW}user already exists, resetting password... ${NC}"
                out=$(uapi --output=json --user="$CP_USER" Mysql set_password \
                      user="$DB_USER" password="$DB_PASS" 2>&1)
            fi
            if ! echo "$out" | grep -q '"errors":null'; then
                echo -e "${RED}ERROR${NC}"; echo "$out"; return 1
            fi
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
    if [ -n "$REQ_VERSION" ]; then
        INSTALL_VERSION="$REQ_VERSION"
        echo -e "${BLUE}Version to install:${NC} $INSTALL_VERSION"
    elif [[ -n "$CUSTOM_ZIP" ]]; then
        echo -e "${BLUE}Custom core zip:${NC} $CUSTOM_ZIP"
    elif [[ -n "$CUSTOM_URL" ]]; then
        echo -e "${BLUE}Custom core URL:${NC} $CUSTOM_URL"
    else
        read -p "$(echo -e ${CYAN}'Version to install [default 6.9.5], "latest", or a custom zip URL/local path: '${NC})" INSTALL_INPUT
        if [[ "$INSTALL_INPUT" =~ ^https?:// ]]; then
            CUSTOM_URL="$INSTALL_INPUT"
            echo -e "${BLUE}Custom core URL:${NC} $CUSTOM_URL"
        elif [[ -n "$INSTALL_INPUT" && -f "$INSTALL_INPUT" ]]; then
            CUSTOM_ZIP="$INSTALL_INPUT"
            echo -e "${BLUE}Custom core zip:${NC} $CUSTOM_ZIP"
        else
            INSTALL_VERSION=${INSTALL_INPUT:-6.9.5}
        fi
    fi

    echo -e "${RED}⚠ This moves EVERY existing file in the webroot into old-files/.${NC}"
    if [[ "$ASSUME_YES" != "yes" ]]; then
        read -p "$(echo -e ${YELLOW}'Proceed with fresh install? [y/N]: '${NC})" CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; exit 0; }
    fi

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
    get_wp_package "$INSTALL_VERSION" || exit 1

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

    # Confirm the version that actually landed on disk.
    local new_version=""
    [[ -f "wp-includes/version.php" ]] && \
        new_version=$(grep "\$wp_version =" wp-includes/version.php | cut -d"'" -f2)

    echo
    echo -e "${GREEN}✔ WordPress installation completed successfully!${NC}"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    [[ -n "$new_version" ]] && echo -e "  ${BLUE}Installed ver :${NC} $new_version"
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
#  DIRECT DATABASE ACCESS  (no PHP involved)
#############################################
# Everything below talks to MySQL with the credentials in wp-config.php. The
# site's own PHP version is irrelevant, nothing bootstraps WordPress, and no
# plugin code is executed.
WPDB_NAME=""
WPDB_USER=""
WPDB_PASS=""
WPDB_HOST=""
WPDB_PREFIX="wp_"
WPDB_MULTISITE=""
WPDB_READY=""
WPDB_ARGS=()

# Value of a define('NAME', 'value') in wp-config.php. Both quote styles are
# accepted and their PHP escapes are decoded, so a password holding a backslash
# or a quote survives the trip.
wpconf_define() {
    local raw
    raw=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*'\(.*\)'[[:space:]]*)[[:space:]]*;.*/\1/p" \
          wp-config.php 2>/dev/null | head -n1)
    if [[ -n "$raw" ]]; then
        printf '%s' "$raw" | sed -e "s/\\\\'/'/g" -e 's/\\\\/\\/g'
        return
    fi
    raw=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*\"\(.*\)\"[[:space:]]*)[[:space:]]*;.*/\1/p" \
          wp-config.php 2>/dev/null | head -n1)
    printf '%s' "$raw" | sed -e 's/\\"/"/g' -e 's/\\\$/$/g' -e 's/\\\\/\\/g'
}

# Escape a value for a single-quoted SQL literal.
sql_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

# Run the SQL arriving on stdin; rows come back tab-separated, no headers.
# --no-defaults keeps a stray ~/.my.cnf from hijacking the credentials, and
# MYSQL_PWD keeps the password out of the process list.
wpdb_query() {
    MYSQL_PWD="$WPDB_PASS" mysql --no-defaults -u "$WPDB_USER" "${WPDB_ARGS[@]}" \
        -N -B --connect-timeout=10 "$WPDB_NAME"
}

# Read wp-config.php and find a connection that actually works. Cached.
wpdb_init() {
    if [[ -n "$WPDB_READY" ]]; then
        [[ "$WPDB_READY" == "yes" ]]
        return
    fi
    WPDB_READY="no"

    [[ -f "wp-config.php" ]] || return 1
    command -v mysql >/dev/null 2>&1 || return 1

    WPDB_NAME=$(wpconf_define DB_NAME)
    WPDB_USER=$(wpconf_define DB_USER)
    WPDB_PASS=$(wpconf_define DB_PASSWORD)
    WPDB_HOST=$(wpconf_define DB_HOST)
    [[ -n "$WPDB_NAME" && -n "$WPDB_USER" ]] || return 1

    local pfx
    pfx=$(sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
          wp-config.php 2>/dev/null | head -n1)
    [[ -n "$pfx" ]] && WPDB_PREFIX="$pfx"

    grep -qE "define\(\s*['\"]MULTISITE['\"]\s*,\s*true" wp-config.php 2>/dev/null \
        && WPDB_MULTISITE="yes"

    # DB_HOST is "host", "host:port" or "host:/path/to/socket".
    local host="${WPDB_HOST:-localhost}" hostname port="" socket=""
    hostname="${host%%:*}"
    [[ "$host" == *:* ]] && port="${host#*:}"
    if [[ "$port" == /* ]]; then socket="$port"; port=""; fi
    [[ -n "$hostname" ]] || hostname="localhost"

    # First candidate is what wp-config asks for; the rest cover servers whose
    # socket path differs from the client's compiled-in default.
    local -a candidates=()
    if [[ -n "$socket" ]]; then
        candidates+=("--socket=$socket")
    elif [[ -n "$port" ]]; then
        candidates+=("--host=$hostname|--port=$port|--protocol=TCP")
    else
        candidates+=("--host=$hostname")
    fi
    candidates+=(
        "--socket=/var/lib/mysql/mysql.sock"
        "--socket=/var/run/mysqld/mysqld.sock"
        "--socket=/tmp/mysql.sock"
        "--host=127.0.0.1|--protocol=TCP"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        IFS='|' read -r -a WPDB_ARGS <<< "$candidate"
        if wpdb_query <<< "SELECT 1;" >/dev/null 2>&1; then
            WPDB_READY="yes"
            return 0
        fi
    done

    WPDB_ARGS=()
    return 1
}

# Shared "we cannot reach the database" complaint.
wpdb_require() {
    wpdb_init && return 0
    if [[ ! -f "wp-config.php" ]]; then
        echo -e "${RED}✘ wp-config.php not found — cannot reach the database.${NC}"
    elif ! command -v mysql >/dev/null 2>&1; then
        echo -e "${RED}✘ No mysql client found; admin management needs one.${NC}"
    else
        echo -e "${RED}✘ Could not connect with the credentials in wp-config.php.${NC}"
    fi
    return 1
}


#############################################
#  ADMINISTRATOR USER MANAGEMENT
#############################################

# Pull s:N:"key";s:N:"value" out of a serialized option blob.
serialized_str() {
    printf '%s' "$1" | sed -n "s/.*s:[0-9]*:\"$2\";s:[0-9]*:\"\([^\"]*\)\".*/\1/p" | head -n1
}

# Same, but only inside the sub-array that follows a given key.
serialized_nested() {
    printf '%s' "$1" | awk -v outer="$2" -v inner="$3" '{
        pos = index($0, "\"" outer "\"")
        if (pos == 0) exit
        rest = substr($0, pos)
        if (match(rest, "s:[0-9]+:\"" inner "\";s:[0-9]+:\"[^\"]*\"")) {
            hit = substr(rest, RSTART, RLENGTH)
            sub("^s:[0-9]+:\"" inner "\";s:[0-9]+:\"", "", hit)
            sub("\"$", "", hit)
            print hit
        }
    }'
}

WPC_INFO_DONE=""
WPC_LOGIN_URL=""
WPC_LOGIN_PLUGIN=""
WPC_LOGIN_CUSTOM=""
WPC_SITE_URL=""
WPC_HOME_URL=""
WPC_LOGIN_WARN=""

# One pass over wp_options: site addresses plus wherever the login form moved.
# Every known "hide login" plugin keeps its slug in an option, so the answer
# comes straight out of the database instead of from a WordPress bootstrap.
wp_info() {
    if [[ -n "$WPC_INFO_DONE" ]]; then
        [[ -n "$WPC_LOGIN_URL" ]]
        return
    fi
    WPC_INFO_DONE="yes"
    wpdb_init || return 1

    local rows name value slug="" plugin="" active=""
    declare -A opt=()
    rows=$(wpdb_query <<SQL
SELECT option_name, option_value FROM \`${WPDB_PREFIX}options\`
 WHERE option_name IN ('siteurl','home','active_plugins','whl_page','rwl_page',
       'hmwp_login_url','aio_wp_security_configs','wd_masking_login_settings',
       'cerber_settings','perfmatters_options','itsec-storage');
SQL
    ) || return 1

    while IFS=$'\t' read -r name value; do
        [[ -n "$name" ]] && opt["$name"]="$value"
    done <<< "$rows"

    WPC_SITE_URL="${opt[siteurl]}"
    WPC_HOME_URL="${opt[home]}"
    [[ -n "$WPC_SITE_URL" ]] || return 1
    active="${opt[active_plugins]}"

    # Plain-string slugs first, then the ones buried in serialized arrays.
    if   [[ -n "${opt[whl_page]}"       ]]; then slug="${opt[whl_page]}";       plugin="WPS Hide Login"
    elif [[ -n "${opt[rwl_page]}"       ]]; then slug="${opt[rwl_page]}";       plugin="Rename wp-login.php"
    elif [[ -n "${opt[hmwp_login_url]}" ]]; then slug="${opt[hmwp_login_url]}"; plugin="Hide My WP Ghost"
    fi
    if [[ -z "$slug" && -n "${opt[aio_wp_security_configs]}" ]]; then
        slug=$(serialized_str "${opt[aio_wp_security_configs]}" 'aiowps_login_page_slug')
        [[ -n "$slug" ]] && plugin="All In One WP Security"
    fi
    if [[ -z "$slug" && -n "${opt[wd_masking_login_settings]}" ]]; then
        slug=$(serialized_str "${opt[wd_masking_login_settings]}" 'mask_url')
        [[ -n "$slug" ]] && plugin="Defender"
    fi
    if [[ -z "$slug" && -n "${opt[cerber_settings]}" ]]; then
        slug=$(serialized_str "${opt[cerber_settings]}" 'loginpath')
        [[ -n "$slug" ]] && plugin="WP Cerber"
    fi
    if [[ -z "$slug" && -n "${opt[perfmatters_options]}" ]]; then
        slug=$(serialized_str "${opt[perfmatters_options]}" 'login_url')
        [[ -n "$slug" ]] && plugin="Perfmatters"
    fi
    if [[ -z "$slug" && -n "${opt[itsec-storage]}" ]]; then
        slug=$(serialized_nested "${opt[itsec-storage]}" 'hide-backend' 'slug')
        [[ -n "$slug" ]] && plugin="Solid Security"
    fi

    if [[ -n "$slug" ]]; then
        WPC_LOGIN_URL="${WPC_HOME_URL%/}/${slug#/}"
        WPC_LOGIN_PLUGIN="$plugin"
        WPC_LOGIN_CUSTOM="1"
    else
        WPC_LOGIN_URL="${WPC_SITE_URL%/}/wp-login.php"
        WPC_LOGIN_CUSTOM="0"
        # A login-hiding plugin we do not have an option key for: say so rather
        # than quietly reporting the default address.
        if printf '%s' "$active" | grep -qiE 'hide[-_]?(my[-_]?wp|login)|rename[-_]?wp[-_]?login|login[-_]?(url|lockdown)|wps-hide|sg-security|wp-cerber|better-wp-security|defender-security'; then
            WPC_LOGIN_WARN="a login-hiding plugin looks active — verify this address"
        fi
    fi
    return 0
}

# "Login URL: ..." plus the plugin that moved it, when one did.
print_login_url() {
    wp_info || return 0
    if [[ "$WPC_LOGIN_CUSTOM" == "1" ]]; then
        echo -e "${GREEN}✔ Login URL: ${WPC_LOGIN_URL}${NC}${WPC_LOGIN_PLUGIN:+ ${MAGENTA}(${WPC_LOGIN_PLUGIN})${NC}}"
    else
        echo -e "${GREEN}✔ Login URL: ${WPC_LOGIN_URL}${NC}"
        [[ -n "$WPC_LOGIN_WARN" ]] && echo -e "  ${YELLOW}⚠ ${WPC_LOGIN_WARN}${NC}"
    fi
}

wpdb_login_taken() {
    local hits
    hits=$(wpdb_query <<< "SELECT COUNT(*) FROM \`${WPDB_PREFIX}users\` WHERE user_login = '$(sql_escape "$1")';")
    [[ -n "$hits" && "$hits" != "0" ]]
}

# First free login in the admin, admin1, admin2... series — one query, not N.
wpdb_suggest_login() {
    local base="${1:-admin}" taken i
    taken=$(wpdb_query <<< "SELECT user_login FROM \`${WPDB_PREFIX}users\` WHERE user_login LIKE '$(sql_escape "$base")%';")
    if ! grep -qxF "$base" <<< "$taken"; then printf '%s' "$base"; return 0; fi
    for ((i = 1; i < 1000; i++)); do
        if ! grep -qxF "${base}${i}" <<< "$taken"; then printf '%s' "${base}${i}"; return 0; fi
    done
    printf '%s%s' "$base" "$RANDOM"
}

wpdb_list_admins() {
    local rows
    rows=$(wpdb_query <<SQL
SELECT u.ID, u.user_login, u.user_email, u.user_registered
  FROM \`${WPDB_PREFIX}users\` u
  JOIN \`${WPDB_PREFIX}usermeta\` m ON m.user_id = u.ID
 WHERE m.meta_key = '${WPDB_PREFIX}capabilities'
   AND m.meta_value LIKE '%"administrator"%'
 ORDER BY u.ID;
SQL
    ) || return 1
    if [[ -z "$rows" ]]; then
        echo "(no administrator accounts found)"
        return 0
    fi
    printf "%-5s  %-24s  %-32s  %s\n" 'ID' 'LOGIN' 'EMAIL' 'REGISTERED'
    while IFS=$'\t' read -r id login email reg; do
        [[ -n "$id" ]] && printf "%-5s  %-24s  %-32s  %s\n" "$id" "$login" "$email" "$reg"
    done <<< "$rows"
}

# WordPress accepts a bare MD5 in user_pass as its legacy format and silently
# re-hashes it to the modern one the first time the account logs in.
wpdb_set_password() {
    local login="$1" pass="$2" out uid
    uid=$(wpdb_query <<< "SELECT ID FROM \`${WPDB_PREFIX}users\` WHERE user_login = '$(sql_escape "$login")';")
    if [[ -z "$uid" ]]; then
        echo -e "${RED}✘ User '${login}' not found.${NC}" >&2
        return 2
    fi
    out=$(wpdb_query 2>&1 <<SQL
UPDATE \`${WPDB_PREFIX}users\` SET user_pass = MD5('$(sql_escape "$pass")') WHERE ID = ${uid};
DELETE FROM \`${WPDB_PREFIX}usermeta\` WHERE user_id = ${uid} AND meta_key = 'session_tokens';
SQL
    ) || { echo -e "${RED}✘ ${out}${NC}" >&2; return 1; }
    echo "Password updated for '${login}' (ID ${uid}) — other sessions signed out"
}

wpdb_create_admin() {
    local login="$1" email="$2" pass="$3" nicename out uid hits

    if wpdb_login_taken "$login"; then
        echo -e "${RED}✘ Login '${login}' already exists.${NC}" >&2
        return 3
    fi
    if [[ -n "$email" ]]; then
        hits=$(wpdb_query <<< "SELECT COUNT(*) FROM \`${WPDB_PREFIX}users\` WHERE user_email = '$(sql_escape "$email")';")
        if [[ -n "$hits" && "$hits" != "0" ]]; then
            echo -e "${RED}✘ Email '${email}' already exists.${NC}" >&2
            return 3
        fi
    fi

    nicename=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]' \
               | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
    [[ -n "$nicename" ]] || nicename="$login"

    out=$(wpdb_query 2>&1 <<SQL
INSERT INTO \`${WPDB_PREFIX}users\`
    (user_login, user_pass, user_nicename, user_email, user_url,
     user_registered, user_activation_key, user_status, display_name)
VALUES
    ('$(sql_escape "$login")', MD5('$(sql_escape "$pass")'), '$(sql_escape "$nicename")',
     '$(sql_escape "$email")', '', UTC_TIMESTAMP(), '', 0, '$(sql_escape "$login")');
SET @uid = LAST_INSERT_ID();
INSERT INTO \`${WPDB_PREFIX}usermeta\` (user_id, meta_key, meta_value) VALUES
    (@uid, 'nickname', '$(sql_escape "$login")'),
    (@uid, 'first_name', ''),
    (@uid, 'last_name', ''),
    (@uid, 'description', ''),
    (@uid, 'rich_editing', 'true'),
    (@uid, 'syntax_highlighting', 'true'),
    (@uid, 'comment_shortcuts', 'false'),
    (@uid, 'admin_color', 'fresh'),
    (@uid, 'use_ssl', '0'),
    (@uid, 'show_admin_bar_front', 'true'),
    (@uid, 'locale', ''),
    (@uid, '${WPDB_PREFIX}capabilities', 'a:1:{s:13:"administrator";b:1;}'),
    (@uid, '${WPDB_PREFIX}user_level', '10'),
    (@uid, 'dismissed_wp_pointers', '');
SELECT @uid;
SQL
    ) || { echo -e "${RED}✘ ${out}${NC}" >&2; return 4; }

    uid=$(printf '%s' "$out" | tail -n1)
    echo "Administrator '${login}' created (ID ${uid})"
    if [[ "$WPDB_MULTISITE" == "yes" ]]; then
        echo -e "${YELLOW}⚠ Multisite detected — the role was set on the main site only,${NC}"
        echo -e "${YELLOW}  and the account is not a network super admin.${NC}"
    fi
}

# --admin-user/--admin-email/--admin-pass (or -A -y): create without prompting.
create_admin_auto() {
    wpdb_require || return 1
    wp_info >/dev/null 2>&1

    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER=$(wpdb_suggest_login admin)
        echo -e "${BLUE}No --admin-user given — using${NC} ${GREEN}${ADMIN_USER}${NC}"
    fi
    if [[ -z "$ADMIN_PASS" ]]; then
        ADMIN_PASS=$(gen_password)
    fi

    wpdb_create_admin "$ADMIN_USER" "$ADMIN_EMAIL" "$ADMIN_PASS" || return 1
    echo -e "${GREEN}✔ Login: ${ADMIN_USER}  ·  Password: ${ADMIN_PASS}${NC}"
    print_login_url
}

manage_admins() {
    wpdb_require || return 1

    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}      Administrator User Management     ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if wp_info; then
        if [[ "$WPC_LOGIN_CUSTOM" == "1" ]]; then
            echo -e "  ${BLUE}Login URL:${NC} ${YELLOW}${WPC_LOGIN_URL}${NC}${WPC_LOGIN_PLUGIN:+ ${MAGENTA}(${WPC_LOGIN_PLUGIN})${NC}}"
        else
            echo -e "  ${BLUE}Login URL:${NC} ${GREEN}${WPC_LOGIN_URL}${NC}"
            [[ -n "$WPC_LOGIN_WARN" ]] && echo -e "  ${YELLOW}⚠ ${WPC_LOGIN_WARN}${NC}"
        fi
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    echo -e "${YELLOW}1) List administrator accounts${NC}"
    echo -e "${YELLOW}2) Change an administrator's password${NC}"
    echo -e "${YELLOW}3) Create a new administrator${NC}"
    echo
    read -p "$(echo -e ${GREEN}"Enter choice [1-3]: "${NC})" achoice

    case $achoice in
        1)
            echo
            wpdb_list_admins
            ;;
        2)
            echo
            echo -e "${BLUE}Current administrators:${NC}"
            wpdb_list_admins
            echo
            read -p "$(echo -e ${CYAN}'Login to update: '${NC})" A_LOGIN
            [[ -n "$A_LOGIN" ]] || { echo -e "${RED}✘ Login required.${NC}"; return 1; }
            read -s -p "$(echo -e ${CYAN}'New password (blank = auto-generate): '${NC})" A_PASS; echo
            if [[ -z "$A_PASS" ]]; then
                A_PASS=$(gen_password)
                echo -e "${BLUE}Generated password:${NC} $A_PASS"
            fi
            wpdb_set_password "$A_LOGIN" "$A_PASS" \
                && echo -e "${GREEN}✔ Done.${NC}"
            ;;
        3)
            echo
            A_SUGGEST=$(wpdb_suggest_login admin)
            read -p "$(echo -e ${CYAN}"New admin login (${A_SUGGEST}): "${NC})" A_LOGIN
            A_LOGIN="${A_LOGIN:-$A_SUGGEST}"
            [[ -n "$A_LOGIN" ]] || { echo -e "${RED}✘ Login required.${NC}"; return 1; }
            read -p "$(echo -e ${CYAN}'Email: '${NC})" A_EMAIL
            read -s -p "$(echo -e ${CYAN}'Password (blank = auto-generate): '${NC})" A_PASS; echo
            if [[ -z "$A_PASS" ]]; then
                A_PASS=$(gen_password)
                echo -e "${BLUE}Generated password:${NC} $A_PASS"
            fi
            if wpdb_create_admin "$A_LOGIN" "$A_EMAIL" "$A_PASS"; then
                echo -e "${GREEN}✔ Login: ${A_LOGIN}  ·  Password: ${A_PASS}${NC}"
                print_login_url
            fi
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

# Flag-driven actions skip the interactive menu entirely; without a flag we
# fall through to the numbered menu below.
if [ -n "$ACTION" ]; then
    case "$ACTION" in
        repair)   action="repair" ;;
        update)   action="update" ;;
        install)  action="custom"
                  [ -n "$REQ_VERSION" ] && CUSTOM_VERSION="$REQ_VERSION" ;;
        rollback) action="rollback" ;;
        admin)    if [ -n "$ADMIN_CREATE" ]; then create_admin_auto; else manage_admins; fi
                  exit $? ;;
        fresh)    fresh_install; exit 0 ;;
    esac
fi

if [ -z "$action" ]; then

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
if wp_info; then
    if [[ "$WPC_LOGIN_CUSTOM" == "1" ]]; then
        echo -e "  ${BLUE}Login URL      :${NC} ${YELLOW}${WPC_LOGIN_URL}${NC}${WPC_LOGIN_PLUGIN:+ ${MAGENTA}(${WPC_LOGIN_PLUGIN})${NC}}"
    else
        echo -e "  ${BLUE}Login URL      :${NC} ${GREEN}${WPC_LOGIN_URL}${NC}"
        [[ -n "$WPC_LOGIN_WARN" ]] && echo -e "  ${BLUE}               ${NC} ${YELLOW}⚠ ${WPC_LOGIN_WARN}${NC}"
    fi
    if [[ -n "$WPC_SITE_URL" && "$WPC_SITE_URL" != "$WPC_HOME_URL" ]]; then
        echo -e "  ${BLUE}WP address     :${NC} ${WPC_SITE_URL} ${YELLOW}(differs from site address)${NC}"
    fi
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

fi   # end interactive menu (skipped when an action flag was given)


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
    if [[ "$ASSUME_YES" != "yes" ]]; then
        read -p "$(echo -e ${YELLOW}'Restore the previous core? This replaces the current core [y/N]: '${NC})" CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${BLUE}Cancelled.${NC}"; exit 0; }
    fi

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

PKG_VERSION=""

if [[ "$action" == "repair" ]]; then
    if [[ -z "$WP_VERSION" ]]; then
        echo -e "${RED}✘ Could not detect installed version to repair.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✔ Installed Version: $WP_VERSION${NC}"
    PKG_VERSION="$WP_VERSION"

elif [[ "$action" == "update" ]]; then
    PKG_VERSION="latest"

elif [[ "$action" == "v695" ]]; then
    PKG_VERSION="6.9.5"

elif [[ "$action" == "custom" ]]; then
    if [[ -n "$CUSTOM_VERSION" ]]; then
        echo -e "${GREEN}✔ Install version: $CUSTOM_VERSION${NC}"
    elif [[ -n "$CUSTOM_ZIP" ]]; then
        echo -e "${BLUE}Custom core zip:${NC} $CUSTOM_ZIP"
    elif [[ -n "$CUSTOM_URL" ]]; then
        echo -e "${BLUE}Custom core URL:${NC} $CUSTOM_URL"
    else
        read -p "Enter custom WP version (example: 6.8.3), or a custom zip URL/local path: " CUSTOM_INPUT
        if [[ "$CUSTOM_INPUT" =~ ^https?:// ]]; then
            CUSTOM_URL="$CUSTOM_INPUT"
        elif [[ -n "$CUSTOM_INPUT" && -f "$CUSTOM_INPUT" ]]; then
            CUSTOM_ZIP="$CUSTOM_INPUT"
        else
            CUSTOM_VERSION="$CUSTOM_INPUT"
        fi
    fi
    PKG_VERSION="$CUSTOM_VERSION"
fi


#############################################
#  STEP 5 — Download & Replace Core
#############################################

get_wp_package "$PKG_VERSION" || exit 1


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

# Read back the version that actually landed on disk and confirm it.
NEW_WP_VERSION=""
if [[ -f "wp-includes/version.php" ]]; then
    NEW_WP_VERSION=$(grep "\$wp_version =" wp-includes/version.php | cut -d"'" -f2)
fi

echo
echo -e "${GREEN}✔ WordPress core updated/repaired successfully!${NC}"
if [[ -n "$NEW_WP_VERSION" ]]; then
    echo -e "${GREEN}✔ Installed version: ${NEW_WP_VERSION}${NC}"
else
    echo -e "${YELLOW}⚠ Could not read the installed version from wp-includes/version.php.${NC}"
fi
echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
echo
