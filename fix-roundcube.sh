#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Fix Roundcube
#   Repair and reconfigure Roundcube webmail.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.0.1
# ════════════════════════════════════════════════════════════
VERSION="1.0.1"
set -e

# ======== COLORS ========
# Color codes for styled terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RESET='\033[0m'
BOLD='\033[1m'

# ======== HEADER ========
print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Fix Roundcube${N}"
    echo -e "  Repair and reconfigure Roundcube webmail."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}

# ======== CONFIG ========
# Log directory and file
log_dir="/tmp/bobclub_log/"
log_file="${log_dir}/fix_roundcube.log"

# DirectAdmin MySQL configuration file
DA_MYSQL_CONF="/usr/local/directadmin/conf/mysql.conf"

# Roundcube DB name and MySQL data directory
DBNAME="da_roundcube"
MYSQL_DATA_DIR="/var/lib/mysql"

# Timestamp for backup file
TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUPFILE="/root/${DBNAME}_backup_${TIMESTAMP}.sql"

mkdir -p "$log_dir"

# ======== LOG FUNCTION ========
# Custom log function with color + tee for logging to file
log() {
    echo -e "${CYAN}$1${RESET}" | tee -a "$log_file"
}

# ======== MYSQL FUNCTIONS ========
# Stop MySQL/MariaDB service
stop_mysql() {
    log "${YELLOW}🔻 Stopping MySQL/MariaDB...${RESET}"
    if ! systemctl stop mariadb 2>&1 | tee -a "$log_file"; then
        systemctl stop mysqld 2>&1 | tee -a "$log_file"
    fi
}

# Start MySQL/MariaDB service
start_mysql() {
    log "${YELLOW}🔺 Starting MySQL/MariaDB...${RESET}"
    if ! systemctl start mariadb 2>&1 | tee -a "$log_file"; then
        systemctl start mysqld 2>&1 | tee -a "$log_file"
    fi
}

# ======== MAIN ========

print_header

log "${BLUE}${BOLD}📄 Reading MySQL credentials from:${RESET} ${DA_MYSQL_CONF}"

# Ensure DirectAdmin MySQL config file exists
if [ ! -f "$DA_MYSQL_CONF" ]; then
    log "${RED}${BOLD}❌ ERROR:${RESET} MySQL config file not found!"
    exit 1
fi

# Extract MySQL username and password from DirectAdmin configuration
DBUSER=$(grep '^user=' "$DA_MYSQL_CONF" | cut -d= -f2)
DBPASS=$(grep '^passwd=' "$DA_MYSQL_CONF" | cut -d= -f2)

log "${GREEN}✅ MySQL user detected:${RESET} ${BOLD}$DBUSER${RESET}"

# ======== BACKUP ========
# Attempt to create a backup of Roundcube database
log "${MAGENTA}${BOLD}📦 Attempting backup of database:${RESET} $DBNAME"

if mysqldump -u "$DBUSER" -p"$DBPASS" "$DBNAME" 2>&1 | tee -a "$log_file" > "$BACKUPFILE"; then
    log "${GREEN}✅ Backup created:${RESET} $BACKUPFILE"
else
    log "${YELLOW}⚠️ Backup failed — database may not exist. Continuing...${RESET}"
fi

# ======== DROP DATABASE ========
# Drop Roundcube database (if it exists)
log "${MAGENTA}${BOLD}🗑️ Dropping database:${RESET} $DBNAME"

if mysql -u "$DBUSER" -p"$DBPASS" -e "DROP DATABASE IF EXISTS \`${DBNAME}\`;" 2>&1 | tee -a "$log_file"; then
    log "${GREEN}✅ DROP DATABASE executed successfully.${RESET}"
else
    log "${YELLOW}⚠️ DROP DATABASE failed. Continuing...${RESET}"
fi

# ======== CLEANUP DATA DIRECTORY ========
# Remove leftover MySQL data directory for the Roundcube DB
if [ -d "${MYSQL_DATA_DIR}/${DBNAME}" ]; then
    log "${YELLOW}⚠️ Leftover MySQL directory found:${RESET} ${MYSQL_DATA_DIR}/${DBNAME}"
    log "${BLUE}🧹 Removing leftover directory...${RESET}"

    stop_mysql
    rm -rf "${MYSQL_DATA_DIR}/${DBNAME}" 2>&1 | tee -a "$log_file"
    start_mysql

    log "${GREEN}✅ Leftover directory removed.${RESET}"
fi

# ======== REBUILD ROUNDCUBE ========
# Use DirectAdmin command to rebuild Roundcube installation
log "${BLUE}${BOLD}🛠️ Running:${RESET} da build roundcube"

if da build roundcube 2>&1 | tee -a "$log_file"; then
    log "${GREEN}${BOLD}✅ Roundcube has been rebuilt successfully.${RESET}"
else
    log "${RED}${BOLD}❌ Error rebuilding Roundcube.${RESET}"
fi

log "${GREEN}${BOLD}🎉 ALL DONE — Operation completed successfully.${RESET}"

