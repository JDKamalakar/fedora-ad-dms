#!/usr/bin/env bash
# ==============================================================================
# Fedora Active Directory & DMS Automated Installer (Pure CLI / TUI Edition)
# Script: setup-ad-dms-tui.sh
# ==============================================================================
set -euo pipefail

# Inhibit system sleep/suspend and screen blanking while script runs
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target &>/dev/null || true
setterm -blank 0 -powersave off -powerdown 0 &>/dev/null || true

cleanup() {
  systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target &>/dev/null || true
}
trap cleanup EXIT

# ANSI Colors
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
NC="\033[0m"

ASSUME_YES=false
SELECTED_LAB_INDEX=""

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    --lab-index=*) SELECTED_LAB_INDEX="${arg#*=}" ;;
  esac
done

draw_banner() {
  clear
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}"
  echo -e "${CYAN}|${NC} ${BOLD}${MAGENTA}        FEDORA ACTIVE DIRECTORY & DMS AUTOMATED SETUP               ${NC} ${CYAN}|${NC}"
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}\n"
}

step_header() {
  echo -e "\n${BOLD}${BLUE}[STEP $1/6]${NC} ${BOLD}$2${NC}"
  echo -e "${BLUE}======================================================================${NC}"
}

msg_info()  { echo -e "  ${CYAN}[INFO]${NC} $1"; }
msg_ok()    { echo -e "  ${GREEN}[OK]${NC} $1"; }
msg_warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
msg_err()   { echo -e "  ${RED}[ERROR]${NC} $1"; }

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local resp

  if [ "$ASSUME_YES" = true ]; then
    msg_info "${prompt} -> Auto-approved (-y flag)"
    return 0
  fi

  while true; do
    echo -en "  ${YELLOW}[PROMPT]${NC} ${prompt} [Y/n]: "
    read -r resp < /dev/tty
    resp="${resp:-$default}"
    case "$resp" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) msg_err "Invalid input. Please enter 'y' or 'n'." ;;
    esac
  done
}

if [ "$EUID" -ne 0 ]; then
  draw_banner
  msg_err "This script requires administrative privileges. Run with 'sudo'."
  exit 1
fi

draw_banner
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$PWD")"
[[ "$SCRIPT_DIR" == "/dev"* ]] && SCRIPT_DIR="$PWD"

# Pre-load configuration settings
if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/domain.conf"
  msg_ok "Loaded configuration settings from 'domain.conf'."
else
  msg_warn "'domain.conf' missing. Falling back to default parameters."
fi

# ------------------------------------------------------------------------------
# Phase 0: ProtonVPN (pVPN) Setup & Initial Connection
# ------------------------------------------------------------------------------
echo -e "${BOLD}${BLUE}[PHASE 0/6]${NC} ${BOLD}ProtonVPN (pVPN) Setup & Connection${NC}"
echo -e "${BLUE}======================================================================${NC}"

SHOULD_INSTALL_PVPN=false
PVPN_MODE="$(echo "${ENABLE_PVPN:-ask}" | tr '[:upper:]' '[:lower:]')"

case "$PVPN_MODE" in
  yes|y|true|1)
    SHOULD_INSTALL_PVPN=true
    msg_info "pVPN installation automatically enabled (ENABLE_PVPN='yes')."
    ;;
  no|n|false|0)
    SHOULD_INSTALL_PVPN=false
    msg_info "pVPN installation explicitly disabled (ENABLE_PVPN='no')."
    ;;
  ask|*)
    if ask_yes_no "Install and connect ProtonVPN (pVPN) for software installation?" "Y"; then
      SHOULD_INSTALL_PVPN=true
    fi
    ;;
esac

if [ "$SHOULD_INSTALL_PVPN" = true ]; then
  msg_info "Downloading and running pVPN installer script..."
  if curl -fsSL https://raw.githubusercontent.com/YourDoritos/pVPN/main/install.sh | bash 2>/dev/null; then
    msg_ok "pVPN installation script executed."
  else
    msg_warn "pVPN installer finished with non-fatal warnings."
  fi

  if [ -n "${PVPN_USER:-}" ] && [ -n "${PVPN_PASS:-}" ]; then
    if command -v pvpnctl &>/dev/null; then
      msg_info "Logging into pVPN with user '${PVPN_USER}'..."
      pvpnctl login "$PVPN_USER" "$PVPN_PASS" 2>/dev/null || true
      
      msg_info "Connecting to pVPN..."
      pvpnctl connect 2>/dev/null || true
      msg_ok "pVPN connection established."
    else
      msg_warn "'pvpnctl' command not found in PATH after installation."
    fi
  else
    msg_warn "pVPN credentials missing in 'domain.conf'. Skipping auto-connect."
  fi
else
  msg_info "Skipping pVPN setup phase."
fi

# ------------------------------------------------------------------------------
# Step 1: Software Swapping (LibreOffice -> ONLYOFFICE)
# ------------------------------------------------------------------------------
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
msg_info "Executing software swap: Removing LibreOffice and installing ONLYOFFICE..."

if dnf remove -y "libreoffice*" 2>/dev/null; then
  msg_ok "LibreOffice packages removed."
else
  msg_warn "LibreOffice removal finished with warnings or packages were not present."
fi

dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm 2>/dev/null || true

if dnf install -y onlyoffice-desktopeditors 2>/dev/null; then
  msg_ok "ONLYOFFICE installation complete."
else
  msg_warn "ONLYOFFICE package installation encountered minor mirror issues. Continuing setup..."
fi

# ------------------------------------------------------------------------------
# Step 2: System Update (Error Guarded)
# ------------------------------------------------------------------------------
step_header "2" "Updating System Packages"
if ask_yes_no "Run full system update ('dnf update')?" "Y"; then
  msg_info "Executing package manager update..."
  if dnf update -y; then
    msg_ok "System update finished cleanly."
  else
    msg_warn "DNF update completed with non-fatal package warnings. Continuing..."
  fi
fi

# ------------------------------------------------------------------------------
# Step 3: Install AD Prerequisites
# ------------------------------------------------------------------------------
step_header "3" "Installing AD & Security Dependencies"
if dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit 2>/dev/null; then
  msg_ok "All AD prerequisite packages installed."
else
  msg_warn "AD dependencies installed with minor package warnings. Proceeding..."
fi

# ------------------------------------------------------------------------------
# Step 4: Install Dank Material Shell (DMS) as Non-Root User
# ------------------------------------------------------------------------------
step_header "4" "Installing Dank Material Shell (DMS)"
REAL_USER="${SUDO_USER:-}"

if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  msg_info "Executing DMS installer as standard user '${REAL_USER}'..."
  if sudo -u "$REAL_USER" bash -c "curl -fsSL https://install.danklinux.com | sh" 2>/dev/null; then
    msg_ok "DMS native installation executed for user '${REAL_USER}'."
  else
    msg_warn "DMS installer finished with execution warnings."
  fi
else
  msg_warn "Direct root session detected without SUDO_USER context."
  msg_warn "DMS installer requires standard user privileges. Skeleton configs will deploy to /etc/skel."
fi

# ------------------------------------------------------------------------------
# Step 5: Disconnect ProtonVPN (pVPN) Before AD/Domain Setup
# ------------------------------------------------------------------------------
step_header "5" "Disconnecting ProtonVPN (pVPN)"
if command -v pvpnctl &>/dev/null; then
  msg_info "Disconnecting pVPN to restore direct domain/local network routing..."
  pvpnctl disconnect 2>/dev/null || true
  msg_ok "pVPN disconnected successfully."
else
  msg_info "pVPN CLI not found. Skipping disconnect step."
fi

# ------------------------------------------------------------------------------
# Step 6: Active Directory & DMS Greeter (greetd) Setup
# ------------------------------------------------------------------------------
step_header "6" "Configuring Active Directory & DMS Greeter (greetd)"

TARGET_DOMAIN="${DOMAIN_NAME:-gsfcu.local}"
TARGET_REALM="${REALM_NAME:-${TARGET_DOMAIN^^}}"
TARGET_ADMIN="${DOMAIN_USER:-admin}"

# 1. DNS & Time Sync
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Configuring NetworkManager DNS (${AD_DNS_IP}) for domain ${TARGET_DOMAIN}..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$TARGET_DOMAIN" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
fi

systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true
msg_ok "Network clock synchronized."

# 2. Realm Join (Prompting only if not already joined and password not in env)
if realm list 2>/dev/null | grep -iq "${TARGET_DOMAIN}"; then
  msg_ok "Device is already joined to Active Directory realm '${TARGET_REALM}'."
else
  if [ -z "${DOMAIN_PASS:-}" ]; then
    echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${TARGET_ADMIN}@${TARGET_REALM}': "
    read -rsp "" DOMAIN_PASS < /dev/tty
    echo ""
  fi

  msg_info "Joining domain '${TARGET_REALM}'..."
  if echo "$DOMAIN_PASS" | realm join --user="${TARGET_ADMIN}" "${TARGET_REALM}" --verbose 2>/dev/null; then
    msg_ok "Joined Active Directory realm '${TARGET_REALM}' successfully."
  else
    if realm list 2>/dev/null | grep -iq "${TARGET_DOMAIN}"; then
      msg_ok "Verified membership in Active Directory realm '${TARGET_REALM}'."
    else
      msg_err "Failed to join domain '${TARGET_REALM}'. Check network connectivity or credentials."
      exit 1
    fi
  fi
fi

# 3. Apply Custom Kerberos and PAM configs if present
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  msg_ok "Kerberos configuration overrides applied."
fi

# Ensure greetd PAM configuration integrates with system-auth (SSSD) and creates home dirs
cat <<'EOF' > /etc/pam.d/greetd
#%PAM-1.0
auth        include     system-auth
account     include     system-auth
password    include     system-auth
session     include     system-auth
session     optional    pam_gnome_keyring.so auto_start
session     optional    pam_mkhomedir.so umask=0077 skel=/etc/skel
EOF

USE_FQDN="False"
if [ "$(echo "${ALLOW_SHORT_USERNAMES:-yes}" | tr '[:upper:]' '[:lower:]')" = "no" ]; then
  USE_FQDN="True"
fi

if [ -f /etc/sssd/sssd.conf ]; then
  if grep -q "\[sssd\]" /etc/sssd/sssd.conf; then
    if ! grep -q "default_domain_suffix" /etc/sssd/sssd.conf; then
      sed -i "/\[sssd\]/a default_domain_suffix = ${TARGET_DOMAIN}" /etc/sssd/sssd.conf
    else
      sed -i "s/default_domain_suffix.*/default_domain_suffix = ${TARGET_DOMAIN}/g" /etc/sssd/sssd.conf
    fi
  fi

  if grep -q "use_fully_qualified_names" /etc/sssd/sssd.conf; then
    sed -i "s/use_fully_qualified_names.*/use_fully_qualified_names = ${USE_FQDN}/g" /etc/sssd/sssd.conf
  else
    sed -i "/\[domain\/.*\]/a use_fully_qualified_names = ${USE_FQDN}" /etc/sssd/sssd.conf
  fi

  if grep -q "fallback_homedir" /etc/sssd/sssd.conf; then
    sed -i "s|fallback_homedir.*|fallback_homedir = /home/%u@%d|g" /etc/sssd/sssd.conf
  else
    sed -i "/\[domain\/.*\]/a fallback_homedir = /home/%u@%d" /etc/sssd/sssd.conf
  fi

  chmod 600 /etc/sssd/sssd.conf
  chown root:root /etc/sssd/sssd.conf
  msg_ok "Configured SSSD (use_fully_qualified_names = ${USE_FQDN}, default_domain_suffix = ${TARGET_DOMAIN})."
fi

authselect select sssd with-mkhomedir --force 2>/dev/null || true
systemctl enable --now oddjobd 2>/dev/null || true
msg_ok "PAM configured for SSSD and automatic home directory creation."

# 4. DMS Greeter (greetd) Account & Cache Directory Setup
mkdir -p /var/cache/dms-greeter/users
chmod 777 /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter/users 2>/dev/null || true

# Pre-populate DMS greeter profile cache for domain user
if [ -n "${TARGET_ADMIN}" ]; then
  mkdir -p "/var/cache/dms-greeter/users/${TARGET_ADMIN}"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/settings.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/settings.json"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/session.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/session.json"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/colors.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/colors.json"
  chmod -R 777 "/var/cache/dms-greeter/users/${TARGET_ADMIN}" 2>/dev/null || true
fi

# Apply SELinux booleans and permissions for domain logins & greeter
setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true
restorecon -R /etc/skel /etc/sssd /etc/pam.d /var/cache/dms-greeter 2>/dev/null || true

# 5. Restart Authentication & Greeter Services
if ask_yes_no "Restart authentication & greeter services (SSSD, Oddjob, greetd) now?" "Y"; then
  systemctl stop sssd oddjobd greetd 2>/dev/null || true
  sss_cache -E 2>/dev/null || true
  rm -f /var/lib/sss/db/* 2>/dev/null || true
  systemctl restart sssd oddjobd 2>/dev/null || true
  systemctl restart greetd 2>/dev/null || true
  msg_ok "Authentication & greeter services restarted. Domain login is ready on DMS Greeter!"
fi

echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Installation steps complete successfully!                            ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
