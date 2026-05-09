#!/usr/bin/env bash

# =========================================================
# NGINX + 3XUI (XRay) MANAGER
# =========================================================
#
# FEATURES:
#   - Auto install nginx/certbot
#   - Relay mode
#   - Backend mode
#   - gRPC
#   - WebSocket
#   - SplitHTTP (XHTTP)
#   - Fake website (probe resistance)
#   - Route constructor
#   - Safe route includes
#   - No sed insertion bugs
#   - No standalone certbot port 80 bug
#
# TESTED:
#   Ubuntu 22+
#   Debian 12+
#
# =========================================================

set -e

NGINX_DIR="/etc/nginx"
CONF_DIR="/etc/nginx/conf.d"
ROUTES_DIR="/etc/nginx/routes"

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

# =========================================================
# INSTALL
# =========================================================

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
    systemctl restart nginx

    ok "Packages installed"
}

# =========================================================
# FAKE SITE
# =========================================================

function create_fake_site() {

    mkdir -p "$WWW_DIR"

    cat > "$WWW_DIR/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
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
<p>Server is running.</p>

</body>
</html>
EOF

    ok "Fake website created"
}

# =========================================================
# ASK DOMAIN
# =========================================================

function ask_domain() {

    echo

    read -rp "$(echo -e ${CYAN}Введите домен:${NC} )" DOMAIN
}

# =========================================================
# CREATE TEMP HTTP CONFIG
# Needed for certbot --nginx
# =========================================================

function create_temp_http_config() {

    cat > "$CONF_DIR/$DOMAIN-temp.conf" <<EOF
server {

    listen 80;
    server_name $DOMAIN;

    root $WWW_DIR;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    nginx -t
    systemctl reload nginx

    ok "Temporary HTTP config created"
}

# =========================================================
# SSL
# =========================================================

function ssl_menu() {

    echo
    echo "1) Generate Let's Encrypt certificate"
    echo "2) Use existing certificate"

    read -rp "Select: " SSL_MODE

    if [[ "$SSL_MODE" == "1" ]]; then

        create_temp_http_config

        certbot --nginx \
            -d "$DOMAIN" \
            --redirect \
            --non-interactive \
            --agree-tos \
            -m admin@"$DOMAIN"

        CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

        rm -f "$CONF_DIR/$DOMAIN-temp.conf"

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

# =========================================================
# MODE MENU
# =========================================================

function mode_menu() {

    echo
    echo -e "${GREEN}Режим работы:${NC}"
    echo

    echo -e "${WHITE}1) Relay (Проксирующий сервер)${NC}"
    echo -e "${WHITE}2) Backend (Сервер с 3XUI)${NC}"

    echo

    read -rp "$(echo -e ${CYAN}Выберите режим:${NC} )" MODE
}

# =========================================================
# TRANSPORT MENU
# =========================================================

function transport_menu() {

    echo
    echo "1) gRPC"
    echo "2) WebSocket"
    echo "3) SplitHTTP (XHTTP)"

    read -rp "Select: " TRANSPORT

    read -rp "Route path (example /grpc): " PATH_NAME

    ROUTE_NAME=$(echo "$PATH_NAME" | tr -d '/')

    if [[ "$MODE" == "1" ]]; then
        read -rp "Backend domain/IP: " BACKEND
    else
        read -rp "Local Xray port: " LOCAL_PORT
    fi
}

# =========================================================
# MAIN NGINX CONFIG
# =========================================================

function create_main_nginx_config() {

    mkdir -p "$ROUTES_DIR/$DOMAIN"

    cat > "$CONF_DIR/$DOMAIN.conf" <<EOF
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

    include $ROUTES_DIR/$DOMAIN/*.conf;
}
EOF

    nginx -t
    systemctl reload nginx

    ok "Main nginx config created"
}

# =========================================================
# GENERATE ROUTE
# =========================================================

function create_grpc_route() {

    if [[ "$MODE" == "1" ]]; then

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
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

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
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

# =========================================================
# WS
# =========================================================

function create_ws_route() {

    if [[ "$MODE" == "1" ]]; then

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
location $PATH_NAME {

    proxy_redirect off;

    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host $BACKEND;

    proxy_pass https://$BACKEND;

    proxy_ssl_server_name on;
    proxy_ssl_name $BACKEND;
}
EOF

    else

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
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

# =========================================================
# XHTTP
# =========================================================

function create_xhttp_route() {

    if [[ "$MODE" == "1" ]]; then

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
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

cat > "$ROUTES_DIR/$DOMAIN/$ROUTE_NAME.conf" <<EOF
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

# =========================================================
# CREATE ROUTE
# =========================================================

function create_route() {

    case "$TRANSPORT" in

        1)
            create_grpc_route
            ;;

        2)
            create_ws_route
            ;;

        3)
            create_xhttp_route
            ;;

        *)
            err "Invalid transport"
            exit 1
            ;;
    esac

    nginx -t
    systemctl reload nginx

    ok "Route added"
}

# =========================================================
# ADD ROUTE
# =========================================================

function add_route() {

    ask_domain

    if [[ ! -f "$CONF_DIR/$DOMAIN.conf" ]]; then
        err "Domain config not found"
        exit 1
    fi

    mode_menu
    transport_menu

    create_route
}

# =========================================================
# FULL INSTALL
# =========================================================

function full_install() {

    install_packages

    mkdir -p "$ROUTES_DIR"

    create_fake_site

    ask_domain

    ssl_menu

    create_main_nginx_config

    mode_menu

    transport_menu

    create_route

    ok "Installation completed"
}

# =========================================================
# COLORS
# =========================================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
BOLD="\e[1m"
NC="\e[0m"

# =========================================================
# MENU
# =========================================================

function menu() {

    clear

    echo -e "${GREEN}${BOLD}"
    echo "==========================================="
    echo "         NGINX + 3XUI MANAGER"
    echo "==========================================="
    echo -e "${NC}"

    echo -e "${WHITE}1) Полная установка${NC}"
    echo -e "${WHITE}2) Добавить маршрут${NC}"
    echo -e "${WHITE}3) Выход${NC}"

    echo

    read -rp "$(echo -e ${CYAN}Выберите пункт:${NC} )" ACTION

    case "$ACTION" in

        1)
            full_install
            ;;

        2)
            add_route
            ;;

        3)
            exit 0
            ;;

        *)
            err "Неверный пункт"
            ;;
    esac
}
require_root
menu
