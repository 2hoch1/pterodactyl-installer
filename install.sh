#!/usr/bin/env bash
# =============================================================================
# Pterodactyl Panel + Wings Installer (worker script)
# Called by setup.sh after interactive configuration.
# Reads: PANEL_DOMAIN, WINGS_DOMAIN, DB_PASSWORD, LE_EMAIL, TIMEZONE, INSTALL_WINGS
# =============================================================================

set -euo pipefail

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Helpers -----------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}>>> $* ${RESET}\n"; }

# --- Guard: ensure required env vars are set ---------------------------------
check_env() {
  local missing=()
  [[ -z "${PANEL_DOMAIN:-}" ]] && missing+=("PANEL_DOMAIN")
  [[ -z "${DB_PASSWORD:-}"  ]] && missing+=("DB_PASSWORD")
  [[ -z "${LE_EMAIL:-}"     ]] && missing+=("LE_EMAIL")
  [[ -z "${TIMEZONE:-}"     ]] && missing+=("TIMEZONE")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required variables: ${missing[*]}. Run setup.sh instead of calling this script directly."
  fi

  INSTALL_WINGS="${INSTALL_WINGS:-false}"
}

# =============================================================================
# PHASE 1: PANEL
# =============================================================================

install_base_deps() {
  section "Installing Base Dependencies"

  apt-get update -y
  apt-get install -y \
    curl wget gnupg lsb-release ca-certificates \
    tar unzip git sudo openssl

  success "Base packages installed."
}

install_php() {
  section "Adding PHP 8.3 (Sury repo)"

  mkdir -p /etc/apt/keyrings
  curl -sSL https://packages.sury.org/php/apt.gpg \
    | gpg --yes --dearmor -o /etc/apt/keyrings/sury-php.gpg

  echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] \
https://packages.sury.org/php/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/sury-php.list

  apt-get update -y
  apt-get install -y \
    php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip}

  success "PHP 8.3 installed."
}

install_redis() {
  section "Installing Redis"

  # Debian 13 ships Redis 7.x natively; no 3rd-party repo needed
  apt-get install -y redis-server

  systemctl enable --now redis-server
  success "Redis installed and started."
}

install_mariadb() {
  section "Installing MariaDB"

  apt-get install -y mariadb-server
  systemctl enable --now mariadb
  success "MariaDB installed and started."
}

install_nginx_certbot() {
  section "Installing NGINX and Certbot"

  apt-get install -y nginx certbot python3-certbot-nginx
  systemctl enable nginx
  success "NGINX and Certbot installed."
}

install_composer() {
  section "Installing Composer"

  if command -v composer &>/dev/null; then
    success "Composer already present, skipping."
    return
  fi

  curl -sS https://getcomposer.org/installer \
    | php -- --install-dir=/usr/local/bin --filename=composer

  success "Composer installed."
}

setup_database() {
  section "Setting Up Database"

  mariadb -u root <<SQL
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost'  IDENTIFIED BY '${DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS panel;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost'  WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  success "Database 'panel' and user 'pterodactyl' ready."
}

obtain_panel_ssl() {
  section "Obtaining SSL Certificate for Panel (${PANEL_DOMAIN})"

  systemctl stop nginx || true

  certbot certonly \
    --standalone \
    --agree-tos \
    --no-eff-email \
    -m "${LE_EMAIL}" \
    -d "${PANEL_DOMAIN}" \
    || error "Certbot failed for ${PANEL_DOMAIN}. Ensure port 80 is open and DNS points here."

  systemctl start nginx
  success "SSL certificate obtained for ${PANEL_DOMAIN}."
}

download_panel() {
  section "Downloading Pterodactyl Panel"

  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl

  info "Downloading latest release..."
  curl -Lo panel.tar.gz \
    https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/
  rm -f panel.tar.gz

  success "Panel files extracted to /var/www/pterodactyl"
}

install_panel_app() {
  section "Installing Panel Application"
  cd /var/www/pterodactyl

  cp .env.example .env

  info "Installing Composer dependencies..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  info "Generating application key..."
  php artisan key:generate --force

  info "Configuring application environment..."
  php artisan p:environment:setup \
    --author="${LE_EMAIL}" \
    --url="https://${PANEL_DOMAIN}" \
    --timezone="${TIMEZONE}" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --no-interaction

  php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database=panel \
    --username=pterodactyl \
    --password="${DB_PASSWORD}" \
    --no-interaction

  info "Running database migrations (this may take a moment)..."
  php artisan migrate --seed --force

  info "Setting file permissions..."
  chown -R www-data:www-data /var/www/pterodactyl

  success "Panel application configured."
}

configure_nginx_panel() {
  section "Configuring NGINX for Panel"

  rm -f /etc/nginx/sites-enabled/default

  cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${PANEL_DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate     /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    ssl_session_cache   shared:SSL:10m;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

  ln -sf /etc/nginx/sites-available/pterodactyl.conf \
         /etc/nginx/sites-enabled/pterodactyl.conf

  nginx -t || error "NGINX config test failed. Check /etc/nginx/sites-available/pterodactyl.conf"
  systemctl restart nginx
  success "NGINX configured for panel."
}

setup_queue_worker() {
  section "Setting Up Queue Worker and Scheduler"

  (crontab -l 2>/dev/null; \
   echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") \
    | sort -u | crontab -

  cat > /etc/systemd/system/pteroq.service <<SERVICE
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now pteroq.service
  success "Queue worker enabled."
}

create_admin_user() {
  section "Creating Admin User"
  echo "Follow the prompts to create your first panel administrator."
  echo ""
  cd /var/www/pterodactyl
  php artisan p:user:make
}

print_app_key_warning() {
  local app_key
  app_key=$(grep APP_KEY /var/www/pterodactyl/.env | cut -d= -f2-)

  echo ""
  echo -e "${RED}${BOLD}!!! IMPORTANT: Back up your APP_KEY now !!!${RESET}"
  echo ""
  echo "  APP_KEY=${BOLD}${app_key}${RESET}"
  echo ""
  echo "If this key is lost, all encrypted data (API keys, etc.) is permanently unrecoverable."
  echo "Store it in a password manager or encrypted file outside this server."
  echo ""
  read -rp "Press ENTER once you have saved the key to continue..."
}

# =============================================================================
# PHASE 2: WINGS
# =============================================================================

install_docker() {
  section "Installing Docker"

  if command -v docker &>/dev/null; then
    success "Docker already installed, skipping."
  else
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  fi

  systemctl enable --now docker
  success "Docker installed and started."
}

obtain_wings_ssl() {
  section "Obtaining SSL Certificate for Wings (${WINGS_DOMAIN})"

  # Certbot standalone needs port 80 free; stop NGINX temporarily
  systemctl stop nginx || true

  certbot certonly \
    --standalone \
    --agree-tos \
    --no-eff-email \
    -m "${LE_EMAIL}" \
    -d "${WINGS_DOMAIN}" \
    || error "Certbot failed for ${WINGS_DOMAIN}. Ensure port 80 is open and DNS points here."

  systemctl start nginx
  success "SSL certificate obtained for ${WINGS_DOMAIN}."
}

install_wings_binary() {
  section "Installing Wings Binary"

  mkdir -p /etc/pterodactyl

  ARCH="amd64"
  [[ "$(uname -m)" != "x86_64" ]] && ARCH="arm64"

  curl -L \
    -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}"

  chmod u+x /usr/local/bin/wings
  success "Wings binary installed at /usr/local/bin/wings"
}

setup_wings_service() {
  section "Setting Up Wings Systemd Service"

  cat > /etc/systemd/system/wings.service <<SERVICE
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  success "Wings service unit created (not started yet, config needed first)."
}

print_wings_instructions() {
  echo ""
  echo -e "${YELLOW}${BOLD}Wings requires manual configuration before it can start:${RESET}"
  echo ""
  echo "1. Log into your panel at https://${PANEL_DOMAIN}"
  echo "2. Go to Admin > Nodes > Create New."
  echo "   Set the FQDN to: ${WINGS_DOMAIN}"
  echo "   Enable 'Use SSL Connection' as appropriate."
  echo ""
  echo "3. Open the node, go to the 'Configuration' tab."
  echo "   Either:"
  echo "   a) Copy the config block and save it to /etc/pterodactyl/config.yml"
  echo "   b) Click 'Generate Token', copy the command, and run it on this server."
  echo ""
  echo "4. Once config.yml is in place, start Wings:"
  echo "   sudo systemctl enable --now wings"
  echo ""
  echo "5. Verify Wings started cleanly:"
  echo "   sudo systemctl status wings"
  echo "   sudo journalctl -u wings -f"
  echo ""
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
  section "Installation Complete"
  echo -e "  Panel URL  : ${CYAN}https://${PANEL_DOMAIN}${RESET}"
  if [[ "${INSTALL_WINGS}" == "true" ]]; then
    echo -e "  Wings FQDN : ${CYAN}${WINGS_DOMAIN}${RESET}"
    echo -e "  Wings cert : /etc/letsencrypt/live/${WINGS_DOMAIN}/"
    echo ""
    echo "  Wings service is installed but NOT running yet."
    echo "  Complete the node configuration steps above, then start it."
  fi
  echo ""
  echo -e "${GREEN}${BOLD}Done.${RESET}"
}

# =============================================================================
# MAIN
# =============================================================================

check_env

# Phase 1: Panel
install_base_deps
install_php
install_redis
install_mariadb
install_nginx_certbot
install_composer
setup_database
obtain_panel_ssl
download_panel
install_panel_app
configure_nginx_panel
setup_queue_worker
create_admin_user
print_app_key_warning

# Phase 2: Wings
if [[ "${INSTALL_WINGS}" == "true" ]]; then
  install_docker
  obtain_wings_ssl
  install_wings_binary
  setup_wings_service
  print_wings_instructions
fi

print_summary
