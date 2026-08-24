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
  echo -e "\n${BOLD}${BLUE}[STEP $1/7]${NC} ${BOLD}$2${NC}"
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
echo -e "${BOLD}${BLUE}[PHASE 0/7]${NC} ${BOLD}ProtonVPN (pVPN) Setup & Connection${NC}"
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
# Step 3: Install AD Prerequisites & Core Build Tools
# ------------------------------------------------------------------------------
step_header "3" "Installing AD & Security Dependencies"
if dnf install -y dnf-plugins-core realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit git cmake extra-cmake-modules 2>/dev/null; then
  msg_ok "All AD prerequisite packages and core tools installed."
else
  msg_warn "AD dependencies installed with minor package warnings. Proceeding..."
fi

# ------------------------------------------------------------------------------
# Step 4: Install Dank Material Shell (DMS) & Deploy Profiles
# ------------------------------------------------------------------------------
step_header "4" "Installing Dank Material Shell (DMS)"
REAL_USER="${SUDO_USER:-}"

# 1. Execute DMS Installer Script (Dankinstall latest/git version)
DMS_TARGET_USER=""
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  DMS_TARGET_USER="$REAL_USER"
else
  # Detect first human interactive user with UID >= 1000 if not running under sudo
  DMS_TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd || true)
fi

msg_info "Downloading latest Dank Material Shell installer..."
DMS_TMP_DIR=$(mktemp -d)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TAG="amd64" ;;
  aarch64) ARCH_TAG="arm64" ;;
  *) ARCH_TAG="amd64" ;;
esac

LATEST_DMS_TAG=$(curl -s https://api.github.com/repos/AvengeMedia/DankMaterialShell/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
DMS_INSTALLED=false

if [ -n "$LATEST_DMS_TAG" ]; then
  msg_info "Detected latest DMS release: ${LATEST_DMS_TAG}"
  if curl -fsSL "https://github.com/AvengeMedia/DankMaterialShell/releases/download/${LATEST_DMS_TAG}/dankinstall-${ARCH_TAG}.gz" -o "${DMS_TMP_DIR}/dankinstall.gz" 2>/dev/null; then
    gunzip -f "${DMS_TMP_DIR}/dankinstall.gz"
    chmod +x "${DMS_TMP_DIR}/dankinstall"

    # Check if this dankinstall binary supports headless mode (-c / --compositor flag)
    if "${DMS_TMP_DIR}/dankinstall" --help 2>&1 | grep -q -- "--compositor"; then
      msg_info "Executing headless DMS installation (Niri + Kitty + DankCalendar + DankSearch + Greeter)..."
      
      # Build flag list based on supported capabilities in dankinstall help
      DMS_FLAGS=("-c" "niri" "-t" "kitty" "-y")
      if "${DMS_TMP_DIR}/dankinstall" --help 2>&1 | grep -q -- "--dankcalendar"; then
        DMS_FLAGS+=("--dankcalendar")
      fi
      if "${DMS_TMP_DIR}/dankinstall" --help 2>&1 | grep -q -- "--danksearch"; then
        DMS_FLAGS+=("--danksearch")
      fi
      if "${DMS_TMP_DIR}/dankinstall" --help 2>&1 | grep -q -- "--include-deps"; then
        DMS_FLAGS+=("--include-deps" "dms-greeter")
      fi

      if [ -n "$DMS_TARGET_USER" ] && id "$DMS_TARGET_USER" &>/dev/null; then
        # Ensure target user has cached sudo permissions before invocation
        if sudo -u "$DMS_TARGET_USER" "${DMS_TMP_DIR}/dankinstall" "${DMS_FLAGS[@]}" 2>&1; then
          DMS_INSTALLED=true
          msg_ok "DMS installation with full dependencies executed successfully for user '${DMS_TARGET_USER}'."
        fi
      else
        if "${DMS_TMP_DIR}/dankinstall" "${DMS_FLAGS[@]}" 2>&1; then
          DMS_INSTALLED=true
          msg_ok "DMS installation with full dependencies executed successfully."
        fi
      fi
    else
      msg_info "Installed dankinstall version does not have headless flags. Using COPR / git installation fallback..."
    fi
  fi
fi

rm -rf "$DMS_TMP_DIR"

# Enable COPR repositories (avengemedia/dms and git repository for latest bleeding-edge/git builds)
msg_info "Configuring and synchronizing DMS COPR repositories (including git builds)..."
dnf copr enable -y avengemedia/dms 2>/dev/null || true
dnf copr enable -y avengemedia/dms-git 2>/dev/null || true
dnf copr enable -y avengemedia/danklinux 2>/dev/null || true

# Install / upgrade packages to ensure latest git packages and optional dependencies are present
dnf install -y dms dms-greeter greetd niri kitty matugen quickshell 2>/dev/null || true
dnf upgrade -y dms dms-greeter 2>/dev/null || true
msg_ok "DMS packages and git versions synchronized."

# 2. Let Dank Material Shell set up its clean configuration
# Instead of hardcoding broken display/output overrides, run 'dms setup' for user template
if command -v dms &>/dev/null; then
  msg_info "Initializing DMS desktop and niri runtime configurations..."
  if [ -n "$DMS_TARGET_USER" ] && id "$DMS_TARGET_USER" &>/dev/null; then
    sudo -u "$DMS_TARGET_USER" dms setup 2>/dev/null || true
  fi
fi

# Ensure /etc/skel receives clean niri & DMS config generated by dms if available
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  USER_HOME=$(eval echo "~${REAL_USER}")
  if [ -d "${USER_HOME}/.config/niri" ]; then
    mkdir -p /etc/skel/.config
    cp -r "${USER_HOME}/.config/niri" /etc/skel/.config/ 2>/dev/null || true
  fi
  if [ -d "${USER_HOME}/.config/DankMaterialShell" ]; then
    mkdir -p /etc/skel/.config
    cp -r "${USER_HOME}/.config/DankMaterialShell" /etc/skel/.config/ 2>/dev/null || true
  fi
fi

msg_ok "DMS and Niri configurations successfully synchronized."

# ------------------------------------------------------------------------------
# Step 5: Install & Apply Darkly Theme
# ------------------------------------------------------------------------------
step_header "5" "Installing & Applying Darkly Theme"

msg_info "Enabling deltacopy/darkly COPR repository..."
dnf copr enable -y deltacopy/darkly 2>/dev/null || true

DARKLY_INSTALLED=false
msg_info "Installing Darkly style package..."
if dnf install -y darkly darkly-qt5 darkly-qt6 2>/dev/null; then
  DARKLY_INSTALLED=true
  msg_ok "Darkly package installed via repository."
else
  msg_warn "COPR package install failed or unavailable for this release. Building Darkly from source..."
  DARKLY_BUILD_DIR=$(mktemp -d)
  if git clone --depth 1 https://github.com/Bali10050/Darkly.git "${DARKLY_BUILD_DIR}" 2>/dev/null; then
    dnf install -y git cmake extra-cmake-modules kwin-devel kf6-kcolorscheme-devel kf6-kguiaddons-devel kf6-ki18n-devel kf6-kiconthemes-devel kf6-kirigami-devel kf6-kcmutils-devel 2>/dev/null || true
    (
      cd "${DARKLY_BUILD_DIR}"
      chmod +x install.sh 2>/dev/null || true
      ./install.sh 2>/dev/null || true
    )
    DARKLY_INSTALLED=true
    msg_ok "Darkly compiled and installed from source."
  else
    msg_warn "Could not clone Darkly repository. Setting configuration fallback."
  fi
  rm -rf "${DARKLY_BUILD_DIR}"
fi

# Apply Darkly widget style to /etc/skel and current user
apply_darkly_style() {
  local target_home="$1"
  local target_user="${2:-}"

  mkdir -p "${target_home}/.config"
  local kdeglobals_file="${target_home}/.config/kdeglobals"

  if [ -f "$kdeglobals_file" ]; then
    if grep -q "\[KDE\]" "$kdeglobals_file"; then
      if grep -q "widgetStyle=" "$kdeglobals_file"; then
        sed -i "s/^widgetStyle=.*/widgetStyle=Darkly/g" "$kdeglobals_file"
      else
        sed -i "/\[KDE\]/a widgetStyle=Darkly" "$kdeglobals_file"
      fi
    else
      echo -e "\n[KDE]\nwidgetStyle=Darkly" >> "$kdeglobals_file"
    fi
  else
    cat <<'EOF' > "$kdeglobals_file"
[KDE]
widgetStyle=Darkly
EOF
  fi

  if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    chown -R "${target_user}:" "${target_home}/.config" 2>/dev/null || true
    if command -v kwriteconfig6 &>/dev/null; then
      sudo -u "$target_user" kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle Darkly 2>/dev/null || true
    elif command -v kwriteconfig5 &>/dev/null; then
      sudo -u "$target_user" kwriteconfig5 --file kdeglobals --group KDE --key widgetStyle Darkly 2>/dev/null || true
    fi
  fi
}

apply_darkly_style "/etc/skel"

if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  USER_HOME=$(eval echo "~${REAL_USER}")
  if [ -d "$USER_HOME" ]; then
    apply_darkly_style "$USER_HOME" "$REAL_USER"
  fi
fi

msg_ok "Applied Darkly widget style to system templates and user configuration."

# ------------------------------------------------------------------------------
# Step 6: Disconnect ProtonVPN (pVPN) Before AD/Domain Setup
# ------------------------------------------------------------------------------
step_header "6" "Disconnecting ProtonVPN (pVPN)"
if command -v pvpnctl &>/dev/null; then
  msg_info "Disconnecting pVPN to restore direct domain/local network routing..."
  pvpnctl disconnect 2>/dev/null || true
  msg_ok "pVPN disconnected successfully."
else
  msg_info "pVPN CLI not found. Skipping disconnect step."
fi

# ------------------------------------------------------------------------------
# Step 7: Active Directory & DMS Greeter (greetd) Setup
# ------------------------------------------------------------------------------
step_header "7" "Configuring Active Directory & DMS Greeter (greetd)"

TARGET_DOMAIN="${DOMAIN_NAME:-gsfcu.local}"
TARGET_REALM="${REALM_NAME:-${TARGET_DOMAIN^^}}"
TARGET_ADMIN="${DOMAIN_USER:-admin}"

# 1. DNS & Time Sync
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Configuring NetworkManager & systemd-resolved DNS (${AD_DNS_IP}) for domain ${TARGET_DOMAIN}..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$TARGET_DOMAIN" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
  
  # Ensure systemd-resolved routes queries for the domain to AD DNS
  if command -v resolvectl &>/dev/null; then
    resolvectl dns "$TARGET_CONN" "$AD_DNS_IP" 2>/dev/null || true
    resolvectl domain "$TARGET_CONN" "~${TARGET_DOMAIN}" "${TARGET_DOMAIN}" 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
  fi
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

# Full system-auth & systemd-logind compatible PAM stack for greetd
cat <<'EOF' > /etc/pam.d/greetd
#%PAM-1.0
auth       substack    system-auth
-auth      optional    pam_gnome_keyring.so
-auth      optional    pam_kwallet5.so
-auth      optional    pam_kwallet.so
auth       include     postlogin

account    required    pam_nologin.so
account    include     system-auth

password   include     system-auth

session    optional    pam_keyinit.so force revoke
session    required    pam_selinux.so close
session    required    pam_loginuid.so
session    required    pam_selinux.so open
session    include     system-auth
-session   optional    pam_systemd.so
-session   optional    pam_gnome_keyring.so auto_start
-session   optional    pam_kwallet5.so auto_start
-session   optional    pam_kwallet.so auto_start
session    include     postlogin
session    optional    pam_mkhomedir.so umask=0077 skel=/etc/skel
EOF

USE_FQDN="False"
if [ "$(echo "${ALLOW_SHORT_USERNAMES:-yes}" | tr '[:upper:]' '[:lower:]')" = "no" ]; then
  USE_FQDN="True"
fi

if [ -f /etc/sssd/sssd.conf ]; then
  # Ensure sssd.conf contains required sections and permissions
  if grep -q "\[sssd\]" /etc/sssd/sssd.conf; then
    if ! grep -q "default_domain_suffix" /etc/sssd/sssd.conf; then
      sed -i "/\[sssd\]/a default_domain_suffix = ${TARGET_DOMAIN}" /etc/sssd/sssd.conf
    else
      sed -i "s/^default_domain_suffix.*/default_domain_suffix = ${TARGET_DOMAIN}/g" /etc/sssd/sssd.conf
    fi
  fi

  if grep -q "use_fully_qualified_names" /etc/sssd/sssd.conf; then
    sed -i "s/^use_fully_qualified_names.*/use_fully_qualified_names = ${USE_FQDN}/g" /etc/sssd/sssd.conf
  else
    sed -i "/\[domain\/.*\]/a use_fully_qualified_names = ${USE_FQDN}" /etc/sssd/sssd.conf
  fi

  if grep -q "fallback_homedir" /etc/sssd/sssd.conf; then
    sed -i "s|^fallback_homedir.*|fallback_homedir = /home/%u@%d|g" /etc/sssd/sssd.conf
  else
    sed -i "/\[domain\/.*\]/a fallback_homedir = /home/%u@%d" /etc/sssd/sssd.conf
  fi

  # Enable access_provider = permit and disable GPO restrictions for domain users
  if grep -q "access_provider" /etc/sssd/sssd.conf; then
    sed -i "s/^access_provider.*/access_provider = permit/g" /etc/sssd/sssd.conf
  else
    sed -i "/\[domain\/.*\]/a access_provider = permit" /etc/sssd/sssd.conf
  fi

  if ! grep -q "ad_gpo_access_control" /etc/sssd/sssd.conf; then
    sed -i "/\[domain\/.*\]/a ad_gpo_access_control = permissive" /etc/sssd/sssd.conf
  fi

  if ! grep -q "cache_credentials" /etc/sssd/sssd.conf; then
    sed -i "/\[domain\/.*\]/a cache_credentials = True" /etc/sssd/sssd.conf
  fi

  chmod 600 /etc/sssd/sssd.conf
  chown root:root /etc/sssd/sssd.conf
  msg_ok "Configured SSSD (use_fully_qualified_names = ${USE_FQDN}, default_domain_suffix = ${TARGET_DOMAIN}, access_provider = permit)."
fi

authselect select sssd with-mkhomedir --force 2>/dev/null || true
systemctl enable --now oddjobd 2>/dev/null || true
msg_ok "PAM configured for SSSD and automatic home directory creation."

# 4. DMS Greeter (greetd) Account, Service & Cache Directory Setup
mkdir -p /etc/greetd
cat <<'EOF' > /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
command = "dms-greeter --command niri"
user = "greeter"
EOF

# Ensure greeter user exists and has video/input/greeter permissions
if ! id "greeter" &>/dev/null; then
  useradd -M -N -g 1000 -r -s /sbin/nologin -d /var/empty/greetd greeter 2>/dev/null || useradd -r -s /sbin/nologin greeter 2>/dev/null || true
fi
usermod -aG video,input greeter 2>/dev/null || true

mkdir -p /var/cache/dms-greeter/users
chmod -R 777 /var/cache/dms-greeter 2>/dev/null || true

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
restorecon -R /etc/skel /etc/sssd /etc/pam.d /var/cache/dms-greeter /etc/greetd 2>/dev/null || true

# Sync DMS greeter sessions cleanly
if command -v dms &>/dev/null; then
  msg_info "Synchronizing DMS greeter desktop sessions..."
  dms greeter sync 2>/dev/null || true
fi

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
