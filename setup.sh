#!/usr/bin/env bash
# =============================================================================
# Pterodactyl Panel + Wings Setup
# Target: Debian 13 (Trixie)
#
# Run on server:
#   curl -sSL https://raw.githubusercontent.com/2hoch1/pterodactyl-installer/main/setup.sh -o /tmp/ptero-setup.sh && sudo bash /tmp/ptero-setup.sh
# =============================================================================

set -euo pipefail

INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/2hoch1/pterodactyl-installer/main/install.sh"

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

confirm_yes() {
  local prompt="$1"
  local answer
  read -rp "${prompt} [Y/n] " answer
  answer="${answer:-y}"
  [[ "${answer,,}" == "y" ]]
}

require_root() {
  [[ $EUID -eq 0 ]] || error "This script must be run as root (use: sudo bash $0)"
}

require_debian13() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID}" == "debian" && "${VERSION_ID}" == "13" ]] \
      || error "This script is for Debian 13 only. Detected: ${ID} ${VERSION_ID}"
  else
    error "Cannot detect OS. /etc/os-release not found."
  fi
  success "Confirmed: Debian 13 (Trixie)"
}

# --- Exported variables (read by install.sh) ---------------------------------
export PANEL_DOMAIN=""
export WINGS_DOMAIN=""
export DB_PASSWORD=""
export LE_EMAIL=""
export TIMEZONE=""
export INSTALL_WINGS="false"

# --- Input gathering ---------------------------------------------------------

validate_config() {
  [[ -n "${PANEL_DOMAIN}" ]] || error "PANEL_DOMAIN is required."
  [[ -n "${DB_PASSWORD}"  ]] || error "DB_PASSWORD is required."
  [[ -n "${LE_EMAIL}"     ]] || error "LE_EMAIL is required."

  local domain_re='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  [[ "${PANEL_DOMAIN}" =~ ${domain_re} ]] \
    || error "PANEL_DOMAIN does not look like a valid domain: ${PANEL_DOMAIN}"
  if [[ "${INSTALL_WINGS}" == "true" ]]; then
    [[ "${WINGS_DOMAIN}" =~ ${domain_re} ]] \
      || error "WINGS_DOMAIN does not look like a valid domain: ${WINGS_DOMAIN}"
  fi
}

gather_input() {
  section "Interactive Configuration"

  echo "This script installs Pterodactyl Panel (PHP 8.3, MariaDB, Redis, NGINX, Certbot)"
  echo "and optionally Pterodactyl Wings (Docker) on this server."
  echo ""

  local default_hostname
  default_hostname="$(hostname -f 2>/dev/null || hostname)"
  # Only use hostname as default if it looks like a valid FQDN (contains a dot)
  [[ "${default_hostname}" != *.* ]] && default_hostname=""
  local default_db_pass
  default_db_pass="$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-')"

  # Panel domain - strip protocol prefix if user pastes a full URL
  read -rp "Panel domain [panel.example.com]: " PANEL_DOMAIN
  PANEL_DOMAIN="${PANEL_DOMAIN:-panel.example.com}"
  PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
  PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
  PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"

  # Wings: single prompt - Enter=this node, custom FQDN=different name, n=skip
  echo ""
  if [[ -n "${default_hostname}" ]]; then
    echo "Wings FQDN: press Enter to install Wings on this node (${default_hostname}),"
  else
    echo "Wings FQDN: type the FQDN for this node (e.g. node1.example.com),"
  fi
  echo "            type a custom FQDN to use a different name, or type 'n' to skip Wings."
  local wings_prompt="Wings FQDN${default_hostname:+ [${default_hostname}]}: "
  read -rp "${wings_prompt}" wings_input
  wings_input="${wings_input:-${default_hostname}}"
  if [[ "${wings_input,,}" == "n" || -z "${wings_input}" ]]; then
    WINGS_DOMAIN=""
    INSTALL_WINGS="false"
  else
    WINGS_DOMAIN="${wings_input}"
    INSTALL_WINGS="true"
  fi

  # DB password (generated default, shown so user can copy it)
  echo ""
  echo -e "MariaDB password default: ${BOLD}${default_db_pass}${RESET}"
  read -rsp "MariaDB password [press Enter to use above]: " DB_PASSWORD
  echo ""
  DB_PASSWORD="${DB_PASSWORD:-${default_db_pass}}"

  # Let's Encrypt email
  read -rp "Let's Encrypt email: " LE_EMAIL

  # Timezone
  read -rp "Timezone [Europe/Berlin]: " TIMEZONE
  TIMEZONE="${TIMEZONE:-Europe/Berlin}"

  validate_config

  section "Installation Plan"
  echo "  Panel domain  : ${PANEL_DOMAIN}"
  if [[ "${INSTALL_WINGS}" == "true" ]]; then
    echo "  Wings FQDN    : ${WINGS_DOMAIN}"
  else
    echo "  Wings         : skipped"
  fi
  echo "  SSL email     : ${LE_EMAIL}"
  echo "  DB user       : pterodactyl @ 127.0.0.1"
  echo "  Timezone      : ${TIMEZONE}"
  echo ""
  confirm_yes "Start installation?" || { echo "Aborted."; exit 0; }
}

# --- Locate or download install.sh -------------------------------------------

locate_install_script() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local local_path="${script_dir}/install.sh"

  if [[ -f "${local_path}" ]]; then
    echo "${local_path}"
    return
  fi

  info "install.sh not found locally, downloading..." >&2
  local tmp
  tmp="$(mktemp /tmp/ptero-install-XXXXXX.sh)"
  curl -sSL "${INSTALL_SCRIPT_URL}" -o "${tmp}" \
    || error "Failed to download install.sh from ${INSTALL_SCRIPT_URL}"
  chmod +x "${tmp}"
  echo "${tmp}"
}

# =============================================================================
# MAIN
# =============================================================================

require_root
require_debian13
gather_input

INSTALL_SCRIPT="$(locate_install_script)"
info "Running installer: ${INSTALL_SCRIPT}"
bash "${INSTALL_SCRIPT}"
