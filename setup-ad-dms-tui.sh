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

# Parse Command Line Flags (-y / --yes)
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)
      ASSUME_YES=true
      shift
      ;;
  esac
done

draw_banner() {
  clear
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}"
  echo -e "${CYAN}|${NC} ${BOLD}${MAGENTA}       FEDORA ACTIVE DIRECTORY & DMS AUTOMATED SETUP TUI          ${NC} ${CYAN}|${NC}"
  echo -e "${CYAN}+--------------------------------------------------------------------+${NC}\n"
}

step_header() {
  echo -e "\n${BOLD}${BLUE}[STEP $1/12]${NC} ${BOLD}$2${NC}"
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
    msg_info "${prompt} -> Auto-approved (-y flag detected)"
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
if [ "$ASSUME_YES" = true ]; then
  msg_info "Unattended mode enabled (-y flag active)."
fi

if ! ask_yes_no "Do you want to proceed with setup on this machine?" "Y"; then
  msg_warn "Setup cancelled by user."
  exit 0
fi

# Step 1: Remove LibreOffice Software
step_header "1" "Removing Default Software (LibreOffice)"
if ask_yes_no "Do you want to remove LibreOffice packages?" "Y"; then
  msg_info "Removing all libreoffice* packages..."
  dnf remove -y "libreoffice*" || msg_warn "LibreOffice packages not found or already removed."
  msg_ok "LibreOffice removal step completed."
else
  msg_info "Skipping LibreOffice removal."
fi

# Step 2: System Package Update
step_header "2" "Updating System Packages"
if ask_yes_no "Do you want to run a full system update ('dnf update')?" "Y"; then
  msg_info "Running system update..."
  dnf update -y
  msg_ok "System packages updated."
else
  msg_info "Skipping system package update."
fi

# Step 3: Install Active Directory Dependencies
step_header "3" "Installing Active Directory Dependencies"
if ask_yes_no "Do you want to install AD dependencies (realmd, sssd, krb5, oddjob)?" "Y"; then
  msg_info "Installing realmd, sssd, adcli, krb5-workstation, and oddjob..."
  dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils
  msg_ok "Active Directory prerequisite packages installed."
else
  msg_info "Skipping AD package installation."
fi

# Step 4: Install Dank Material Shell (DMS)
step_header "4" "Installing Dank Material Shell (DMS)"
if ask_yes_no "Do you want to run the Dank Material Shell (DMS) installer?" "Y"; then
  msg_info "Executing DMS setup script..."
  curl -fsSL https://install.danklinux.com | sh || msg_warn "DMS installer finished with non-zero status. Continuing..."
  msg_ok "DMS setup phase complete."
else
  msg_info "Skipping DMS installation."
fi

# Step 5: Network / DNS Verification & AD Credentials
step_header "5" "Active Directory & DNS Configuration"
DOMAIN_NAME="gsfcu.local"
REALM_NAME="GSFCU.LOCAL"

# Verify realmd binary exists
if ! command -v realm &> /dev/null; then
  msg_warn "'realm' command not found. Installing 'realmd' package..."
  dnf install -y realmd
fi

# DNS Resolution Check for Domain
msg_info "Checking DNS resolution for domain '${DOMAIN_NAME}'..."
if ! host "$DOMAIN_NAME" &> /dev/null; then
  msg_warn "Could not resolve domain '${DOMAIN_NAME}' via current DNS."
  if ask_yes_no "Do you want to specify your Active Directory DNS server IP?" "Y"; then
    echo -en "  ${YELLOW}[INPUT]${NC} Enter AD DNS Server IP address: "
    read -r AD_DNS_IP < /dev/tty
    if [ -n "$AD_DNS_IP" ]; then
      echo "nameserver $AD_DNS_IP" > /etc/resolv.conf
      msg_ok "Updated /etc/resolv.conf with nameserver ${AD_DNS_IP}."
    fi
  fi
else
  msg_ok "DNS resolution for '${DOMAIN_NAME}' verified."
fi

echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Username (default: Administrator): "
read -r DOMAIN_USER < /dev/tty
DOMAIN_USER="${DOMAIN_USER:-Administrator}"

echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password: "
read -sp "" DOMAIN_PASS < /dev/tty
echo ""

# Step 6: Join AD Realm
step_header "6" "Joining Active Directory Realm"
if echo "$DOMAIN_PASS" | realm join --user="$DOMAIN_USER" "$DOMAIN_NAME"; then
  msg_ok "Successfully joined domain '${DOMAIN_NAME}'."
else
  msg_err "Failed to join domain. Check credentials, time synchronization, and DNS connectivity."
  exit 1
fi

# Function to handle system config files
handle_config_file() {
  local target_path="$1"
  local file_desc="$2"
  local copy_source_dir="$3"

  local filename
  filename=$(basename "$target_path")
  local source_file="${copy_source_dir}/${filename}"

  if [ -n "$copy_source_dir" ] && [ -f "$source_file" ]; then
    cp "$source_file" "$target_path"
    [ "$filename" = "sssd.conf" ] && chmod 600 "$target_path" && chown root:root "$target_path"
    msg_ok "Applied custom '${filename}' -> '${target_path}'."
    return 0
  fi

  case "$filename" in
    "sssd.conf")
      cat <<EOF > /etc/sssd/sssd.conf
[sssd]
domains = ${DOMAIN_NAME}
config_file_version = 2
services = nss, pam
default_domain_suffix = ${DOMAIN_NAME}

[domain/${DOMAIN_NAME}]
id_provider = ad
auth_provider = ad
access_provider = permit
ad_gpo_access_control = permissive
krb5_realm = ${REALM_NAME}
default_domain_suffix = ${DOMAIN_NAME}
use_fully_qualified_names = False
default_shell = /bin/bash
override_homedir = /home/%u
EOF
      chmod 600 /etc/sssd/sssd.conf
      chown root:root /etc/sssd/sssd.conf
      msg_ok "Generated default '/etc/sssd/sssd.conf'."
      ;;
    "krb5.conf")
      cat <<EOF > /etc/krb5.conf
[libdefaults]
    default_realm = ${REALM_NAME}
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    pkinit_anchors = FILE:/etc/pki/tls/certs/ca-bundle.crt
    spake_preauth_groups = edwards25519
    dns_canonicalize_hostname = fallback
    qualify_shortname = ""
    default_ccache_name = KEYRING:persistent:%{uid}
    udp_preference_limit = 0
EOF
      msg_ok "Generated default '/etc/krb5.conf'."
      ;;
    "greetd")
      cat <<EOF > /etc/pam.d/greetd
#%PAM-1.0
auth       substack     system-auth
auth       include      postlogin
account    include      system-auth
password   include      system-auth
session    include      system-auth
session    optional     pam_mkhomedir.so umask=0077 skel=/etc/skel
session    include      postlogin
EOF
      msg_ok "Generated default '/etc/pam.d/greetd'."
      ;;
  esac
}

# Step 7: System Configurations
step_header "7" "Applying System Configurations"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG_DIR=""

if [ -d "${SCRIPT_DIR}/configs" ]; then
  msg_ok "Auto-detected local configs directory '${SCRIPT_DIR}/configs'."
  SOURCE_CONFIG_DIR="${SCRIPT_DIR}/configs"
fi

handle_config_file "/etc/sssd/sssd.conf" "SSSD Configuration" "$SOURCE_CONFIG_DIR"
handle_config_file "/etc/krb5.conf" "Kerberos Configuration" "$SOURCE_CONFIG_DIR"

# Step 8: PAM Integration
step_header "8" "Configuring PAM & Greeter Authentication"
authselect select sssd with-mkhomedir --force
handle_config_file "/etc/pam.d/greetd" "GreetD PAM Policy" "$SOURCE_CONFIG_DIR"

# Step 9: Apply Default Niri & DMS Settings for New Users (/etc/skel)
step_header "9" "Configuring Default Niri & DMS Themes for New Users"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  msg_ok "Auto-detected theme archive '${THEME_ARCHIVE}'."
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  msg_ok "Unpacked desktop configurations to '/etc/skel'! Every new AD user will receive this layout on first login."
else
  msg_warn "No theme archive found at '${THEME_ARCHIVE}'. Skipping /etc/skel population."
fi

# Step 10: Permissions & SELinux
step_header "10" "Setting Permissions & SELinux Policies"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
chmod -R 777 /var/cache/dms-greeter/ 2>/dev/null || true

setsebool -P allow_polyinstantiation 1 || true
setsebool -P nis_enabled 1 || true
setsebool -P use_nfs_home_dirs 1 || true
msg_ok "Cache permissions and SELinux booleans applied."

# Step 11: Clear Caches & Restart Services
step_header "11" "Flushing Caches & Restarting Services"
sss_cache -E || true
rm -f /var/lib/sss/db/* || true

systemctl restart sssd
systemctl restart oddjobd || true
systemctl restart greetd || true
msg_ok "All services restarted successfully."

# Step 12: Done
step_header "12" "Setup Complete"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Installation successful! System joined to AD with DMS enabled.     ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
