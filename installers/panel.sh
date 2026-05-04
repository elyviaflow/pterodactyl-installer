#!/bin/bash

set -e

######################################################################################
# Pterodactyl Installer (Custom Fixed Version - ElyviaFlow Fork)
######################################################################################

fn_exists() { declare -F "$1" >/dev/null; }

if ! fn_exists lib_loaded; then
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE/lib/lib.sh")
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ VARIABLES ----------------- #

FQDN="${FQDN:-localhost}"

MYSQL_DB="${MYSQL_DB:-panel}"
MYSQL_USER="${MYSQL_USER:-pterodactyl}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"

timezone="${timezone:-Europe/Stockholm}"

ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

email="${email:-}"
user_email="${user_email:-}"
user_username="${user_username:-}"
user_firstname="${user_firstname:-}"
user_lastname="${user_lastname:-}"
user_password="${user_password:-}"

missing=()

for var in email user_email user_username user_firstname user_lastname user_password; do
  if [[ -z "${!var}" ]]; then
    missing+=("$var")
  fi
done

if (( ${#missing[@]} > 0 )); then
  for m in "${missing[@]}"; do
    error "${m} is required"
  done
  exit 1
fi

# ---------------- AUTO FIX SYSTEM ---------------- #

auto_fix_dependencies() {
  output "Running system auto-fix..."

  dpkg --configure -a || true
  apt --fix-broken install -y || true
  apt update -y

  install_packages "curl wget git unzip tar gnupg2 ca-certificates lsb-release"
}

# ---------------- COMPOSER ---------------- #

install_composer() {
  output "Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

ptdl_dl() {
  output "Downloading pterodactyl panel files .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Downloaded pterodactyl panel files!"
}

install_composer_deps() {
  output "Installing composer dependencies.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Installed composer dependencies!"
}

# ---------------- CONFIG ---------------- #

configure() {
  output "Configuring environment.."

  local app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  php artisan key:generate --force

  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true

  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  php artisan migrate --seed --force

  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  success "Configured environment!"
}

set_folder_permissions() {
  case "$OS" in
  ubuntu | debian)
    chown -R www-data:www-data ./*
    ;;
  rocky | almalinux)
    chown -R nginx:nginx ./*
    ;;
  esac
}

insert_cronjob() {
  output "Installing cronjob.. "

  crontab -l 2>/dev/null | {
    cat
    echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -

  success "Cronjob installed!"
}

install_pteroq() {
  output "Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service "$GITHUB_URL/configs/pteroq.service"

  case "$OS" in
  ubuntu | debian)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
    ;;
  rocky | almalinux)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
    ;;
  esac

  systemctl enable pteroq.service
  systemctl start pteroq.service

  success "Installed pteroq!"
}

# ---------------- UBUNTU FIXED DEP ---------------- #

ubuntu_dep() {
  output "Preparing Ubuntu dependencies (fixed mode)..."

  install_packages "software-properties-common apt-transport-https ca-certificates gnupg curl lsb-release"

  add-apt-repository universe -y

  UBUNTU_VERSION=$(lsb_release -rs)

  if [[ "$UBUNTU_VERSION" == "24.04" ]]; then
    output "Ubuntu 24.04 detected -> using native PHP 8.3 (no PPA)"

    rm -f /etc/apt/sources.list.d/ondrej-php*.list || true
    apt update -y
  else
    output "Legacy Ubuntu detected -> enabling Ondrej PHP PPA"
    add-apt-repository -y ppa:ondrej/php
    apt update -y
  fi
}

debian_dep() {
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"

  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

# ---------------- DEP INSTALL ---------------- #

dep_install() {
  output "Installing dependencies for $OS..."

  auto_fix_dependencies
  update_repos

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    [ "$OS" == "debian" ] && debian_dep

    update_repos

    install_packages "php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
      mariadb-server mariadb-client nginx redis-server zip unzip tar git cron"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"
    ;;
  esac

  enable_services
  success "Dependencies installed!"
}

enable_services() {
  systemctl enable nginx mariadb redis-server || true
  systemctl start mariadb || true
}

# ---------------- MAIN ---------------- #

perform_install() {
  output "Starting installation.. this might take a while!"

  auto_fix_dependencies
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx

  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  return 0
}

perform_install