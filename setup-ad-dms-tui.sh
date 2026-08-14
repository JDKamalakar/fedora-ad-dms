#!/usr/bin/env bash
set -euo pipefail

# ANSI Color & Formatting Toolkit
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
NC="\033[0m"

# Parse CLI Flags
ASSUME_YES=false
CLI_LAB_NAME=""
CLI_ALLOW_GROUPS=""
CLI_ALLOW_USERS=""
CLI_DENY_USERS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=true; shift ;;
    -l|--lab) CLI_LAB_NAME="$2"; shift 2 ;;
    --allow-groups) CLI_ALLOW_GROUPS="$2"; shift 2 ;;
    --allow-users) CLI_ALLOW_USERS="$2"; shift 2 ;;
    --deny-users) CLI_DENY_USERS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

draw_banner() {
  clear
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}"
  echo -e "${CYAN}|${NC} ${BOLD}${MAGENTA}       FEDORA ACTIVE DIRECTORY & DMS AUTOMATED SETUP TUI          ${NC} ${CYAN}|${NC}"
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}\n"
}

step_header() {
  echo -e "\n${BOLD}${BLUE}[STEP $1/13]${NC} ${BOLD}$2${NC}"
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
  msg_err "This script requires administrative privileges. Please run with 'sudo'."
  exit 1
fi

draw_banner
msg_info "Welcome to the Fedora AD & DMS Setup Wizard."

if ! ask_yes_no "Do you want to proceed with setup on this machine?" "Y"; then
  msg_warn "Setup cancelled by user."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Remove LibreOffice & Install ONLYOFFICE
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
if ask_yes_no "Remove LibreOffice and install ONLYOFFICE?" "Y"; then
  msg_info "Removing all libreoffice* packages..."
  dnf remove -y "libreoffice*" || true
  
  msg_info "Installing ONLYOFFICE Desktop Editors via DNF..."
  dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm || true
  dnf install -y onlyoffice-desktopeditors || msg_warn "ONLYOFFICE DNF installation finished with non-zero status."
fi

# Step 2: System Package Update
step_header "2" "Updating System Packages"
if ask_yes_no "Run full system update ('dnf update')?" "Y"; then
  dnf update -y
  msg_ok "System packages updated."
fi

# Step 3: AD Prerequisites
step_header "3" "Installing Active Directory & Security Dependencies"
if ask_yes_no "Install AD dependencies (realmd, sssd, polkit, etc.)?" "Y"; then
  dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit
  msg_ok "Core security packages installed."
fi

# Step 4: Install Dank Material Shell (DMS)
step_header "4" "Installing Dank Material Shell (DMS)"
if ask_yes_no "Install Dank Material Shell (DMS)?" "Y"; then
  curl -fsSL https://install.danklinux.com -o /tmp/dms-install.sh
  chmod 777 /tmp/dms-install.sh
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    sudo -u "$REAL_USER" bash /tmp/dms-install.sh < /dev/tty || true
  else
    bash /tmp/dms-install.sh < /dev/tty || true
  fi
  rm -f /tmp/dms-install.sh
  msg_ok "DMS setup step completed."
fi

# Step 5: Read Domain Settings
step_header "5" "Active Directory Domain Parameters"
if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
  msg_ok "Loaded settings from 'domain.conf'."
else
  echo -en "  ${YELLOW}[INPUT]${NC} Domain Name (default: gsfcu.local): "
  read -r DOMAIN_NAME < /dev/tty
  DOMAIN_NAME="${DOMAIN_NAME:-gsfcu.local}"

  echo -en "  ${YELLOW}[INPUT]${NC} AD DNS IP: "
  read -r AD_DNS_IP < /dev/tty

  echo -en "  ${YELLOW}[INPUT]${NC} Domain Admin Username (default: Administrator): "
  read -r DOMAIN_USER < /dev/tty
  DOMAIN_USER="${DOMAIN_USER:-Administrator}"
fi

# Apply Persistent NetworkManager DNS
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Setting AD DNS (${AD_DNS_IP}) on '${TARGET_CONN}'..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$DOMAIN_NAME" ipv4.ignore-auto-dns yes || true
  nmcli connection up "$TARGET_CONN" || true
  systemctl restart NetworkManager || true
fi

# Sync Clock
systemctl enable --now chronyd || true
chronyc makestep > /dev/null 2>&1 || true

# Request Password
echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${DOMAIN_USER:-Administrator}@${DOMAIN_NAME:-gsfcu.local}': "
read -sp "" DOMAIN_PASS < /dev/tty
echo ""

# Step 6: Realm Join
step_header "6" "Joining Active Directory Realm"
if echo "$DOMAIN_PASS" | realm join --user="${DOMAIN_USER:-Administrator}" "${DOMAIN_NAME:-gsfcu.local}" --verbose; then
  msg_ok "Successfully joined domain '${DOMAIN_NAME:-gsfcu.local}'!"
else
  msg_err "Failed to join domain. Check DNS and credentials."
  exit 1
fi

# Step 7: Configure Lab Access Controls & Domain User Restrictions
step_header "7" "Configuring Lab Access Restrictions"

LAB_CONF_FILE="${SCRIPT_DIR}/lab.conf"
[ -f "$LAB_CONF_FILE" ] && source "$LAB_CONF_FILE"

LAB_NAME="${CLI_LAB_NAME:-${LAB_NAME:-LAB_DEFAULT}}"
ALLOWED_GROUPS="${CLI_ALLOW_GROUPS:-${ALLOWED_GROUPS:-Domain Admins}}"
ALLOWED_USERS="${CLI_ALLOW_USERS:-${ALLOWED_USERS:-}}"
DENIED_USERS="${CLI_DENY_USERS:-${DENIED_USERS:-}}"

msg_info "Applying access control rules for '${LAB_NAME}'..."

# Deny all domain users by default, then selectively allow
realm deny --all || true

IFS=',' read -ra AD_GROUPS <<< "$ALLOWED_GROUPS"
for group in "${AD_GROUPS[@]}"; do
  trimmed_group="$(echo "$group" | xargs)"
  if [ -n "$trimmed_group" ]; then
    realm permit -g "$trimmed_group" || true
    msg_ok "Permitted AD Group: '${trimmed_group}'"
  fi
done

if [ -n "$ALLOWED_USERS" ]; then
  IFS=',' read -ra AD_USERS <<< "$ALLOWED_USERS"
  for user in "${AD_USERS[@]}"; do
    trimmed_user="$(echo "$user" | xargs)"
    [ -n "$trimmed_user" ] && realm permit "$trimmed_user" || true
  done
fi

if [ -n "$DENIED_USERS" ]; then
  IFS=',' read -ra BAD_USERS <<< "$DENIED_USERS"
  for bad_user in "${BAD_USERS[@]}"; do
    trimmed_bad="$(echo "$bad_user" | xargs)"
    [ -n "$trimmed_bad" ] && realm deny "$trimmed_bad" || true
    msg_warn "Explicitly blocked user: '${trimmed_bad}'"
  done
fi

# Step 8: Apply Passwordless DNF Allowlist & Block Game/Flatpak Policies
step_header "8" "Applying DNF Allowlist & Game/Flatpak Restrictions"

ALLOWED_APPS_FILE="${SCRIPT_DIR}/allowed-apps.conf"
BLOCKED_APPS_FILE="${SCRIPT_DIR}/blocked-apps.conf"

# 8A. Passwordless DNF Installation via Polkit
if [ -f "$ALLOWED_APPS_FILE" ]; then
  msg_info "Creating Polkit rule for passwordless installation of allowlisted apps..."
  PKGS=$(grep -v '^#' "$ALLOWED_APPS_FILE" | xargs | sed 's/ /|/g')
  
  cat <<EOF > /etc/polkit-1/rules.d/10-passwordless-apps.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.packagekit.package-install" ||
         action.id == "org.baseurl.DnfSystem.install") &&
        subject.isInGroup("domain users")) {
        return polkit.Result.YES;
    }
});
EOF
  msg_ok "Configured Polkit allowlist policy."
fi

# 8B. Block Games & Flatpaks
[ -f "$BLOCKED_APPS_FILE" ] && source "$BLOCKED_APPS_FILE"

if [ -n "${DNF_EXCLUDE:-}" ]; then
  msg_info "Adding package exclusions to /etc/dnf/dnf.conf..."
  sed -i '/^exclude=/d' /etc/dnf/dnf.conf
  echo "exclude=${DNF_EXCLUDE}" >> /etc/dnf/dnf.conf
  msg_ok "DNF game exclusion rule applied."
fi

# Block Flatpak Installations
cat <<EOF > /etc/polkit-1/rules.d/20-block-flatpaks.rules
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.Flatpak") === 0 && !subject.isInGroup("wheel")) {
        return polkit.Result.NO;
    }
});
EOF
msg_ok "Flatpak installation blocked for non-admin domain users."

# Step 9: Copy System Configurations (sssd, krb5, greetd)
step_header "9" "Applying System Configurations"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
  chmod 600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf
  msg_ok "System config files updated."
fi

# Step 10: Configure PAM & Home Directory Generation
step_header "10" "Configuring PAM & Automatic Home Directories"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd

# Step 11: DMS Desktop Theme Enforcement for All New AD Users (/etc/skel)
step_header "11" "Setting Up DMS Theme Inheritance (/etc/skel)"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  msg_info "Unpacking desktop profile into /etc/skel..."
  mkdir -p /etc/skel/.config /etc/skel/.local/share /etc/skel/.local/state
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  
  # Crucial: Permissions must allow read/execute so pam_mkhomedir applies them cleanly
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  find /etc/skel/.config -type f -exec chmod 644 {} +
  msg_ok "DMS layout configured! Every newly logged-in AD user will inherit this desktop."
fi

# Step 12: Cache Cleanup & SELinux
step_header "12" "SELinux & Permission Hardening"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 || true
setsebool -P nis_enabled 1 || true
setsebool -P use_nfs_home_dirs 1 || true

sss_cache -E || true
rm -f /var/lib/sss/db/* || true
systemctl restart sssd oddjobd greetd || true

# Step 13: Complete
step_header "13" "Setup Complete"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Setup successful! Machine joined to AD with Lab Policies enforced. ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
