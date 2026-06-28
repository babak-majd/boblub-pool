#!/bin/bash
set +H

WEBROOT="/var/www/html"

read -p $'\033[36mEnter file path, directory, or URL:\033[0m ' input

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
    echo "Choose compression type:"
    echo "1) tar.gz"
    echo "2) zip"

    read -p "Enter option (1 or 2): " opt

    if [ "$opt" == "1" ]; then
        outname="${dirname}.tar.gz"
        tar -czf "/tmp/$outname" -C "$(dirname "$input")" "$dirname"
    elif [ "$opt" == "2" ]; then
        outname="${dirname}.zip"
        zip -r "/tmp/$outname" "$input" >/dev/null
    else
        echo -e '\033[31mInvalid option.\033[0m'
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
