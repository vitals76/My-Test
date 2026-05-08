#!/usr/bin/env bash

# =========================================================
# NGINX + 3XUI (XRay) AUTO CONFIGURATOR
# Relay / Backend mode
# Supports:
#   - gRPC
#   - WebSocket
#   - SplitHTTP (XHTTP)
#   - Let's Encrypt
#   - Existing SSL certs
#   - Probe resistance fake site
#
# Tested:
#   Ubuntu 22.04+
#   Debian 12+
# =========================================================

set -e

NGINX_DIR="/etc/nginx"
SITES_DIR="$NGINX_DIR/conf.d"
WWW_DIR="/var/www/fakesite"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

function ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

function warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Run as root"
        exit 1
    fi
}

function install_packages() {
    apt update

    apt install -y \
        nginx \
        certbot \
        python3-certbot-nginx \
        curl \
        socat \
        cron

    systemctl enable nginx
    systemctl start nginx

    ok "Packages installed"
}

function create_fake_site() {
    mkdir -p "$WWW_DIR"

    cat > "$WWW_DIR/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<title>Welcome</title>
<style>
body {
    background:#f5f5f5;
    font-family:Arial;
    margin-top:100px;
    text-align:center;
}
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>Server is working.</p>
</body>
</html>
EOF

    ok "Fake site created"
}

function ask_domain() {
    read -rp "Domain: " DOMAIN
}

function ssl_menu() {
    echo
    echo "1) Generate Let's Encrypt certificate"
    echo "2) Use existing certificate"

    read -rp "Select: " SSL_MODE

    if [[ "$SSL_MODE" == "1" ]]; then

        certbot --nginx \
            -d "$DOMAIN" \
            --non-interactive \
            --agree-tos \
            -m admin@"$DOMAIN"

        CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    else

        CERT="/root/cert/$DOMAIN/fullchain.pem"
        KEY="/root/cert/$DOMAIN/privkey.pem"

        if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
            err "Certificate files not found"
            exit 1
        fi
    fi

    ok "SSL configured"
}

function mode_menu() {
    echo
    echo "1) Relay mode"
    echo "2) Backend mode"

    read -rp "Select: " MODE
}

function transport_menu() {

    echo
    echo "Transport:"
    echo "1) gRPC"
    echo "2) WebSocket"
    echo "3) SplitHTTP (XHTTP)"

    read -rp "Select: " TRANSPORT

    read -rp "Route path (example /grpc): " PATH_NAME

    if [[ "$MODE" == "1" ]]; then
        read -rp "Backend domain/IP: " BACKEND
    fi

    if [[ "$MODE" == "2" ]]; then
        read -rp "Local Xray port: " LOCAL_PORT
    fi
}

function build_grpc_location() {

if [[ "$MODE" == "1" ]]; then

cat <<EOF
location $PATH_NAME {

    if (\$content_type !~ "application/grpc") {
        return 404;
    }

    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;

    grpc_pass grpcs://$BACKEND:443;

    grpc_ssl_server_name on;
    grpc_ssl_name $BACKEND;
}
EOF

else

cat <<EOF
location $PATH_NAME {

    if (\$content_type !~ "application/grpc") {
        return 404;
    }

    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;

    grpc_pass grpc://127.0.0.1:$LOCAL_PORT;
}
EOF

fi
}

function build_ws_location() {

if [[ "$MODE" == "1" ]]; then

cat <<EOF
location $PATH_NAME {

    proxy_redirect off;
    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host $BACKEND;

    proxy_pass https://$BACKEND;
}
EOF

else

cat <<EOF
location $PATH_NAME {

    proxy_redirect off;
    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_pass http://127.0.0.1:$LOCAL_PORT;
}
EOF

fi
}

function build_xhttp_location() {

if [[ "$MODE" == "1" ]]; then

cat <<EOF
location $PATH_NAME {

    proxy_buffering off;
    proxy_request_buffering off;

    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_set_header Host $BACKEND;

    proxy_pass https://$BACKEND;

    proxy_ssl_server_name on;
    proxy_ssl_name $BACKEND;
}
EOF

else

cat <<EOF
location $PATH_NAME {

    proxy_buffering off;
    proxy_request_buffering off;

    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_pass http://127.0.0.1:$LOCAL_PORT;
}
EOF

fi
}

function generate_transport_block() {

    case "$TRANSPORT" in
        1)
            build_grpc_location
            ;;
        2)
            build_ws_location
            ;;
        3)
            build_xhttp_location
            ;;
        *)
            err "Invalid transport"
            exit 1
            ;;
    esac
}

function create_nginx_config() {

CONF="$SITES_DIR/$DOMAIN.conf"

TRANSPORT_BLOCK=$(generate_transport_block)

cat > "$CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}

server {

    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;

    ssl_protocols TLSv1.2 TLSv1.3;

    root $WWW_DIR;
    index index.html;

    client_max_body_size 0;

    location / {
        try_files \$uri \$uri/ =404;
    }

$TRANSPORT_BLOCK
}
EOF

    nginx -t

    systemctl restart nginx

    ok "Nginx config created"
}

function add_route() {

    ask_domain

    CONF="$SITES_DIR/$DOMAIN.conf"

    if [[ ! -f "$CONF" ]]; then
        err "Config not found"
        exit 1
    fi

    mode_menu
    transport_menu

    BLOCK=$(generate_transport_block)

    sed -i "/^}/i $BLOCK" "$CONF"

    nginx -t
    systemctl restart nginx

    ok "Route added"
}

function menu() {

    echo
    echo "========== 3XUI NGINX MANAGER =========="
    echo
    echo "1) Full install"
    echo "2) Add route"
    echo "3) Exit"
    echo

    read -rp "Select: " ACTION

    case "$ACTION" in

        1)
            install_packages
            create_fake_site
            ask_domain
            ssl_menu
            mode_menu
            transport_menu
            create_nginx_config
            ;;

        2)
            add_route
            ;;

        3)
            exit 0
            ;;

        *)
            err "Invalid option"
            ;;
    esac
}

require_root
menu
