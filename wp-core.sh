#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  WP Core Manager
#   Repair, update or install WordPress core.
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

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}WP Core Manager${N}"
    echo -e "  Repair, update or install WordPress core."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "${C}${hr}${N}"
    echo
}

#############################################
#  STEP 1 — Get Domain
#############################################

print_header

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
            exit 1
        fi
    fi

    #############################################
    # Detect DirectAdmin
    #############################################
    if [ -d "/usr/local/directadmin" ] && [ -z "$WEBROOT" ]; then
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
            exit 1
        fi
    fi
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
#  Detect currently installed version
#############################################
WP_VERSION=""
if [[ -f "wp-includes/version.php" ]]; then
    WP_VERSION=$(grep "\$wp_version =" wp-includes/version.php | cut -d"'" -f2)
fi


#############################################
#  STEP 2 — Menu
#############################################

echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}      Select WordPress Operation      ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ -n "$WP_VERSION" ]]; then
    echo -e "  ${BLUE}Current version:${NC} ${GREEN}$WP_VERSION${NC}"
else
    echo -e "  ${BLUE}Current version:${NC} ${YELLOW}not detected${NC}"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${YELLOW}1) Repair existing version${NC}"
echo -e "${YELLOW}2) Update to latest version${NC}"
echo -e "${YELLOW}3) Install WordPress 6.9.4${NC}"
echo -e "${YELLOW}4) Install custom version${NC}"
echo -e "${YELLOW}5) Rollback to previous core (old-core)${NC}"
echo

read -p "$(echo -e ${GREEN}"Enter choice [1-5]: "${NC})" choice

case $choice in
    1) action="repair" ;;
    2) action="update" ;;
    3) action="v694" ;;
    4) action="custom" ;;
    5) action="rollback" ;;
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
#  STEP 4 — Detect Owner
#############################################
OWNER=""
GROUP=""

if command -v stat >/dev/null 2>&1; then
    OWNER=$(stat -c '%U' wp-config.php 2>/dev/null || stat -f '%Su' wp-config.php 2>/dev/null)
    GROUP=$(stat -c '%G' wp-config.php 2>/dev/null || stat -f '%Sg' wp-config.php 2>/dev/null)
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
#  STEP 5 — Determine package URL
#############################################

if [[ "$action" == "repair" ]]; then
    if [[ -z "$WP_VERSION" ]]; then
        echo -e "${RED}✘ Could not detect installed version to repair.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✔ Installed Version: $WP_VERSION${NC}"
    DOWNLOAD_URL_IR="http://mirror-ir.iswps.ir/core/wp$WP_VERSION.zip"
    DOWNLOAD_URL_ORG="https://wordpress.org/wordpress-$WP_VERSION.zip"

elif [[ "$action" == "update" ]]; then
    DOWNLOAD_URL_IR="http://mirror-ir.iswps.ir/core/latest.zip"
    DOWNLOAD_URL_ORG="https://wordpress.org/latest.zip"

elif [[ "$action" == "v694" ]]; then
    DOWNLOAD_URL_IR="http://mirror-ir.iswps.ir/core/wp6.9.4.zip"
    DOWNLOAD_URL_ORG="https://wordpress.org/wordpress-6.9.4.zip"

elif [[ "$action" == "custom" ]]; then
    read -p "Enter custom WP version (example: 6.8.3): " CUSTOM_VERSION
    DOWNLOAD_URL_IR="http://mirror-ir.iswps.ir/core/wp$CUSTOM_VERSION.zip"
    DOWNLOAD_URL_ORG="https://wordpress.org/wordpress-$CUSTOM_VERSION.zip"
fi


#############################################
#  STEP 6 — Download & Replace Core
#############################################

echo -e "${BLUE}↓ Downloading WordPress package...${NC}"

wget -O wp.zip "$DOWNLOAD_URL_IR"

if [[ $? -ne 0 ]]; then
    echo -e "${YELLOW}IR mirror failed, trying official source...${NC}"
    wget -O wp.zip "$DOWNLOAD_URL_ORG" || {
        echo -e "${RED}Download failed!${NC}"
        exit 1
    }
fi

echo -e "${BLUE}Extracting...${NC}"
unzip -q wp.zip

if [[ ! -d "wordpress" ]]; then
    echo -e "${RED}✘ Extraction failed!${NC}"
    exit 1
fi


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
#  STEP 7 — Fix permissions
#############################################

echo -e "${MAGENTA}Applying permissions...${NC}"
find . \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)

chmod 640 wp-config.php 2>/dev/null

if [[ -n "$OWNER" ]]; then
    chown -R "$OWNER:$GROUP" . 2>/dev/null
fi


#############################################
#  DONE
#############################################

echo
echo -e "${GREEN}✔ WordPress core updated/repaired successfully!${NC}"
echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
echo
