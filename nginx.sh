#!/usr/bin/env bash

set -u

PROGRAM_NAME="Orama-Advisors Nginx Manager"
FOOTER="Designed and Development : antonios.mortos@outlook.com"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
BACKUP_ROOT="/var/backups/orama-nginx-manager"
SNAPSHOT_ROOT="$BACKUP_ROOT/snapshots"
TMP_ROOT="/tmp/orama-nginx-manager"
DEFAULT_BACKEND="10.11.103.100"

mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" "$SNAPSHOT_ROOT" "$TMP_ROOT"

cleanup() {
    rm -f "$TMP_ROOT"/* 2>/dev/null || true
}
trap cleanup EXIT

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo $0"
    echo
    echo "$FOOTER"
    exit 1
fi

install_dependencies() {
    local packages=()
    command -v dialog >/dev/null 2>&1 || packages+=(dialog)
    command -v nginx >/dev/null 2>&1 || packages+=(nginx)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v ss >/dev/null 2>&1 || packages+=(iproute2)

    if [ ${#packages[@]} -gt 0 ]; then
        apt-get update || exit 1
        apt-get install -y "${packages[@]}" || exit 1
    fi
}

ensure_certbot() {
    if command -v certbot >/dev/null 2>&1; then
        return 0
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Certbot Required" \
        --yesno "Certbot is not installed.\n\nInstall it now?" 10 60
    [ $? -eq 0 ] || return 1

    apt-get update || return 1
    apt-get install -y certbot python3-certbot-nginx || return 1
    return 0
}

valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

nginx_service_status() {
    if systemctl is-active --quiet nginx; then
        echo "ACTIVE"
    else
        echo "INACTIVE"
    fi
}

nginx_domain_map() {
    nginx -T 2>/dev/null | awk '
        /^# configuration file / {
            file=$0
            sub(/^# configuration file /, "", file)
            sub(/:$/, "", file)
            next
        }
        /^[[:space:]]*server_name[[:space:]]+/ {
            for (i=2; i<=NF; i++) {
                domain=$i
                gsub(/;/, "", domain)
                domain=tolower(domain)
                if (domain == "" || domain == "_" || domain ~ /^\*/ || domain ~ /^~/)
                    continue
                if (domain ~ /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/)
                    print file "\t" domain
            }
        }
    ' | awk '!seen[$0]++'
}

active_site_files() {
    nginx_domain_map | cut -f1 | sort -u
}

domains_for_file() {
    local wanted="$1"
    nginx_domain_map | awk -F '\t' -v wanted="$wanted" '$1 == wanted && !seen[$2]++ { print $2 }'
}

primary_domain_for_file() {
    local file="$1"
    domains_for_file "$file" | head -1
}

aliases_for_file() {
    local file="$1"
    local primary
    primary=$(primary_domain_for_file "$file")
    domains_for_file "$file" | grep -vxF "$primary" || true
}

domain_count() {
    nginx_domain_map | cut -f2 | sort -u | sed '/^$/d' | wc -l
}

site_count() {
    active_site_files | sed '/^$/d' | wc -l
}

config_for_domain() {
    local domain="$1"
    nginx_domain_map | awk -F '\t' -v wanted="$domain" 'tolower($2) == tolower(wanted) { print $1; exit }'
}

ssl_port_for_file() {
    local file="$1"
    local port

    [ -f "$file" ] || { echo "?"; return; }

    port=$(awk '
        /^[[:space:]]*listen[[:space:]]+/ && /ssl/ {
            for (i=2; i<=NF; i++) {
                value=$i
                gsub(/;/, "", value)
                if (value ~ /^[0-9]+$/) {
                    print value
                    exit
                }
                if (value ~ /:[0-9]+$/) {
                    sub(/^.*:/, "", value)
                    print value
                    exit
                }
            }
        }
    ' "$file")

    if [ -n "$port" ]; then
        echo "$port"
    else
        echo "HTTP"
    fi
}

ssl_certificate_for_file() {
    local file="$1"
    [ -f "$file" ] || return
    awk '/^[[:space:]]*ssl_certificate[[:space:]]+/ { cert=$2; gsub(/;/, "", cert); print cert; exit }' "$file"
}

certbot_name_for_file() {
    local file="$1"
    local cert
    cert=$(ssl_certificate_for_file "$file")
    if [[ "$cert" =~ ^/etc/letsencrypt/live/([^/]+)/fullchain\.pem$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

domain_exists() {
    local domain="$1"
    nginx_domain_map | awk -F '\t' -v wanted="$domain" 'tolower($2) == tolower(wanted) { found=1 } END { exit(found ? 0 : 1) }'
}

check_public_port() {
    local port="$1"
    local listeners non_nginx output

    listeners=$(ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { print }')

    if [ -z "$listeners" ]; then
        return 0
    fi

    non_nginx=$(printf '%s\n' "$listeners" | grep -vi 'nginx' || true)

    if [ -n "$non_nginx" ]; then
        output="$TMP_ROOT/port-conflict.txt"
        {
            echo "PORT CONFLICT"
            echo
            echo "TCP port: $port"
            echo
            echo "This port is already used by another service:"
            echo
            echo "$listeners"
            echo
            echo "Domain creation has been cancelled."
        } > "$output"
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Port Conflict - TCP $port" --textbox "$output" 20 100
        return 1
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Port Check - TCP $port" \
        --msgbox "TCP $port is already used by Nginx.\n\nThis is safe. Nginx can host multiple domains on the same HTTPS port using SNI/server_name." 12 75
    return 0
}

safe_name() {
    echo "$1" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-'
}

create_snapshot_for_path() {
    local label="$1" active_path="$2" reason="$3"
    local stamp safe_label snapshot real_path is_symlink=0 n=1

    stamp=$(date +"%Y%m%d-%H%M%S")
    safe_label=$(safe_name "$label")
    snapshot="$SNAPSHOT_ROOT/${stamp}_${safe_label}_${reason}"

    while [ -e "$snapshot" ]; do
        snapshot="$SNAPSHOT_ROOT/${stamp}_${safe_label}_${reason}_$n"
        n=$((n + 1))
    done

    mkdir -p "$snapshot"

    if [ -e "$active_path" ] || [ -L "$active_path" ]; then
        if [ -L "$active_path" ]; then
            is_symlink=1
            real_path=$(readlink -f "$active_path")
        else
            real_path="$active_path"
        fi

        cp -a "$real_path" "$snapshot/config"

        {
            echo "EXISTS=1"
            echo "LABEL=$label"
            echo "REASON=$reason"
            echo "DATE=$(date -Is)"
            echo "ACTIVE_PATH=$active_path"
            echo "REAL_PATH=$real_path"
            echo "IS_SYMLINK=$is_symlink"
        } > "$snapshot/meta"
    else
        {
            echo "EXISTS=0"
            echo "LABEL=$label"
            echo "REASON=$reason"
            echo "DATE=$(date -Is)"
            echo "ACTIVE_PATH=$active_path"
            echo "REAL_PATH=$active_path"
            echo "IS_SYMLINK=0"
        } > "$snapshot/meta"
    fi

    LAST_SNAPSHOT="$snapshot"
}

create_absent_snapshot() {
    local label="$1" active_path="$2" real_path="$3" reason="$4"
    local stamp safe_label snapshot n=1

    stamp=$(date +"%Y%m%d-%H%M%S")
    safe_label=$(safe_name "$label")
    snapshot="$SNAPSHOT_ROOT/${stamp}_${safe_label}_${reason}"

    while [ -e "$snapshot" ]; do
        snapshot="$SNAPSHOT_ROOT/${stamp}_${safe_label}_${reason}_$n"
        n=$((n + 1))
    done

    mkdir -p "$snapshot"
    {
        echo "EXISTS=0"
        echo "LABEL=$label"
        echo "REASON=$reason"
        echo "DATE=$(date -Is)"
        echo "ACTIVE_PATH=$active_path"
        echo "REAL_PATH=$real_path"
        echo "IS_SYMLINK=1"
    } > "$snapshot/meta"

    LAST_SNAPSHOT="$snapshot"
}

meta_value() {
    local meta="$1" key="$2"
    grep "^${key}=" "$meta" | head -1 | cut -d= -f2-
}

restore_snapshot() {
    local snapshot="$1"
    local meta="$snapshot/meta"
    local exists active_path real_path is_symlink

    [ -f "$meta" ] || return 1

    exists=$(meta_value "$meta" "EXISTS")
    active_path=$(meta_value "$meta" "ACTIVE_PATH")
    real_path=$(meta_value "$meta" "REAL_PATH")
    is_symlink=$(meta_value "$meta" "IS_SYMLINK")

    if [ "$exists" = "0" ]; then
        [ -n "$active_path" ] && rm -f "$active_path"
        if [ -n "$real_path" ] && [ "$real_path" != "$active_path" ]; then
            rm -f "$real_path"
        fi
        return 0
    fi

    [ -f "$snapshot/config" ] || return 1

    if [ "$is_symlink" = "1" ]; then
        mkdir -p "$(dirname "$real_path")" "$(dirname "$active_path")"
        cp -a "$snapshot/config" "$real_path"
        rm -f "$active_path"
        ln -s "$real_path" "$active_path"
    else
        mkdir -p "$(dirname "$active_path")"
        cp -a "$snapshot/config" "$active_path"
    fi

    return 0
}

select_site() {
    local files=() file primary port alias_count tag choice index=1
    local menu=()

    while IFS= read -r file; do
        [ -n "$file" ] && files+=("$file")
    done < <(active_site_files)

    if [ ${#files[@]} -eq 0 ]; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Sites" --msgbox "No active Nginx sites were found." 8 50
        return 1
    fi

    declare -gA SELECT_SITE_MAP
    SELECT_SITE_MAP=()

    for file in "${files[@]}"; do
        primary=$(primary_domain_for_file "$file")
        port=$(ssl_port_for_file "$file")
        alias_count=$(aliases_for_file "$file" | sed '/^$/d' | wc -l)
        tag=$(printf 'SITE%03d' "$index")
        SELECT_SITE_MAP["$tag"]="$file"

        if [ "$alias_count" -gt 0 ]; then
            menu+=("$tag" "$primary  [HTTPS:$port]  +$alias_count alias(es)")
        else
            menu+=("$tag" "$primary  [HTTPS:$port]")
        fi
        index=$((index + 1))
    done

    choice=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Select Nginx Site" --cancel-label "Back" \
        --menu "Use UP/DOWN and ENTER:" 28 100 18 "${menu[@]}")
    [ $? -eq 0 ] || return 1

    echo "${SELECT_SITE_MAP[$choice]}"
}

show_site_details() {
    local file="$1" primary aliases port cert real_path output
    [ -f "$file" ] || return

    primary=$(primary_domain_for_file "$file")
    aliases=$(aliases_for_file "$file")
    port=$(ssl_port_for_file "$file")
    cert=$(ssl_certificate_for_file "$file")

    if [ -L "$file" ]; then
        real_path=$(readlink -f "$file")
    else
        real_path="$file"
    fi

    output="$TMP_ROOT/site-details.txt"
    {
        echo "NGINX SITE DETAILS"
        echo
        echo "Primary domain: $primary"
        echo "HTTPS port: $port"
        echo "Active config: $file"
        echo "Real config:   $real_path"
        echo
        if [ -n "$aliases" ]; then
            echo "Aliases:"
            while IFS= read -r alias; do
                [ -n "$alias" ] && echo "  - $alias"
            done <<< "$aliases"
            echo
        fi
        echo "SSL certificate:"
        if [ -n "$cert" ]; then
            echo "  $cert"
        else
            echo "  No ssl_certificate directive found"
        fi
    } > "$output"

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "$primary" --textbox "$output" 24 110
}

create_domain() {
    local domain public_port backend backend_port protocol public_url
    local real_config active_config testlog certlog cert key redirect_line

    domain=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Create Domain - 1/5" \
        --inputbox "Enter the new domain.\n\nExample:\nnavigation.orama-advisors.gr" 11 70)
    [ $? -eq 0 ] || return

    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | xargs)

    if ! valid_domain "$domain"; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Invalid Domain" --msgbox "Invalid domain:\n\n$domain" 9 60
        return
    fi

    if domain_exists "$domain"; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Domain Already Exists" \
            --msgbox "The domain already exists.\n\nConfig:\n$(config_for_domain "$domain")" 12 85
        return
    fi

    public_port=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Create Domain - 2/5" \
        --inputbox "Public HTTPS port:\n\nDefault: 443" 10 60 "443")
    [ $? -eq 0 ] || return

    if ! valid_port "$public_port" || [ "$public_port" = "80" ]; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Invalid Port" --msgbox "Invalid HTTPS port." 8 45
        return
    fi

    check_public_port "$public_port" || return
    check_public_port 80 || return

    backend=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Create Domain - 3/5" \
        --inputbox "Backend IP or hostname:" 9 65 "$DEFAULT_BACKEND")
    [ $? -eq 0 ] || return
    backend=$(echo "$backend" | xargs)
    [ -n "$backend" ] || return

    backend_port=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Create Domain - 4/5" \
        --inputbox "Backend service port:\n\nExamples: 12000 / 22000 / 9090" 11 60)
    [ $? -eq 0 ] || return

    if ! valid_port "$backend_port"; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --msgbox "Invalid backend port." 8 45
        return
    fi

    protocol=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Create Domain - 5/5" \
        --radiolist "Select backend protocol:" 13 65 4 \
        "http" "HTTP backend" on \
        "https" "HTTPS backend" off)
    [ $? -eq 0 ] || return

    if [ "$public_port" = "443" ]; then
        public_url="https://$domain"
    else
        public_url="https://$domain:$public_port"
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Confirm New Domain" --yesno \
"Domain: $domain
Public URL: $public_url
Backend: $protocol://$backend:$backend_port
WebSocket: enabled
SSL: Let's Encrypt

Create this domain?" 18 80
    [ $? -eq 0 ] || return

    real_config="$SITES_AVAILABLE/$domain.conf"
    active_config="$SITES_ENABLED/$domain.conf"

    create_absent_snapshot "$domain" "$active_config" "$real_config" "before-create"

    cat > "$real_config" <<EOF2
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location / {
        proxy_pass $protocol://$backend:$backend_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
EOF2

    ln -sfn "$real_config" "$active_config"
    testlog="$TMP_ROOT/create-test.txt"

    if ! nginx -t > "$testlog" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Nginx Test Failed" --textbox "$testlog" 22 100
        return
    fi

    if ! systemctl reload nginx >> "$testlog" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Reload Failed" --textbox "$testlog" 22 100
        return
    fi

    ensure_certbot || {
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        return
    }

    certlog="$TMP_ROOT/certbot-create.txt"
    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "SSL Certificate" \
        --infobox "Requesting Let's Encrypt certificate...\n\n$domain\n\nPlease wait." 9 60

    if ! certbot certonly --nginx -d "$domain" --agree-tos --non-interactive --register-unsafely-without-email > "$certlog" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "SSL Certificate Failed" --textbox "$certlog" 24 105
        return
    fi

    cert="/etc/letsencrypt/live/$domain/fullchain.pem"
    key="/etc/letsencrypt/live/$domain/privkey.pem"

    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "SSL Error" \
            --msgbox "Certificate files were not found.\n\nThe Nginx configuration was rolled back." 10 70
        return
    fi

    if [ "$public_port" = "443" ]; then
        redirect_line='return 301 https://$host$request_uri;'
    else
        redirect_line="return 301 https://\$host:$public_port\$request_uri;"
    fi

    cat > "$real_config" <<EOF2
# Managed by Orama-Advisors Nginx Manager
# Domain: $domain
# Backend: $protocol://$backend:$backend_port
# Public HTTPS Port: $public_port

server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    $redirect_line
}

server {
    listen $public_port ssl;
    listen [::]:$public_port ssl;
    server_name $domain;

    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass $protocol://$backend:$backend_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port $public_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
EOF2

    if [ "$protocol" = "https" ]; then
        cat >> "$real_config" <<'EOF2'
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
EOF2
    fi

    cat >> "$real_config" <<'EOF2'
    }
}
EOF2

    if ! nginx -t > "$testlog" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Final Nginx Test Failed" --textbox "$testlog" 22 100
        return
    fi

    if ! systemctl reload nginx >> "$testlog" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Final Reload Failed" --textbox "$testlog" 22 100
        return
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Domain Created" --msgbox \
"Domain created successfully.

URL: $public_url
Backend: $protocol://$backend:$backend_port
SSL: ACTIVE
Config: $real_config
Backup: $LAST_SNAPSHOT" 18 90
}

delete_site() {
    local file primary aliases real_path alias_text="" log cert_name

    file=$(select_site) || return
    primary=$(primary_domain_for_file "$file")
    aliases=$(aliases_for_file "$file")

    if [ -L "$file" ]; then
        real_path=$(readlink -f "$file")
    else
        real_path="$file"
    fi

    case "$file" in
        /etc/nginx/sites-enabled/*|/etc/nginx/conf.d/*) ;;
        *)
            dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Protected Configuration" \
                --msgbox "For safety, this manager will not delete:\n\n$file" 10 90
            return
            ;;
    esac

    if [ -n "$aliases" ]; then
        while IFS= read -r alias; do
            [ -n "$alias" ] && alias_text+="\n  - $alias"
        done <<< "$aliases"
    else
        alias_text="\n  None"
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Delete Nginx Site" --yesno \
"Primary domain:
  $primary

Aliases:$alias_text

Active config:
  $file

Real config:
  $real_path

A rollback snapshot will be created first.

Continue?" 24 95
    [ $? -eq 0 ] || return

    create_snapshot_for_path "$primary" "$file" "before-delete"

    rm -f "$file"
    if [ "$real_path" != "$file" ] && [[ "$real_path" == /etc/nginx/sites-available/* ]]; then
        rm -f "$real_path"
    fi

    log="$TMP_ROOT/delete.txt"

    if ! nginx -t > "$log" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Delete Failed" --textbox "$log" 22 100
        return
    fi

    if ! systemctl reload nginx >> "$log" 2>&1; then
        restore_snapshot "$LAST_SNAPSHOT"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Delete Failed" \
            --msgbox "Nginx reload failed. Automatic rollback completed." 10 60
        return
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Delete Certificate?" --yesno \
"The Nginx site was removed.

Delete its Certbot certificate too?

Certificate deletion is separate from Nginx rollback." 13 75

    if [ $? -eq 0 ]; then
        cert_name=$(certbot_name_for_file "$LAST_SNAPSHOT/config" 2>/dev/null || true)
        if [ -n "$cert_name" ]; then
            ensure_certbot && certbot delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1 || true
        fi
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Site Deleted" \
        --msgbox "Site removed:\n\n$primary\n\nRollback snapshot:\n$LAST_SNAPSHOT" 12 80
}

check_ssl() {
    local file primary port cert output expiry expiry_epoch now_epoch remaining

    file=$(select_site) || return
    primary=$(primary_domain_for_file "$file")
    port=$(ssl_port_for_file "$file")
    cert=$(ssl_certificate_for_file "$file")
    output="$TMP_ROOT/check-ssl.txt"

    {
        echo "SSL CERTIFICATE CHECK"
        echo
        echo "Site: $primary"
        echo "HTTPS Port: $port"
        echo "Config: $file"
        echo

        if [ -z "$cert" ]; then
            echo "STATUS: NO SSL CERTIFICATE CONFIGURED"
        elif [ ! -f "$cert" ]; then
            echo "Certificate path: $cert"
            echo "STATUS: CERTIFICATE FILE NOT FOUND"
        else
            echo "Certificate: $cert"
            echo
            openssl x509 -in "$cert" -noout -subject -issuer -serial -startdate -enddate -fingerprint -sha256
            echo

            expiry=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2-)
            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)

            if [ "$expiry_epoch" -gt 0 ]; then
                remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
                echo "Days remaining: $remaining"
                echo

                if [ "$remaining" -lt 0 ]; then
                    echo "STATUS: EXPIRED"
                elif [ "$remaining" -lt 15 ]; then
                    echo "STATUS: WARNING - EXPIRING VERY SOON"
                elif [ "$remaining" -lt 30 ]; then
                    echo "STATUS: RENEWAL RECOMMENDED"
                else
                    echo "STATUS: VALID"
                fi
            fi
        fi
    } > "$output"

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "SSL Check - $primary" --textbox "$output" 28 105
}

renew_ssl() {
    local file primary cert_name log

    file=$(select_site) || return
    primary=$(primary_domain_for_file "$file")
    cert_name=$(certbot_name_for_file "$file" 2>/dev/null || true)

    if [ -z "$cert_name" ]; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Renew SSL" \
            --msgbox "This site does not appear to use a Certbot-managed certificate.\n\nSite: $primary" 11 75
        return
    fi

    ensure_certbot || return

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Renew SSL" --yesno \
        "Force renewal for:\n\n$primary\n\nCertbot name: $cert_name" 12 70
    [ $? -eq 0 ] || return

    log="$TMP_ROOT/renew-ssl.txt"

    if certbot renew --cert-name "$cert_name" --force-renewal > "$log" 2>&1; then
        if nginx -t >> "$log" 2>&1; then
            systemctl reload nginx >> "$log" 2>&1 || true
        fi
        echo >> "$log"
        echo "SSL RENEWAL COMPLETED." >> "$log"
    else
        echo >> "$log"
        echo "SSL RENEWAL FAILED." >> "$log"
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "SSL Renewal - $primary" --textbox "$log" 26 105
}

test_nginx() {
    local log="$TMP_ROOT/nginx-test.txt" rc
    nginx -t > "$log" 2>&1
    rc=$?
    echo >> "$log"
    if [ "$rc" -eq 0 ]; then
        echo "STATUS: NGINX CONFIGURATION OK" >> "$log"
    else
        echo "STATUS: NGINX CONFIGURATION ERROR" >> "$log"
    fi
    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Test Nginx" --textbox "$log" 22 105
}

reload_nginx() {
    local log="$TMP_ROOT/nginx-reload.txt"

    if ! nginx -t > "$log" 2>&1; then
        echo >> "$log"
        echo "Reload cancelled because nginx -t failed." >> "$log"
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Reload Cancelled" --textbox "$log" 22 105
        return
    fi

    if systemctl reload nginx >> "$log" 2>&1; then
        echo >> "$log"
        echo "NGINX RELOADED SUCCESSFULLY." >> "$log"
    else
        echo >> "$log"
        echo "NGINX RELOAD FAILED." >> "$log"
    fi

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Reload Nginx" --textbox "$log" 22 105
}

rollback_manager() {
    local snapshots=() snapshot meta label reason date active_path real_path choice pre_rollback log
    local menu=() tag index=1

    while IFS= read -r snapshot; do
        [ -d "$snapshot" ] && snapshots+=("$snapshot")
    done < <(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [ ${#snapshots[@]} -eq 0 ]; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Rollback" --msgbox "No rollback snapshots are available." 8 55
        return
    fi

    declare -A ROLLBACK_MAP

    for snapshot in "${snapshots[@]}"; do
        meta="$snapshot/meta"
        [ -f "$meta" ] || continue
        label=$(meta_value "$meta" "LABEL")
        reason=$(meta_value "$meta" "REASON")
        date=$(meta_value "$meta" "DATE")
        tag=$(printf 'RB%03d' "$index")
        ROLLBACK_MAP["$tag"]="$snapshot"
        menu+=("$tag" "$label | $reason | $date")
        index=$((index + 1))
    done

    choice=$(dialog --hline "$FOOTER" --stdout --backtitle "$PROGRAM_NAME" --title "Rollback Snapshot" --cancel-label "Back" \
        --menu "Select snapshot:" 30 115 20 "${menu[@]}")
    [ $? -eq 0 ] || return

    snapshot="${ROLLBACK_MAP[$choice]}"
    meta="$snapshot/meta"
    label=$(meta_value "$meta" "LABEL")
    reason=$(meta_value "$meta" "REASON")
    date=$(meta_value "$meta" "DATE")
    active_path=$(meta_value "$meta" "ACTIVE_PATH")
    real_path=$(meta_value "$meta" "REAL_PATH")

    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Confirm Rollback" --yesno \
"Site: $label
Snapshot: $date
Reason: $reason
Active path: $active_path

A backup of the current state will be created first.

Continue?" 18 90
    [ $? -eq 0 ] || return

    if [ -e "$active_path" ] || [ -L "$active_path" ]; then
        create_snapshot_for_path "$label" "$active_path" "before-rollback"
    else
        create_absent_snapshot "$label" "$active_path" "$real_path" "before-rollback"
    fi
    pre_rollback="$LAST_SNAPSHOT"

    if ! restore_snapshot "$snapshot"; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Rollback Error" \
            --msgbox "Unable to restore the selected snapshot." 9 60
        return
    fi

    log="$TMP_ROOT/rollback.txt"
    if nginx -t > "$log" 2>&1 && systemctl reload nginx >> "$log" 2>&1; then
        dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Rollback Successful" \
            --msgbox "Rollback successful.\n\nSite: $label\nSnapshot: $date" 12 80
        return
    fi

    restore_snapshot "$pre_rollback"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx

    echo >> "$log"
    echo "ROLLBACK FAILED. Previous state restored." >> "$log"
    dialog --hline "$FOOTER" --backtitle "$PROGRAM_NAME" --title "Rollback Failed" --textbox "$log" 24 105
}

main_header() {
    printf 'NGINX STATUS: %s\n' "$(nginx_service_status)"
    printf 'NGINX SITES : %s\n' "$(site_count)"
    printf 'HOSTNAMES   : %s\n' "$(domain_count)"
    printf '\nUse UP/DOWN arrows and ENTER.\n'
}

while true; do
    declare -A MAIN_SITE_MAP
    MAIN_SITE_MAP=()

    menu_items=(
        "CREATE"   "Create Domain"
        "DELETE"   "Delete Domain / Site"
        "CHECKSSL" "Check SSL"
        "RENEWSSL" "Renew SSL"
        "TEST"     "Test Nginx Configuration"
        "RELOAD"   "Reload Nginx"
        "ROLLBACK" "Rollback"
        "REFRESH"  "Refresh Domain List"
    )

    index=1
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        primary=$(primary_domain_for_file "$file")
        port=$(ssl_port_for_file "$file")
        alias_count=$(aliases_for_file "$file" | sed '/^$/d' | wc -l)
        tag=$(printf 'DOMAIN%03d' "$index")
        MAIN_SITE_MAP["$tag"]="$file"

        if [ "$alias_count" -gt 0 ]; then
            menu_items+=("$tag" "$primary  [HTTPS:$port]  +$alias_count alias(es)")
        else
            menu_items+=("$tag" "$primary  [HTTPS:$port]")
        fi
        index=$((index + 1))
    done < <(active_site_files)

    choice=$(dialog --hline "$FOOTER" --stdout --clear --backtitle "Orama-Advisors Infrastructure" \
        --title "NGINX DOMAIN MANAGER" --cancel-label "Exit" \
        --menu "$(main_header)" 36 115 24 "${menu_items[@]}")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        clear
        exit 0
    fi

    case "$choice" in
        CREATE) create_domain ;;
        DELETE) delete_site ;;
        CHECKSSL) check_ssl ;;
        RENEWSSL) renew_ssl ;;
        TEST) test_nginx ;;
        RELOAD) reload_nginx ;;
        ROLLBACK) rollback_manager ;;
        REFRESH) ;;
        DOMAIN*)
            if [ -n "${MAIN_SITE_MAP[$choice]:-}" ]; then
                show_site_details "${MAIN_SITE_MAP[$choice]}"
            fi
            ;;
    esac
done