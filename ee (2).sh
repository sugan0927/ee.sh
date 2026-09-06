#!/bin/bash
# -------------------------------------------------------------------------------
# ee.sh – Advanced LEMP Stack Manager (EasyEngine‑style)
# Now with Stalwart Mail Server integration
# Commands: ee create domain -mail -ssl, ee mail status, etc.
# -------------------------------------------------------------------------------
set -euo pipefail

# ----------------------------- Configuration -----------------------------------
LEMP_VERSION="2.3"
SCRIPT_NAME=$(basename "$0")
PHP_VERSIONS_SUPPORTED=("8.1" "8.2" "8.3" "8.4")
DEFAULT_PHP="8.3"
REDIS_CACHE_EXPIRY="3600"
NGINX_CACHE_PATH="/var/cache/nginx"
NGINX_CACHE_KEY="\$scheme\$host\$request_uri"
NGINX_CACHE_LEVELS="1:2"

# Mail server config
MAIL_SERVER_PORT="8080"
MAIL_SERVER_BINARY="/usr/local/bin/stalwart"
MAIL_CONFIG_DIR="/etc/stalwart"
MAIL_DATA_DIR="/var/lib/stalwart/data"
MAIL_ENV_FILE="/etc/stalwart/stalwart.env"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----------------------------- Helper functions --------------------------------
die() { echo -e "${RED}[ERROR] $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
heading() { echo -e "${BLUE}==> $*${NC}"; }

check_root() { [[ $EUID -eq 0 ]] || die "This script must be run as root."; }

reload_nginx() {
    if ! nginx -t &>/tmp/nginx-test.log; then
        warn "Nginx configuration test failed:"
        cat /tmp/nginx-test.log
        die "Fix the Nginx config above before continuing."
    fi
    systemctl reload nginx
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        if [[ "$OS" == "ubuntu" && "$VERSION" == "24.04" ]] || [[ "$OS" == "debian" && "$VERSION" == "12" ]]; then
            return 0
        fi
    fi
    die "Unsupported OS. Only Ubuntu 24.04 and Debian 12 are supported."
}

confirm() {
    local prompt="$1"
    read -p "$prompt (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ----------------------------- MariaDB Secure (robust) -------------------------
secure_mysql() {
    local MYSQL_ROOT_PASS=""
    local PASS_FILE="/root/.mysql_root_password"
    local CAN_CONNECT_WITHOUT_PASS=false

    if mysql -u root -e "SELECT 1" &>/dev/null; then
        CAN_CONNECT_WITHOUT_PASS=true
    fi

    if $CAN_CONNECT_WITHOUT_PASS; then
        MYSQL_ROOT_PASS=$(openssl rand -base64 24)
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
        echo "$MYSQL_ROOT_PASS" > "$PASS_FILE"
        chmod 600 "$PASS_FILE"
        info "MariaDB root password set and saved to $PASS_FILE"
    else
        if [[ -f "$PASS_FILE" ]]; then
            MYSQL_ROOT_PASS=$(cat "$PASS_FILE")
            if mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
                info "Using existing MariaDB root password from $PASS_FILE"
            else
                warn "Stored password does not work. Please enter the current MariaDB root password:"
                read -s -p "Current MariaDB root password: " MYSQL_ROOT_PASS
                echo
                if ! mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
                    die "Incorrect password. Cannot proceed."
                fi
                echo "$MYSQL_ROOT_PASS" > "$PASS_FILE"
                chmod 600 "$PASS_FILE"
                info "Password updated in $PASS_FILE"
            fi
        else
            warn "No saved MariaDB root password found. Please enter the current root password (or leave blank if none):"
            read -s -p "Current MariaDB root password: " MYSQL_ROOT_PASS
            echo
            if [[ -z "$MYSQL_ROOT_PASS" ]]; then
                if mysql -u root -e "SELECT 1" &>/dev/null; then
                    MYSQL_ROOT_PASS=$(openssl rand -base64 24)
                    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
                    echo "$MYSQL_ROOT_PASS" > "$PASS_FILE"
                    chmod 600 "$PASS_FILE"
                    info "New MariaDB root password set and saved to $PASS_FILE"
                else
                    die "Cannot connect to MariaDB without password. Please provide the correct password."
                fi
            else
                if ! mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
                    die "Incorrect password. Cannot proceed."
                fi
                echo "$MYSQL_ROOT_PASS" > "$PASS_FILE"
                chmod 600 "$PASS_FILE"
                info "Password saved to $PASS_FILE"
            fi
        fi
    fi

    local PASS=$(cat "$PASS_FILE")
    mysql -u root -p"$PASS" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -u root -p"$PASS" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
    mysql -u root -p"$PASS" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -p"$PASS" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
    mysql -u root -p"$PASS" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    info "MariaDB secured."
}

# ----------------------------- Core LEMP Installation --------------------------
# On many VPS/container hosts (OpenVZ, KVM templates, some cloud images),
# there is no real block device (e.g. /dev/vda) that grub-pc can install
# itself onto. If a kernel/grub-pc upgrade is pulled in by `apt upgrade`,
# grub-pc's postinst tries to run grub-install against that non-existent
# device, fails, leaves dpkg in a broken state, and — because of `set -e`
# — kills the entire install with no LEMP packages installed at all.
# Preseeding debconf to install grub-pc to "no device" (equivalent to
# unchecking every device in `dpkg-reconfigure grub-pc`) avoids this
# entirely, and the running kernel doesn't need a bootloader touch anyway
# since most such hosts manage the kernel/bootloader outside the guest.
safe_system_upgrade() {
    heading "Updating system packages..."
    apt update

    if dpkg -l grub-pc &>/dev/null; then
        echo "grub-pc grub-pc/install_devices multiselect" | debconf-set-selections
        echo "grub-pc grub-pc/install_devices_empty boolean true" | debconf-set-selections
    fi

    if ! apt upgrade -y; then
        warn "apt upgrade hit an error (commonly grub-pc/bootloader on VPS or containers)."
        warn "Repairing package state and retrying..."
        dpkg --configure -a || true
        apt --fix-broken install -y || true
        if ! apt upgrade -y; then
            warn "System upgrade still incomplete after repair attempt."
            warn "Continuing anyway — this does not block installing nginx/PHP/MariaDB below."
        fi
    fi
}

install_lemp() {
    heading "Installing full LEMP stack with optimisations..."
    export DEBIAN_FRONTEND=noninteractive

    safe_system_upgrade
    apt install -y curl wget git unzip apt-transport-https gnupg2 \
        software-properties-common lsb-release ca-certificates

    ensure_php_repo
    apt update
    apt install -y nginx mariadb-server mariadb-client \
        php${DEFAULT_PHP}-fpm php${DEFAULT_PHP}-cli php${DEFAULT_PHP}-common \
        php${DEFAULT_PHP}-mysql php${DEFAULT_PHP}-curl php${DEFAULT_PHP}-gd \
        php${DEFAULT_PHP}-mbstring php${DEFAULT_PHP}-xml php${DEFAULT_PHP}-zip \
        php${DEFAULT_PHP}-bcmath php${DEFAULT_PHP}-soap php${DEFAULT_PHP}-intl \
        php${DEFAULT_PHP}-opcache

    apt install -y redis-server php${DEFAULT_PHP}-redis

    systemctl enable --now nginx mariadb redis-server php${DEFAULT_PHP}-fpm

    secure_mysql

    configure_php "$DEFAULT_PHP"
    configure_nginx
    configure_redis

    setup_firewall
    setup_fail2ban
    setup_unattended_upgrades

    apt install -y certbot python3-certbot-nginx python3-certbot-dns-cloudflare

    setup_php_auto_upgrade

    info "LEMP installation complete. Default PHP version: $DEFAULT_PHP"
    info "MariaDB root password: $(cat /root/.mysql_root_password)"
}

# ----------------------------- PHP Configuration ------------------------------
configure_php() {
    local ver="$1"
    local ini="/etc/php/${ver}/fpm/php.ini"
    local cli="/etc/php/${ver}/cli/php.ini"
    [[ -f "$ini" ]] || die "PHP ini file not found: $ini"
    [[ -f "$cli" ]] || die "PHP cli file not found: $cli"
    for f in "$ini" "$cli"; do
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 128M/' "$f"
        sed -i 's/^post_max_size = .*/post_max_size = 128M/' "$f"
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$f"
        sed -i 's/^max_execution_time = .*/max_execution_time = 600/' "$f"
        sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$f"
        sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$f"
        sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=256/' "$f"
        sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$f"
        sed -i 's/^;opcache.validate_timestamps=.*/opcache.validate_timestamps=0/' "$f"
    done

    local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
    [[ -f "$pool" ]] || die "PHP pool file not found: $pool"
    sed -i 's/^pm = .*/pm = dynamic/' "$pool"
    sed -i 's/^pm.max_children = .*/pm.max_children = 100/' "$pool"
    sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/' "$pool"
    sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$pool"
    sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 50/' "$pool"
    systemctl restart php${ver}-fpm
}

configure_nginx() {
    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 128M;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml application/atom+xml image/svg+xml;

    fastcgi_cache_path /var/cache/nginx levels=1:2 keys_zone=fastcgicache:100m inactive=60m;
    fastcgi_cache_key "$scheme$host$request_uri";
    fastcgi_cache_use_stale error timeout invalid_header http_500 http_503;
    fastcgi_cache_lock on;
    fastcgi_cache_lock_timeout 5s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    mkdir -p /var/cache/nginx
    chown -R www-data:www-data /var/cache/nginx

    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
    reload_nginx
}

configure_redis() {
    sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
    systemctl restart redis-server
}

setup_firewall() {
    apt install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw allow 8080/tcp   # for mail server admin during setup
    ufw --force enable
}

setup_fail2ban() {
    apt install -y fail2ban

    # Custom filter for WordPress wp-login.php brute force (no filter for this
    # ships with the fail2ban package, so it must be created here or the jail
    # below fails to start with "Unable to read the filter").
    cat > /etc/fail2ban/filter.d/wp-login.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST .*wp-login\.php.*" (200|401|403)
            ^<HOST> .* "POST .*xmlrpc\.php.*" (200|401|403)
ignoreregex =
EOF

    # Only filters that actually ship with the fail2ban package on
    # Ubuntu 24.04 / Debian 12 are referenced here (nginx-http-auth and
    # nginx-botsearch). "nginx-badbots" and a bare "wordpress" filter do
    # NOT exist in the package and previously made fail2ban fail to start.
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2

[wp-login]
enabled = true
port = http,https
filter = wp-login
logpath = /var/log/nginx/*access.log
maxretry = 3
EOF

    # Validate config before (re)starting so a bad jail can't silently break
    # the whole install; fail loudly here instead of failing later.
    if ! fail2ban-client -t &>/tmp/fail2ban-test.log; then
        warn "fail2ban configuration test failed, see /tmp/fail2ban-test.log"
        cat /tmp/fail2ban-test.log
        die "fail2ban setup failed."
    fi

    systemctl enable --now fail2ban
    systemctl restart fail2ban
}

setup_unattended_upgrades() {
    apt install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl restart unattended-upgrades
}

setup_php_auto_upgrade() {
    cat > /etc/cron.weekly/php-upgrade <<'EOF'
#!/bin/bash
apt update && apt upgrade -y php* 
EOF
    chmod +x /etc/cron.weekly/php-upgrade
}

# ----------------------------- Mail Server Installation -----------------------
install_mail_server() {
    local domain="$1"
    local admin_email="$2"
    local with_ssl="${3:-false}"

    heading "Installing Stalwart Mail Server for $domain..."

    # Ensure LEMP is installed
    if ! command -v nginx &>/dev/null; then
        warn "LEMP not fully installed. Installing LEMP first..."
        install_lemp
    fi

    # Stop any existing Stalwart
    systemctl stop stalwart 2>/dev/null || true
    systemctl disable stalwart 2>/dev/null || true

    # Remove old installation if any (fresh reinstall)
    rm -f /usr/local/bin/stalwart*
    rm -rf /etc/stalwart /var/lib/stalwart

    # Install Stalwart via the OFFICIAL installer. This installs the binary
    # to /usr/local/bin/stalwart, creates the "stalwart" system user, writes
    # a proper systemd unit, and creates /etc/stalwart/stalwart.env — all
    # without any interactive prompts, so it needs no stdin input at all.
    # (Earlier versions of this script pulled a non-existent installer URL
    # and tried to answer prompts that don't exist, which broke mail install.)
    info "Downloading and running the official Stalwart installer..."
    if ! curl -fsSL https://get.stalw.art/install.sh -o /tmp/stalwart-install.sh; then
        die "Could not download the Stalwart installer. Check network/DNS."
    fi
    bash /tmp/stalwart-install.sh
    rm -f /tmp/stalwart-install.sh

    if [[ ! -x "$MAIL_SERVER_BINARY" ]]; then
        die "Stalwart installer finished but $MAIL_SERVER_BINARY was not found."
    fi

    # Stalwart starts in "bootstrap mode" on first run (no config.json yet)
    # and prints a random one-time admin password to the journal. Pin a
    # known password instead via STALWART_RECOVERY_ADMIN, and pre-fill the
    # hostname, so the admin doesn't have to go hunting through logs.
    local bootstrap_pass
    bootstrap_pass=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)

    systemctl stop stalwart 2>/dev/null || true
    touch "$MAIL_ENV_FILE"
    # Remove any previous values for these keys, then set fresh ones.
    sed -i '/^STALWART_RECOVERY_ADMIN=/d; /^STALWART_HOSTNAME=/d' "$MAIL_ENV_FILE"
    {
        echo "STALWART_RECOVERY_ADMIN=admin:$bootstrap_pass"
        echo "STALWART_HOSTNAME=$domain"
    } >> "$MAIL_ENV_FILE"
    chmod 600 "$MAIL_ENV_FILE"

    systemctl daemon-reload
    systemctl enable --now stalwart

    # Wait and verify
    sleep 3
    if systemctl is-active --quiet stalwart; then
        info "Stalwart started successfully on port $MAIL_SERVER_PORT"
    else
        warn "Stalwart failed to start. Checking logs..."
        journalctl -u stalwart -n 30 --no-pager
        die "Mail server installation failed. Check logs above."
    fi

    # Configure Nginx reverse proxy for the domain
    info "Configuring Nginx reverse proxy for $domain..."
    local nginx_config="/etc/nginx/sites-available/$domain"
    cat > "$nginx_config" <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$MAIL_SERVER_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
EOF

    ln -sf "$nginx_config" /etc/nginx/sites-enabled/
    reload_nginx

    # SSL if requested
    if [[ "$with_ssl" == "true" ]]; then
        info "Obtaining SSL certificate for $domain..."
        if [[ -z "$admin_email" ]]; then
            admin_email="admin@$domain"
        fi
        certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$admin_email" --redirect
    fi

    # Open firewall ports for mail (if not already)
    ufw allow 25,587,465,143,993,110,995/tcp 2>/dev/null || true
    ufw reload 2>/dev/null || true

    # Final instructions
    info "========================================="
    info "✅ Stalwart installed and running for $domain"
    info "Admin Panel: https://$domain/admin (if SSL enabled) or http://$domain/admin"
    info "Bootstrap login -> username: admin  password: $bootstrap_pass"
    info "IMPORTANT: This is a ONE-TIME bootstrap login. Open the admin panel,"
    info "sign in with the credentials above, and complete Stalwart's setup"
    info "wizard (hostname is pre-filled as $domain). Once you finish the"
    info "wizard, Stalwart writes $MAIL_CONFIG_DIR/config.json, creates a"
    info "permanent admin account, and this temporary password stops working."
    info "Then configure DKIM/DMARC/SPF DNS records from within the wizard."
    info "========================================="
}

mail_status() {
    if systemctl is-active --quiet stalwart; then
        info "Stalwart is running."
        systemctl status stalwart --no-pager | head -5
    else
        warn "Stalwart is not running."
    fi
}

mail_restart() {
    systemctl restart stalwart
    info "Stalwart restarted."
}

mail_stop() {
    systemctl stop stalwart
    info "Stalwart stopped."
}

mail_start() {
    systemctl start stalwart
    info "Stalwart started."
}

# ----------------------------- Site Management --------------------------------
create_site() {
    local domain="$1"
    local php_version="${2:-$DEFAULT_PHP}"
    local with_ssl="${3:-false}"
    local with_wp="${4:-false}"
    local wildcard="${5:-false}"
    local email="${6:-admin@$domain}"

    if [[ -z "$domain" ]]; then
        die "Usage: site create <domain> [php_version] [--ssl] [--wp] [--wildcard]"
    fi

    # Ensure PHP version is installed
    if ! systemctl status php${php_version}-fpm >/dev/null 2>&1; then
        install_php_version "$php_version"
    fi

    local root_dir="/var/www/$domain/htdocs"
    mkdir -p "$root_dir"
    chown -R www-data:www-data "$root_dir"

    local vhost="/etc/nginx/sites-available/$domain"
    cat > "$vhost" <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
    root $root_dir;
    index index.php index.html;

    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;

    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author_|wordpress_logged_|wp-postpass_" ) { set \$skip_cache 1; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${php_version}-fpm.sock;
        fastcgi_cache fastcgicache;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        fastcgi_cache_valid 200 301 302 $REDIS_CACHE_EXPIRY;
        fastcgi_cache_use_stale error timeout invalid_header http_500 http_503;
        add_header X-Cache \$upstream_cache_status;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf "$vhost" /etc/nginx/sites-enabled/
    reload_nginx

    # SSL
    if [[ "$with_ssl" == "true" ]]; then
        if [[ "$wildcard" == "true" ]]; then
            obtain_wildcard_ssl "$domain" "$email"
        else
            obtain_ssl "$domain" "$email"
        fi
    fi

    # WordPress
    if [[ "$with_wp" == "true" ]]; then
        install_wordpress "$domain" "$root_dir" "$php_version"
    else
        echo "<h1>Site $domain is ready</h1>" > "$root_dir/index.html"
    fi

    info "Site $domain created with PHP $php_version at $root_dir"
}

install_wordpress() {
    local domain="$1"
    local root_dir="$2"
    local php_version="$3"

    heading "Installing WordPress for $domain..."
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/* "$root_dir/"
    rm -rf wordpress latest.tar.gz

    chown -R www-data:www-data "$root_dir"
    find "$root_dir" -type d -exec chmod 755 {} \;
    find "$root_dir" -type f -exec chmod 644 {} \;

    local db_name="wp_${domain//./_}"
    local db_user="wp_${domain//./_}"
    local db_pass=$(openssl rand -base64 18)
    local mysql_root_pass=$(cat /root/.mysql_root_password)

    mysql -u root -p"$mysql_root_pass" -e "CREATE DATABASE $db_name;"
    mysql -u root -p"$mysql_root_pass" -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
    mysql -u root -p"$mysql_root_pass" -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    mysql -u root -p"$mysql_root_pass" -e "FLUSH PRIVILEGES;"

    cd "$root_dir"
    cat > wp-config.php <<EOF
<?php
define('DB_NAME', '$db_name');
define('DB_USER', '$db_user');
define('DB_PASSWORD', '$db_pass');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');
$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
\$table_prefix = 'wp_';

define('WP_CACHE', true);
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);

if ( ! defined('ABSPATH') ) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
EOF
    chown www-data:www-data wp-config.php
    chmod 640 wp-config.php

    wp_cli_download
    wp plugin install redis-cache --activate --allow-root --path="$root_dir"
    wp redis enable --allow-root --path="$root_dir"

    info "WordPress installed at $root_dir. DB: $db_name, user: $db_user, pass: $db_pass"
}

wp_cli_download() {
    if ! command -v wp >/dev/null 2>&1; then
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
    fi
}

delete_site() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        die "Usage: site delete <domain>"
    fi
    heading "Deleting site $domain..."
    rm -f /etc/nginx/sites-enabled/$domain
    rm -f /etc/nginx/sites-available/$domain
    reload_nginx

    rm -rf "/var/www/$domain"

    local db_name="wp_${domain//./_}"
    mysql -u root -p"$(cat /root/.mysql_root_password)" -e "DROP DATABASE IF EXISTS $db_name;" 2>/dev/null || true

    info "Site $domain deleted."
}

# ----------------------------- SSL Management ----------------------------------
obtain_ssl() {
    local domain="$1"
    local email="${2:-admin@$domain}"
    certbot --nginx -d "$domain" -d "www.$domain" --non-interactive --agree-tos --email "$email" --redirect
}

obtain_wildcard_ssl() {
    local domain="$1"
    local email="${2:-admin@$domain}"
    if [[ ! -f /root/.cloudflare.ini ]]; then
        warn "Cloudflare credentials not found. Please create /root/.cloudflare.ini with dns_cloudflare_api_token"
        return
    fi
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.cloudflare.ini \
        -d "$domain" -d "*.$domain" --non-interactive --agree-tos --email "$email"
    local vhost="/etc/nginx/sites-available/$domain"
    if [[ -f "$vhost" ]]; then
        sed -i "s/listen 80;/listen 443 ssl;/" "$vhost"
        sed -i "/server_name/a \\
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;\n\
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;\n\
    include /etc/letsencrypt/options-ssl-nginx.conf;\n\
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;" "$vhost"
        cat > "/etc/nginx/sites-available/${domain}-redirect" <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$host\$request_uri;
}
EOF
        ln -sf "/etc/nginx/sites-available/${domain}-redirect" /etc/nginx/sites-enabled/
        reload_nginx
    fi
    info "Wildcard SSL installed for $domain"
}

# ----------------------------- PHP Version Management --------------------------
# Adds the ondrej/php PPA (Ubuntu) or sury.org repo (Debian) if it isn't
# already present. install_lemp() and install_php_version() both need this;
# previously only install_lemp() added it, so running `ee php install X.Y`
# on its own (without having run `ee install` first) failed with
# "Unable to locate package".
ensure_php_repo() {
    detect_os
    if [[ "$OS" == "ubuntu" ]]; then
        if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
            apt install -y software-properties-common
            add-apt-repository -y ppa:ondrej/php
            apt update
        fi
    else
        if [[ ! -f /etc/apt/sources.list.d/php.list ]]; then
            apt install -y apt-transport-https gnupg2 ca-certificates lsb-release
            curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
            echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
            apt update
        fi
    fi
}

install_php_version() {
    local ver="$1"
    if [[ -z "$ver" ]]; then
        die "Usage: $SCRIPT_NAME php install <version>. Supported: ${PHP_VERSIONS_SUPPORTED[*]}"
    fi
    if [[ ! " ${PHP_VERSIONS_SUPPORTED[*]} " =~ " ${ver} " ]]; then
        die "PHP version $ver not supported. Use: ${PHP_VERSIONS_SUPPORTED[*]}"
    fi
    if systemctl status php${ver}-fpm >/dev/null 2>&1; then
        info "PHP $ver already installed."
        return
    fi
    ensure_php_repo
    heading "Installing PHP $ver..."
    apt install -y php${ver}-fpm php${ver}-cli php${ver}-common \
        php${ver}-mysql php${ver}-curl php${ver}-gd php${ver}-mbstring \
        php${ver}-xml php${ver}-zip php${ver}-bcmath php${ver}-soap \
        php${ver}-intl php${ver}-opcache php${ver}-redis
    configure_php "$ver"
    systemctl enable --now php${ver}-fpm
    info "PHP $ver installed and configured."
}

# ----------------------------- CLI Parser (Short Commands) ---------------------
parse_simple_command() {
    local cmd="$1"
    shift
    case "$cmd" in
        create)
            local domain="$1"
            shift
            local php_version="$DEFAULT_PHP"
            local with_ssl=false
            local with_wp=false
            local wildcard=false
            local with_mail=false
            local email="admin@$domain"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -html)
                        ;;
                    -wp)
                        with_wp=true
                        ;;
                    -ssl)
                        with_ssl=true
                        ;;
                    -wildcard)
                        wildcard=true
                        with_ssl=true
                        ;;
                    -php*)
                        php_version="${1#-php}"
                        if [[ ! " ${PHP_VERSIONS_SUPPORTED[*]} " =~ " ${php_version} " ]]; then
                            die "Unsupported PHP version: $php_version. Use ${PHP_VERSIONS_SUPPORTED[*]}"
                        fi
                        ;;
                    -email)
                        shift
                        email="$1"
                        ;;
                    -mail)
                        with_mail=true
                        ;;
                    *)
                        die "Unknown option: $1"
                        ;;
                esac
                shift
            done

            if [[ "$with_mail" == "true" ]]; then
                # Install mail server on this domain
                install_mail_server "$domain" "$email" "$with_ssl"
            else
                # Create a normal website
                create_site "$domain" "$php_version" "$with_ssl" "$with_wp" "$wildcard" "$email"
            fi
            ;;
        delete)
            local domain="$1"
            delete_site "$domain"
            ;;
        mail)
            shift
            case "$1" in
                status) mail_status ;;
                restart) mail_restart ;;
                stop) mail_stop ;;
                start) mail_start ;;
                *)
                    echo -e "${RED}[ERROR] Unknown mail subcommand: ${1:-}${NC}" >&2
                    echo
                    show_help
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown simple command: $cmd${NC}" >&2
            echo
            show_help
            exit 1
            ;;
    esac
}

# ----------------------------- Help --------------------------------------------
show_help() {
    cat <<EOF
$SCRIPT_NAME – Advanced LEMP + Mail Server Manager

Usage (EE‑style, simple commands):
  $SCRIPT_NAME create <domain> [options]
    Options:
      -html          (default) Create a static HTML site
      -wp            Install WordPress with Redis caching
      -ssl           Obtain Let's Encrypt SSL certificate
      -wildcard      Obtain wildcard SSL (requires Cloudflare DNS)
      -phpX.Y        Use PHP version X.Y (e.g., -php8.4)
      -email <addr>  Email for SSL certificate (default: admin@domain)
      -mail          Install Stalwart Mail Server on this domain

  $SCRIPT_NAME delete <domain>

  $SCRIPT_NAME mail {status|restart|stop|start}

Examples:
  $SCRIPT_NAME create example.com -html -ssl
  $SCRIPT_NAME create myblog.com -wp -ssl -php8.4
  $SCRIPT_NAME create mail.easyinstall.site -mail -ssl
  $SCRIPT_NAME mail status
  $SCRIPT_NAME mail restart

Advanced subcommands (for power users):
  install                 Install full LEMP stack
  site create ...         (same as above, but with --flags)
  site delete <domain>
  php install <version>   Install additional PHP version
  php set-default <ver>   Set default PHP version
  ssl <domain> [email]    Obtain standard SSL
  wildcard <domain> [email] Obtain wildcard SSL
  update                  Update system and PHP packages
  help                    Show this help (works without root, always)

Useful paths (for reference, all in one place):
  Sites:            /var/www/<domain>/htdocs
  Nginx vhosts:     /etc/nginx/sites-available/<domain>
  MariaDB root pw:  /root/.mysql_root_password
  Mail config:      $MAIL_CONFIG_DIR  (config.json appears after the setup wizard)
  Mail data:        $MAIL_DATA_DIR
  Mail env/creds:   $MAIL_ENV_FILE  (STALWART_RECOVERY_ADMIN, STALWART_HOSTNAME)
  Mail admin panel: https://<mail-domain>/admin

Notes:
  - Must be run as root for every command except 'help'.
  - Only Ubuntu 24.04 and Debian 12 are supported.
EOF
}

# ----------------------------- Main Entry --------------------------------------
# help/--help/-h and no-args should ALWAYS work, even without root and even on
# an unsupported OS, so every related command is visible in one place no
# matter what state the machine is in.
if [[ $# -eq 0 || "$1" == "help" || "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

check_root
detect_os

# Simple commands (EE‑style)
if [[ "$1" == "create" || "$1" == "delete" || "$1" == "mail" ]]; then
    parse_simple_command "$@"
    exit 0
fi

# Advanced subcommands
case "$1" in
    install)
        install_lemp
        ;;
    site)
        shift
        case "$1" in
            create)
                shift
                domain="$1"
                php_version="${2:-$DEFAULT_PHP}"
                shift 2
                with_ssl=false
                with_wp=false
                wildcard=false
                email="admin@$domain"
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --ssl) with_ssl=true ;;
                        --wp) with_wp=true ;;
                        --wildcard) wildcard=true ;;
                        --email) shift; email="$1" ;;
                        *) die "Unknown option: $1" ;;
                    esac
                    shift
                done
                create_site "$domain" "$php_version" "$with_ssl" "$with_wp" "$wildcard" "$email"
                ;;
            delete)
                shift
                delete_site "$1"
                ;;
            *) die "Unknown site subcommand. Use create or delete." ;;
        esac
        ;;
    php)
        shift
        case "$1" in
            install)
                shift
                install_php_version "$1"
                ;;
            set-default)
                shift
                DEFAULT_PHP="$1"
                info "Default PHP set to $DEFAULT_PHP (you may need to adjust site configurations)."
                ;;
            *) die "Unknown php subcommand. Use install or set-default." ;;
        esac
        ;;
    ssl)
        shift
        domain="$1"
        email="${2:-admin@$domain}"
        obtain_ssl "$domain" "$email"
        ;;
    wildcard)
        shift
        domain="$1"
        email="${2:-admin@$domain}"
        obtain_wildcard_ssl "$domain" "$email"
        ;;
    update)
        safe_system_upgrade
        info "System and PHP packages updated."
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}[ERROR] Unknown command: $1${NC}" >&2
        echo
        show_help
        exit 1
        ;;
esac