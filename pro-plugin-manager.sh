#!/bin/bash

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
#  STEP 1 — Get Domain
#############################################

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}           Pro Plugin Manager          ${NC}"
echo -e "${CYAN}               bobclub.ir              ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

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
            exit 1
        fi
    fi

    #############################################
    # Detect DirectAdmin
    #############################################
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
#  STEP 2 — Menu
#############################################

echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}      Select WP Plugin Operation       ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${YELLOW}1) Woocomerce Manager (Soon)${NC}"
echo -e "${YELLOW}2) Elementor Manager (Soon)${NC}"
echo -e "${YELLOW}3) Search And Replace (Soon)${NC}"
echo -e "${YELLOW}4) Install latest Blue Gaurd${NC}"
echo

read -p "$(echo -e ${GREEN}"Enter choice [1-4]: "${NC})" choice

case $choice in
    1) echo -e "${MAGENTA}Invalid choice!${NC}"; exit 1 ;;
    2) echo -e "${MAGENTA}Invalid choice!${NC}"; exit 1 ;;
    3) echo -e "${MAGENTA}Invalid choice!${NC}"; exit 1 ;;
    4) action="bluegaurd" ;;
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
#  STEP 6 — Download & Install
#############################################

echo -e "${BLUE}↓ Downloading Blue Gaurd...${NC}"
wget -O blue-guard.zip "http://guard.iswps.ir/blue-guard/Blue-guard.zip" || { echo -e "${RED}Download failed!${NC}"; exit 1; }

echo -e "${BLUE}Extracting...${NC}"
unzip -q blue-guard.zip

if [[ ! -d "blue-guard" ]]; then
    echo -e "${RED}✘ Extraction failed!${NC}"
    exit 1
fi


#############################################
#  MOVE OLD CORE INSTEAD OF REMOVING
#############################################

echo -e "${BLUE}Creating Old Blue Guard directory...${NC}"
mkdir -p old-blue-guard

echo -e "${BLUE}Moving old Blue Guard core files into old-core...${NC}"

mv wp-content/plugins/blue-guard old-blue-guard/ 2>/dev/null
chmod -R 600 old-blue-guard/

#############################################
# Copy new core
#############################################

echo -e "${BLUE}Copying New blue Guard core...${NC}"
cp -R blue-guard wp-content/plugins


echo -e "${BLUE}Cleaning temporary files...${NC}"
rm -rf blue-guard blue-guard.zip


#############################################
#  STEP 7 — Fix permissions
#############################################

echo -e "${MAGENTA}Applying permissions...${NC}"
find wp-content/plugins \( -type d -exec chmod 755 {} + \) -o \( -type f -exec chmod 644 {} + \)

if [[ -n "$OWNER" ]]; then
    chown -R "$OWNER:$GROUP" wp-content/plugins/blue-guard 2>/dev/null
fi


#############################################
#  STEP 8 — Activate Plugin
#############################################

echo -e "${MAGENTA}Activating Plugin...${NC}"
activated=false
WP_CMD=""

# Temporary vars for portable wp
TMPDIR=""
ZIP=""
WPCLI=""

# 1) Try system wp if available
if command -v wp >/dev/null 2>&1; then
    WP_PATH=$(command -v wp)
    WP_CMD="$WP_PATH --allow-root"
    if $WP_CMD plugin activate blue-guard >/dev/null 2>&1; then
        echo -e "${GREEN}✔ Plugin activated via system wp${NC}"
        activated=true
    else
        echo -e "${YELLOW}⚠ system wp found but activation failed, trying other methods...${NC}"
        WP_CMD=""
    fi
fi

# 2) Try portable wp binary (download) - use /tmp (do not create a temp dir)
if [[ "$activated" != true ]]; then
    echo -e "${MAGENTA}Downloading portable wp binary to /tmp...${NC}"
    TMPDIR=""   # leave empty so later cleanup won't remove /tmp
    ZIP="/tmp/wp.zip"
    WPCLI="/tmp/wp"

    rm -f "$ZIP" "$WPCLI" 2>/dev/null

    if wget -q -O "$ZIP" "http://dl.iswps.ir/cli/wp.zip"; then
        # try to extract the wp executable into /tmp (junk paths)
        if unzip -j -o "$ZIP" 'wp' -d /tmp >/dev/null 2>&1 || unzip -j -o "$ZIP" '*wp' -d /tmp >/dev/null 2>&1; then
            if [[ -f "$WPCLI" ]]; then
                chmod +x "$WPCLI"
                WP_CMD="$WPCLI --allow-root"
                if $WP_CMD plugin activate blue-guard >/dev/null 2>&1; then
                    echo -e "${GREEN}✔ Plugin activated via portable wp${NC}"
                    activated=true
                else
                    echo -e "${YELLOW}⚠ Portable wp found but activation failed${NC}"
                    WP_CMD=""
                    rm -f "$ZIP" "$WPCLI" 2>/dev/null
                fi
            else
                echo -e "${YELLOW}⚠ wp binary not found inside zip${NC}"
                rm -f "$ZIP" 2>/dev/null
            fi
        else
            echo -e "${YELLOW}⚠ Failed to extract wp from zip${NC}"
            rm -f "$ZIP" 2>/dev/null
        fi
    else
        echo -e "${YELLOW}⚠ Failed to download portable wp${NC}"
    fi
fi

# 3) Fallback to control-panel specific wp-cli paths
if [[ "$activated" != true ]]; then
    if [[ "$ControlPanel" = "DirectAdmin" ]]; then
        echo -e "${MAGENTA}Trying DirectAdmin wp-cli phar...${NC}"
        DA_PHAR="/usr/local/directadmin/custombuild/cache/wp-cli-2.12.0.phar"
        if [[ -x "/usr/local/php81/bin/php" && -f "$DA_PHAR" ]]; then
            WP_CMD="/usr/local/php81/bin/php $DA_PHAR"
            if $WP_CMD plugin activate blue-guard --allow-root >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Plugin activated via DirectAdmin wp-cli phar${NC}"
                activated=true
            else
                echo -e "${YELLOW}⚠ DirectAdmin wp-cli phar activation failed${NC}"
                WP_CMD=""
            fi
        else
            echo -e "${YELLOW}⚠ DirectAdmin wp-cli phar not available${NC}"
        fi
    fi

    if [[ "$activated" != true && "$ControlPanel" = "Cpanel" ]]; then
        echo -e "${MAGENTA}Trying cPanel wp binary...${NC}"
        CP_WP="/usr/local/bin/wp"
        if [[ -x "$CP_WP" ]]; then
            WP_CMD="$CP_WP --allow-root"
            if $WP_CMD plugin activate blue-guard >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Plugin activated via cPanel wp binary${NC}"
                activated=true
            else
                echo -e "${YELLOW}⚠ cPanel wp binary activation failed${NC}"
                WP_CMD=""
            fi
        else
            echo -e "${YELLOW}⚠ cPanel wp binary not available${NC}"
        fi
    fi
fi

if [[ "$activated" != true ]]; then
    echo -e "${YELLOW}✘ Plugin activation could not be confirmed. You may need to activate it manually from WP-Admin or via wp-cli.${NC}"
fi

#############################################
#  STEP 9 — Verify plugin status
#############################################

echo -e "${MAGENTA}Checking plugin status...${NC}"

if [[ -n "$WP_CMD" ]]; then
    # Check if plugin is active
    if $WP_CMD plugin is-active blue-guard --allow-root >/dev/null 2>&1; then
        echo -e "${GREEN}✔ blue-guard is ACTIVE${NC}"
        # Show detailed status
        echo
        $WP_CMD plugin status blue-guard --allow-root 2>/dev/null || true
    else
        echo -e "${YELLOW}✘ blue-guard is NOT active${NC}"
        echo
        $WP_CMD plugin status blue-guard --allow-root 2>/dev/null || true
    fi
else
    echo -e "${YELLOW}⚠ No wp-cli available to check status. Please verify in WP-Admin or install wp-cli.${NC}"
fi

# Cleanup portable wp if it was downloaded and not needed anymore
if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    rm -f "$ZIP" "$WPCLI" 2>/dev/null
    rm -rf "$TMPDIR"
fi


#############################################
#  DONE
#############################################

echo
echo -e "${GREEN}✔ Blue Guard installed/updated/repaired successfully!${NC}"
echo -e "${GREEN}✔ Login to admin panel and clear cache if required.${NC}"
echo
