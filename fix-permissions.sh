#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Fix Permissions
#   Reset ownership, file modes and harden sensitive files
#   under a panel user's home directory.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
# ════════════════════════════════════════════════════════════

set -u

# ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# ---------- Options ----------
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=1
fi

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

read -rp "Enter username: " TARGET_USER

if [[ -z "$TARGET_USER" ]]; then
    echo -e "${RED}No username entered.${RESET}"
    exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
    echo -e "${RED}User '$TARGET_USER' does not exist.${RESET}"
    exit 1
fi

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

read -rp "Continue? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

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
    read -rp "[2/3] Fix web file modes (dirs 755 / files 644)? (y/N): " ANS
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

read -rp "[3/3] Harden sensitive files (wp-config.php/.env/.my.cnf -> 600)? (y/N): " ANS
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
