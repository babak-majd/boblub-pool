#!/bin/bash
# ════════════════════════════════════════════════════════════
#   bobclub.ir  ·  Thing To Link
#   Fetch a file or URL into the web root and make it accessible.
# ────────────────────────────────────────────────────────────
#   Website   : https://bobclub.ir
#   Scripts   : https://bobclub.ir/pool
#   Telegram  : https://t.me/bob_club
#   Version   : 1.1.0
# ════════════════════════════════════════════════════════════
VERSION="1.1.0"
set +H

WEBROOT="/var/www/html"

# ---------- Usage + argument parsing ----------
# Flags let every prompt be answered up-front for non-interactive runs; any
# value left unset simply falls back to its interactive prompt further down.
usage() {
    cat <<EOF
Usage: thing-to-link.sh [options] [input]

Fetch a file, directory, or URL and make it downloadable from the web root.
Every option is optional; anything you omit is asked for interactively, so
the script stays fully usable with no arguments at all.

Options:
  -i, --input <path|url>  File, directory, or URL to publish. A bare
                          positional value works too.
  -w, --webroot <dir>     Web root to publish into (default: /var/www/html).
  -c, --compress <type>   Compression for a directory input: tar.gz or zip
                          (skips the interactive prompt).
  -h, --help              Show this help and exit.

Examples:
  thing-to-link.sh
  thing-to-link.sh -i https://example.com/file.zip
  thing-to-link.sh -i /home/user/backups -c zip -w /var/www/html
EOF
}

input=""
COMPRESS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input)    [ -n "${2:-}" ] || { echo -e "\033[31m✘ $1 requires a value.\033[0m" >&2; exit 1; }; input="$2"; shift 2 ;;
        -w|--webroot)  [ -n "${2:-}" ] || { echo -e "\033[31m✘ $1 requires a value.\033[0m" >&2; exit 1; }; WEBROOT="$2"; shift 2 ;;
        -c|--compress) [ -n "${2:-}" ] || { echo -e "\033[31m✘ $1 requires a value.\033[0m" >&2; exit 1; }; COMPRESS="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            echo -e "\033[31m✘ Unknown option: $1\033[0m" >&2; usage; exit 1 ;;
        *)             input="$1"; shift ;;   # bare positional input
    esac
done

print_header() {
    local C='\033[1;36m' Y='\033[1;33m' B='\033[1m' N='\033[0m'
    local hr sr
    hr=$(printf '━%.0s' {1..48})
    sr=$(printf '─%.0s' {1..48})
    echo
    echo -e "${C}${hr}${N}"
    echo -e "  ${Y}${B}bobclub.ir${N}  ·  ${B}Thing To Link${N}"
    echo -e "  Fetch a file or URL into the web root."
    echo -e "${C}${sr}${N}"
    echo -e "  Website   : https://bobclub.ir"
    echo -e "  Pool      : https://bobclub.ir/pool"
    echo -e "  Telegram  : https://t.me/bob_club"
    echo -e "  Version   : ${VERSION}"
    echo -e "${C}${hr}${N}"
    echo
}
print_header

if [[ -z "$input" ]]; then
    read -p $'\033[36mEnter file path, directory, or URL:\033[0m ' input
fi

# اگر ورودی یک URL باشد
if [[ "$input" =~ ^https?:// ]]; then
    filename=$(basename "$input")
    rm -f "$WEBROOT/$filename"

    wget "$input" -O "$WEBROOT/$filename"
    if [ $? -eq 0 ]; then
        chown root:root "$WEBROOT/$filename"
        chmod +r "$WEBROOT/$filename"
        ip=$(hostname -I | awk '{print $1}')

        echo -e '\n\033[1;35mDownload completed!\033[0m'
        echo -e '\n\033[1;36mDownload links:\033[0m'
        echo -e "\033[1;36mhttps://$(hostname)/$filename\033[0m"
        echo -e "\033[1;36mhttp://$ip/$filename\033[0m"
    else
        rm -f "$WEBROOT/$filename"
        echo -e '\033[1;31mDownload failed, file removed.\033[0m'
    fi

# اگر ورودی یک فایل باشد
elif [ -f "$input" ]; then
    filename=$(basename "$input")
    cp "$input" "$WEBROOT/"

    chmod +r "$WEBROOT/$filename"
    chown root:root "$WEBROOT/$filename"

    hn=$(hostname)
    ip=$(hostname -I | awk '{print $1}')

    echo -e '\033[32mSuccess.\033[0m'
    echo -e '\n\033[33mDownload links:\033[0m'
    echo -e "\033[36mhttps://$hn/$filename\033[0m"
    echo -e "\033[36mhttp://$ip/$filename\033[0m"

# اگر ورودی یک دایرکتوری باشد
elif [ -d "$input" ]; then
    dirname=$(basename "$input")

    echo -e "\033[33mDetected directory: $dirname\033[0m"

    if [[ -n "$COMPRESS" ]]; then
        comp_type="$COMPRESS"
    else
        echo "Choose compression type:"
        echo "1) tar.gz"
        echo "2) zip"
        read -p "Enter option (1 or 2): " opt
        case "$opt" in
            1) comp_type="tar.gz" ;;
            2) comp_type="zip" ;;
            *) echo -e '\033[31mInvalid option.\033[0m'; exit 1 ;;
        esac
    fi

    if [ "$comp_type" == "tar.gz" ]; then
        outname="${dirname}.tar.gz"
        tar -czf "/tmp/$outname" -C "$(dirname "$input")" "$dirname"
    elif [ "$comp_type" == "zip" ]; then
        outname="${dirname}.zip"
        zip -r "/tmp/$outname" "$input" >/dev/null
    else
        echo -e '\033[31mInvalid compression type (use tar.gz or zip).\033[0m'
        exit 1
    fi

    # انتقال به وب‌روت
    mv "/tmp/$outname" "$WEBROOT/"
    chown root:root "$WEBROOT/$outname"
    chmod +r "$WEBROOT/$outname"

    hn=$(hostname)
    ip=$(hostname -I | awk '{print $1}')

    echo -e '\033[32mDirectory compressed and uploaded.\033[0m'
    echo -e '\n\033[33mDownload links:\033[0m'
    echo -e "\033[36mhttps://$hn/$outname\033[0m"
    echo -e "\033[36mhttp://$ip/$outname\033[0m"

else
    echo -e '\033[31mError: Not a valid URL, file path, or directory.\033[0m'
fi

set -H
