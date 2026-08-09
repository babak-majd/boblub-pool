#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Fix Roundcube
#   Repair and reconfigure Roundcube webmail.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.0.2
# ════════════════════════════════════════════════════════════
VERSION="1.0.2"

# pipefail: a pipeline (e.g. `mysql ... | tee`) now reports the LEFT command's
# failure instead of tee's success — this is what was masking real DB errors.
# We deliberately do NOT use `set -e`: this is a repair script, it must keep
# going and report an honest summary rather than abort silently mid-cleanup.
set -o pipefail

# ======== COLORS ========
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
log_dir="/tmp/bobclub_log"
log_file="${log_dir}/fix_roundcube.log"

DA_MYSQL_CONF="/usr/local/directadmin/conf/mysql.conf"

DBNAME="da_roundcube"
MYSQL_DATA_DIR="/var/lib/mysql"

TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUPFILE="/root/${DBNAME}_backup_${TIMESTAMP}.sql"

mkdir -p "$log_dir"

# Overall status flag (0 = OK). Set to 1 on any real failure so the final
# banner tells the truth instead of always claiming success.
STATUS=0

# ======== HELPERS ========
# Log a styled line to screen + file.
log() {
    echo -e "${CYAN}$1${RESET}" | tee -a "$log_file"
}

# Run a command, tee its output to the log, and return the command's REAL
# exit code (PIPESTATUS[0]) — not tee's. This is the core fix.
run_logged() {
    "$@" 2>&1 | tee -a "$log_file"
    return "${PIPESTATUS[0]}"
}

# Is a MySQL/MariaDB server process actually running? Process-based on purpose:
# it does not depend on the socket path or on auth, so it is a trustworthy
# guard before we ever touch files on disk.
mysql_running() {
    pgrep -x mysqld    >/dev/null 2>&1 && return 0
    pgrep -x mariadbd  >/dev/null 2>&1 && return 0
    pgrep -x mysqld_safe >/dev/null 2>&1 && return 0
    return 1
}

# Detect the real systemd service name (mariadb / mysqld / mysql).
detect_service() {
    local svc
    for svc in mariadb mysqld mysql mysqld@; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            echo "$svc"
            return 0
        fi
    done
    return 1
}

# Detect the MySQL socket. The 2002 error happened because the client defaulted
# to /tmp/mysql.sock while the server listens elsewhere. Prefer my.cnf, then the
# usual DirectAdmin/DEB/RPM locations; only return one that actually exists.
detect_socket() {
    local cnf_sock s
    cnf_sock=$(grep -hoP '^\s*socket\s*=\s*\K\S+' \
                 /etc/my.cnf /etc/mysql/my.cnf \
                 /etc/my.cnf.d/*.cnf /etc/mysql/mysql.conf.d/*.cnf 2>/dev/null | head -n1)
    for s in "$cnf_sock" \
             /var/lib/mysql/mysql.sock \
             /var/run/mysqld/mysqld.sock \
             /run/mysqld/mysqld.sock \
             /usr/local/mysql/data/mysql.sock \
             /tmp/mysql.sock; do
        [ -n "$s" ] && [ -S "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

# ======== MAIN ========
print_header

log "${BLUE}${BOLD}📄 Reading MySQL credentials from:${RESET} ${DA_MYSQL_CONF}"

if [ ! -f "$DA_MYSQL_CONF" ]; then
    log "${RED}${BOLD}❌ ERROR:${RESET} MySQL config file not found!"
    exit 1
fi

DBUSER=$(grep '^user=' "$DA_MYSQL_CONF" | cut -d= -f2)
DBPASS=$(grep '^passwd=' "$DA_MYSQL_CONF" | cut -d= -f2)

if [ -z "$DBUSER" ]; then
    log "${RED}${BOLD}❌ ERROR:${RESET} Could not read MySQL user from config."
    exit 1
fi

log "${GREEN}✅ MySQL user detected:${RESET} ${BOLD}$DBUSER${RESET}"

# Build a reusable connection argument list, pinning the correct socket if found.
SOCK=$(detect_socket) && log "${GREEN}✅ MySQL socket:${RESET} ${BOLD}$SOCK${RESET}" \
                      || log "${YELLOW}⚠️ No MySQL socket found — using client default.${RESET}"
MYSQL_CONN=(-u "$DBUSER" -p"$DBPASS")
[ -n "$SOCK" ] && MYSQL_CONN+=(--socket="$SOCK")

# ======== BACKUP ========
log "${MAGENTA}${BOLD}📦 Attempting backup of database:${RESET} $DBNAME"

if mysqldump "${MYSQL_CONN[@]}" "$DBNAME" > "$BACKUPFILE" 2>>"$log_file"; then
    log "${GREEN}✅ Backup created:${RESET} $BACKUPFILE"
else
    log "${YELLOW}⚠️ Backup failed — database may not exist. Continuing...${RESET}"
    rm -f "$BACKUPFILE"   # don't leave an empty/partial dump lying around
fi

# ======== DROP DATABASE ========
log "${MAGENTA}${BOLD}🗑️ Dropping database:${RESET} $DBNAME"

if run_logged mysql "${MYSQL_CONN[@]}" -e "DROP DATABASE IF EXISTS \`${DBNAME}\`;"; then
    log "${GREEN}✅ DROP DATABASE executed successfully.${RESET}"
else
    STATUS=1
    log "${RED}${BOLD}❌ DROP DATABASE failed${RESET} — could not talk to MySQL."
    log "${YELLOW}   Fix the connection/socket above before rebuilding, otherwise${RESET}"
    log "${YELLOW}   'da build roundcube' will hit 'table already exists'.${RESET}"
fi

# ======== CLEANUP DATA DIRECTORY (LAST RESORT, GUARDED) ========
# A leftover dir means DROP could not fully clear InnoDB. Removing files under a
# LIVE server is exactly what corrupted things last time, so we only do it when
# the server is genuinely stopped — and we refuse to guess the service name.
if [ -d "${MYSQL_DATA_DIR}/${DBNAME}" ]; then
    log "${YELLOW}⚠️ Leftover MySQL directory found:${RESET} ${MYSQL_DATA_DIR}/${DBNAME}"

    MYSQL_SERVICE=$(detect_service) \
        && log "${GREEN}✅ MySQL service:${RESET} ${BOLD}$MYSQL_SERVICE${RESET}" \
        || log "${RED}❌ Could not detect MySQL service (mariadb/mysqld/mysql).${RESET}"

    if [ -z "$MYSQL_SERVICE" ]; then
        STATUS=1
        log "${RED}${BOLD}⏭️ Skipping filesystem cleanup${RESET} — no service to stop safely."
    else
        log "${YELLOW}🔻 Stopping ${MYSQL_SERVICE}...${RESET}"
        run_logged systemctl stop "$MYSQL_SERVICE"
        sleep 2

        if mysql_running; then
            STATUS=1
            log "${RED}${BOLD}⏭️ MySQL is still running — refusing to rm data dir.${RESET}"
            log "${YELLOW}   (Removing DB files under a live server causes exactly the${RESET}"
            log "${YELLOW}    '[1050] table already exists' error you saw.)${RESET}"
        else
            log "${BLUE}🧹 Server stopped — removing leftover directory...${RESET}"
            rm -rf "${MYSQL_DATA_DIR:?}/${DBNAME}"
            log "${GREEN}✅ Leftover directory removed.${RESET}"
            log "${YELLOW}🔺 Starting ${MYSQL_SERVICE}...${RESET}"
            if ! run_logged systemctl start "$MYSQL_SERVICE"; then
                STATUS=1
                log "${RED}${BOLD}❌ Failed to start ${MYSQL_SERVICE}!${RESET}"
            fi
        fi
    fi
fi

# ======== REBUILD ROUNDCUBE ========
log "${BLUE}${BOLD}🛠️ Running:${RESET} da build roundcube"

if run_logged da build roundcube; then
    log "${GREEN}${BOLD}✅ Roundcube has been rebuilt successfully.${RESET}"
else
    STATUS=1
    log "${RED}${BOLD}❌ Error rebuilding Roundcube.${RESET} See ${log_file}"
fi

# ======== HONEST SUMMARY ========
if [ "$STATUS" -eq 0 ]; then
    log "${GREEN}${BOLD}🎉 ALL DONE — Operation completed successfully.${RESET}"
else
    log "${RED}${BOLD}⚠️ FINISHED WITH ERRORS — see ${log_file}${RESET}"
fi

exit "$STATUS"
