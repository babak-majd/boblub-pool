#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Perm Patrol
#   Patrol a panel user's home: reset ownership, fix file
#   modes and harden sensitive files.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.3.0
# ════════════════════════════════════════════════════════════
VERSION="1.3.0"

set -u

# ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------- Logging  (standard block — identical across all bobclub scripts) ----------
# One directory per script under /var/log, a sub-directory per target (the domain
# or user; empty for whole-server scripts), and one timestamped file per run.
# start_log <key> begins capturing the whole run to that file (colors stripped)
# via tee once the target key is known; it falls back to /tmp when /var/log is
# not writable (e.g. not root). finish_log() prints the final path on any exit.
# Self-contained (literal colors, set -u safe) so the block stays byte-identical
# between scripts.
SCRIPT_NAME="perm-patrol"
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

# ---------- Usage + argument parsing ----------
# Flags let every prompt be answered up-front for non-interactive runs; any
# value left unset simply falls back to its interactive prompt further down.
usage() {
    cat <<EOF
Usage: perm-patrol.sh [options] [username]

Patrol a panel user's home: reset ownership, fix web file modes, and harden
sensitive files. Every option is optional; anything you omit is asked for
interactively, so the script stays fully usable with no arguments at all.

Options:
  -u, --user <username>  Target panel username. A bare positional value works too.
  -n, --dry-run           Show what would change without making any changes.
  -m, --modes             Fix web file modes (dirs 755 / files 644) without asking.
  -s, --harden            Harden sensitive files (wp-config.php/.env/etc -> 600)
                          without asking.
  -y, --yes               Assume "yes" for every confirmation prompt, including
                          --modes and --harden.
  -h, --help              Show this help and exit.

Examples:
  perm-patrol.sh
  perm-patrol.sh -u exampleuser -y
  perm-patrol.sh --user exampleuser --dry-run
EOF
}

TARGET_USER=""
DRY_RUN=0
DO_MODES=""
DO_HARDEN=""
ASSUME_YES=""

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)     [ -n "${2:-}" ] || { echo -e "${RED}✘ $1 requires a value.${RESET}" >&2; exit 1; }; TARGET_USER="$2"; shift 2 ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -m|--modes)    DO_MODES="yes"; shift ;;
        -s|--harden)   DO_HARDEN="yes"; shift ;;
        -y|--yes)      ASSUME_YES="yes"; DO_MODES="yes"; DO_HARDEN="yes"; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            echo -e "${RED}✘ Unknown option: $1${RESET}" >&2; usage; exit 1 ;;
        *)             TARGET_USER="$1"; shift ;;   # bare positional username
    esac
done

# ---------- Header ----------
print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Perm Patrol${N}"
    echo -e "  Patrol a panel user's home: ownership & permissions."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}

print_header

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (chown/chmod require it).${RESET}"
    exit 1
fi

# ---------- Detect Control Panel ----------
if [[ -d /usr/local/directadmin ]]; then
    PANEL="DirectAdmin"
elif [[ -d /usr/local/cpanel ]]; then
    PANEL="cPanel"
else
    echo -e "${RED}Unsupported control panel!${RESET}"
    exit 1
fi

# Groups that are legitimate on any panel
ALLOWED_GROUPS=(mail nobody root daemon bin)
if [[ "$PANEL" == "DirectAdmin" ]]; then
    ALLOWED_GROUPS+=(apache access webapps)
else
    ALLOWED_GROUPS+=(mailman www)
fi

is_allowed_group() {
    local g
    for g in "${ALLOWED_GROUPS[@]}"; do
        [[ "$1" == "$g" ]] && return 0
    done
    return 1
}

echo -e "Detected Panel: ${CYAN}${PANEL}${RESET}"
echo

if [[ -z "$TARGET_USER" ]]; then
    read -rp "Enter username: " TARGET_USER
fi

if [[ -z "$TARGET_USER" ]]; then
    echo -e "${RED}No username entered.${RESET}"
    exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
    echo -e "${RED}User '$TARGET_USER' does not exist.${RESET}"
    exit 1
fi

# Username is valid — begin capturing the run to the log.
start_log "$TARGET_USER"

HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
PRIMARY_GROUP=$(id -gn "$TARGET_USER")

if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    echo -e "${RED}Home directory not found: '$HOME_DIR'${RESET}"
    exit 1
fi

# Guard against system accounts whose "home" is a system path
case "$HOME_DIR" in
    /|/bin|/sbin|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sys|/usr|/var)
        echo -e "${RED}Refusing to operate on system path: $HOME_DIR${RESET}"
        exit 1
        ;;
esac

# ---------- Web roots (per panel) ----------
WEB_ROOTS=()
if [[ "$PANEL" == "DirectAdmin" ]]; then
    for d in "$HOME_DIR"/domains/*/public_html "$HOME_DIR"/domains/*/private_html; do
        # private_html is often a symlink to public_html — skip links
        [[ -d "$d" && ! -L "$d" ]] && WEB_ROOTS+=("$d")
    done
else
    [[ -d "$HOME_DIR/public_html" ]] && WEB_ROOTS+=("$HOME_DIR/public_html")
fi

echo
echo -e "User           : ${CYAN}$TARGET_USER${RESET}"
echo -e "Home Directory : ${CYAN}$HOME_DIR${RESET}"
echo -e "Primary Group  : ${CYAN}$PRIMARY_GROUP${RESET}"
echo -e "Web Roots      : ${CYAN}${WEB_ROOTS[*]:-none found}${RESET}"
(( DRY_RUN )) && echo -e "Mode           : ${YELLOW}dry-run (nothing will be changed)${RESET}"
echo

if [[ "$ASSUME_YES" != "yes" ]]; then
    read -rp "Continue? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

FAILED=0

# NUL-separated path lists, applied in batches with xargs at the
# end of each step — one chown/chmod fork per batch, not per file.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# apply_batch <list-file> <command...> — xargs the list, honors dry-run
apply_batch() {
    local list="$1"; shift
    [[ -s "$list" ]] || return 0
    (( DRY_RUN )) && return 0
    xargs -0 -r -- "$@" < "$list" || FAILED=1
}

# queue_chmod <list-file> <new-mode> <old-mode> <file>
queue_chmod() {
    if (( DRY_RUN )); then
        echo -e "${YELLOW}Would chmod:${RESET} $4  ($3 -> $2)"
    else
        echo -e "${GREEN}Chmod:${RESET} $4  ($3 -> $2)"
    fi
    printf '%s\0' "$4" >> "$1"
}

# ════════════════════════════════════════════
#  STEP 1 — Ownership
# ════════════════════════════════════════════
echo
echo -e "${CYAN}[1/3] Fixing ownership...${RESET}"

OWN_FIXED=0
LIST_BOTH="$TMP_DIR/chown_both"    # wrong owner and group
LIST_OWNER="$TMP_DIR/chown_owner"  # wrong owner, group kept
LIST_GROUP="$TMP_DIR/chown_group"  # wrong group, owner kept

FIX_LABEL="${GREEN}Fixing:${RESET}"
(( DRY_RUN )) && FIX_LABEL="${YELLOW}Would fix:${RESET}"

# One find pass emits owner<TAB>group<TAB>path\0 — no per-file stat forks.
# find does not follow symlinks, matching chown -h below.
while IFS=$'\t' read -r -d '' OWNER GROUP FILE; do
    OWNER_OK=1
    GROUP_OK=1

    case "$OWNER" in
        "$TARGET_USER"|root|nobody) ;;
        *) OWNER_OK=0 ;;
    esac

    if [[ "$GROUP" != "$PRIMARY_GROUP" ]] && ! is_allowed_group "$GROUP"; then
        GROUP_OK=0
    fi

    (( OWNER_OK && GROUP_OK )) && continue

    if (( !OWNER_OK && !GROUP_OK )); then
        echo -e "$FIX_LABEL $FILE  ($OWNER:$GROUP -> $TARGET_USER:$PRIMARY_GROUP)"
        printf '%s\0' "$FILE" >> "$LIST_BOTH"
    elif (( !OWNER_OK )); then
        echo -e "$FIX_LABEL $FILE  ($OWNER:$GROUP -> $TARGET_USER:$GROUP)"
        printf '%s\0' "$FILE" >> "$LIST_OWNER"
    else
        echo -e "$FIX_LABEL $FILE  ($OWNER:$GROUP -> $OWNER:$PRIMARY_GROUP)"
        printf '%s\0' "$FILE" >> "$LIST_GROUP"
    fi
    OWN_FIXED=$((OWN_FIXED + 1))
done < <(find "$HOME_DIR" -printf '%u\t%g\t%p\0')

apply_batch "$LIST_BOTH"  chown -h -- "$TARGET_USER:$PRIMARY_GROUP"
apply_batch "$LIST_OWNER" chown -h -- "$TARGET_USER"
apply_batch "$LIST_GROUP" chown -h -- ":$PRIMARY_GROUP"

# ════════════════════════════════════════════
#  STEP 2 — Web file modes (755 / 644)
# ════════════════════════════════════════════
echo
MODE_FIXED=0

if (( ${#WEB_ROOTS[@]} == 0 )); then
    echo -e "${YELLOW}[2/3] No web roots found — skipping mode fix.${RESET}"
else
    if [[ "$DO_MODES" == "yes" ]]; then
        ANS="y"
    else
        read -rp "[2/3] Fix web file modes (dirs 755 / files 644)? (y/N): " ANS
    fi
    if [[ "$ANS" =~ ^[Yy]$ ]]; then
        LIST_755="$TMP_DIR/chmod_755"
        LIST_644="$TMP_DIR/chmod_644"

        for ROOT in "${WEB_ROOTS[@]}"; do
            # Directories -> 755
            while IFS=$'\t' read -r -d '' OLD_MODE FILE; do
                queue_chmod "$LIST_755" 755 "$OLD_MODE" "$FILE"
                MODE_FIXED=$((MODE_FIXED + 1))
            done < <(find "$ROOT" -type d ! -perm 755 -printf '%m\t%p\0')

            # Files -> 644, but never loosen sensitive files (hardened to 600
            # in step 3) and never strip the exec bit off CGI scripts.
            while IFS=$'\t' read -r -d '' OLD_MODE FILE; do
                queue_chmod "$LIST_644" 644 "$OLD_MODE" "$FILE"
                MODE_FIXED=$((MODE_FIXED + 1))
            done < <(find "$ROOT" -type f ! -perm 644 \
                        ! -name wp-config.php ! -name '.env' ! -name '.htpasswd' \
                        ! -path '*/cgi-bin/*' -printf '%m\t%p\0')
        done

        apply_batch "$LIST_755" chmod 755 --
        apply_batch "$LIST_644" chmod 644 --
    else
        echo "Skipped."
    fi
fi

# ════════════════════════════════════════════
#  STEP 3 — Harden sensitive files
# ════════════════════════════════════════════
echo
HARD_FIXED=0

if [[ "$DO_HARDEN" == "yes" ]]; then
    ANS="y"
else
    read -rp "[3/3] Harden sensitive files (wp-config.php/.env/.my.cnf -> 600)? (y/N): " ANS
fi
if [[ "$ANS" =~ ^[Yy]$ ]]; then
    LIST_600="$TMP_DIR/chmod_600"

    # Secrets -> 600 (leave ~/.ssh alone)
    while IFS=$'\t' read -r -d '' OLD_MODE FILE; do
        queue_chmod "$LIST_600" 600 "$OLD_MODE" "$FILE"
        HARD_FIXED=$((HARD_FIXED + 1))
    done < <(find "$HOME_DIR" -path "$HOME_DIR/.ssh" -prune -o -type f \
                \( -name wp-config.php -o -name '.env' -o -name '.my.cnf' -o -name '.htpasswd' \) \
                ! -perm 600 -printf '%m\t%p\0')

    apply_batch "$LIST_600" chmod 600 --
else
    echo "Skipped."
fi

# ════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════
echo
if (( DRY_RUN )); then
    echo -e "${YELLOW}Dry run finished.${RESET}"
    echo -e "Would fix — ownership: $OWN_FIXED, modes: $MODE_FIXED, hardened: $HARD_FIXED"
elif (( FAILED )); then
    echo -e "${YELLOW}Done with errors${RESET} — some chown/chmod operations failed (see messages above)."
    echo -e "Ownership: $OWN_FIXED, Modes: $MODE_FIXED, Hardened: $HARD_FIXED"
    exit 1
else
    echo -e "${GREEN}Done.${RESET}"
    echo -e "Ownership: $OWN_FIXED, Modes: $MODE_FIXED, Hardened: $HARD_FIXED"
fi
