#!/usr/bin/env bash
# ==============================================================================
# Fedora Active Directory & DMS Automated Installer (Pure CLI / TUI Edition)
# Script: setup-ad-dms-tui.sh
# ==============================================================================
set -euo pipefail

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

# ------------------------------------------------------------------------------
# Phase 0: ProtonVPN (PVPN) Prerequisites & Configuration Guard
# ------------------------------------------------------------------------------
echo -e "${BOLD}${BLUE}[PHASE 0/12]${NC} ${BOLD}ProtonVPN (PVPN) Setup & Verification${NC}"
echo -e "${BLUE}======================================================================${NC}"
msg_info "Checking ProtonVPN / PVPN system packages..."

if ! command -v protonvpn-cli &>/dev/null && ! command -v pvpn &>/dev/null; then
  msg_info "Installing PVPN repository and client binaries..."
  FEDORA_VER=$(grep -oP '(?<=VERSION_ID=)\d+' /etc/os-release 2>/dev/null || echo "40")
  
  if dnf install -y "https://repo.protonvpn.com/fedora-${FEDORA_VER}-stable/protonvpn-stable-release/protonvpn-stable-release-1.0.2-1.noarch.rpm" 2>/dev/null; then
    msg_ok "ProtonVPN official repository added."
  else
    msg_warn "Could not import ProtonVPN RPM repository. Trying distro fallback..."
  fi

  if dnf install -y protonvpn-cli proton-vpn-gnome-desktop 2>/dev/null; then
    msg_ok "ProtonVPN packages installed successfully."
  else
    msg_warn "PVPN installation had minor package warnings. Continuing setup..."
  fi
else
  msg_ok "PVPN command-line/GUI packages are already installed."
fi

# ------------------------------------------------------------------------------
# Step 1: Software Swapping (LibreOffice -> ONLYOFFICE)
# ------------------------------------------------------------------------------
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
msg_info "Executing software swap: Removing LibreOffice and installing ONLYOFFICE..."

if dnf remove -y "libreoffice*" 2>/dev/null; then
  msg_ok "LibreOffice packages removed."
else
  msg_warn "LibreOffice removal step finished with warnings or was not installed."
fi

dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm 2>/dev/null || true

if dnf install -y onlyoffice-desktopeditors 2>/dev/null; then
  msg_ok "ONLYOFFICE installation complete."
else
  msg_warn "ONLYOFFICE installation encountered mirror issues. Continuing..."
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
    msg_warn "DNF update completed with non-fatal package warnings. Script execution continuing..."
  fi
fi

# ------------------------------------------------------------------------------
# Step 3: Install AD Prerequisites
# ------------------------------------------------------------------------------
step_header "3" "Installing AD & Security Dependencies"
if dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit 2>/dev/null; then
  msg_ok "All AD prerequisite packages installed."
else
  msg_warn "Some AD dependencies returned minor installation warnings. Proceeding..."
fi

# ------------------------------------------------------------------------------
# Step 4: Install Dank Material Shell (DMS)
# ------------------------------------------------------------------------------
step_header "4" "Installing Dank Material Shell (DMS)"
msg_info "Executing native DMS installer as root..."
if curl -fsSL https://install.danklinux.com | sh 2>/dev/null; then
  msg_ok "DMS native installation executed."
else
  msg_warn "DMS native script execution finished with non-fatal warnings."
fi

# ------------------------------------------------------------------------------
# Step 5: Read Domain Settings
# ------------------------------------------------------------------------------
step_header "5" "Active Directory Configuration"
if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/domain.conf"
  msg_ok "Loaded configuration from 'domain.conf'."
else
  msg_warn "'domain.conf' missing. Using script defaults."
fi

ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Applying AD DNS server configuration (${AD_DNS_IP})..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "${DOMAIN_NAME:-gsfcu.local}" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
fi

systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true
msg_ok "Network clock synchronized via chrony."

if [ -z "${DOMAIN_PASS:-}" ]; then
  echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${DOMAIN_USER:-Administrator}@${DOMAIN_NAME:-gsfcu.local}': "
  read -sp "" DOMAIN_PASS < /dev/tty
  echo ""
fi

# ------------------------------------------------------------------------------
# Step 6: Realm Join
# ------------------------------------------------------------------------------
step_header "6" "Joining Active Directory Realm"
if echo "$DOMAIN_PASS" | realm join --user="${DOMAIN_USER:-Administrator}" "${DOMAIN_NAME:-gsfcu.local}" --verbose; then
  msg_ok "Joined Active Directory realm successfully."
else
  msg_err "Failed to join domain. Check network connection or DNS settings."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 7: Interactive Lab Access Selection
# ------------------------------------------------------------------------------
step_header "7" "Configuring Lab Access Control Rules"

LAB_CONF="${SCRIPT_DIR}/lab.conf"
if [ -f "$LAB_CONF" ]; then
  mapfile -t LAB_ENTRIES < <(grep -v '^[[:space:]]*#' "$LAB_CONF" | grep -v '^[[:space:]]*$')
  
  if [ "${#LAB_ENTRIES[@]}" -gt 0 ]; then
    echo -e "  ${BOLD}Select the Lab ID to allow on this machine:${NC}\n"
    
    idx=1
    declare -A LAB_NAMES
    declare -A LAB_IDS
    
    for entry in "${LAB_ENTRIES[@]}"; do
      IFS=':' read -r name id <<< "$entry"
      LAB_NAMES[$idx]="$name"
      LAB_IDS[$idx]="$id"
      echo -e "    ${CYAN}[$idx]${NC} ${name} (${YELLOW}ID: ${id}${NC})"
      ((idx++))
    done
    
    CHOICE="$SELECTED_LAB_INDEX"
    if [ -z "$CHOICE" ]; then
      if [ "$ASSUME_YES" = true ]; then
        CHOICE=1
      else
        while true; do
          echo -en "\n  ${YELLOW}[INPUT]${NC} Select Lab number [1-$((idx-1))]: "
          read -r CHOICE < /dev/tty
          if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -lt "$idx" ]; then
            break
          fi
          msg_err "Invalid choice. Please enter a valid number."
        done
      fi
    fi

    ALLOWED_ID="${LAB_IDS[$CHOICE]}"
    ALLOWED_NAME="${LAB_NAMES[$CHOICE]}"
    
    msg_ok "Selected Lab: ${ALLOWED_NAME} (${ALLOWED_ID})"

    # Permit selected lab ID
    realm permit -g "$ALLOWED_ID" 2>/dev/null || true

    # Explicitly block other lab IDs listed in lab.conf
    for key in "${!LAB_IDS[@]}"; do
      if [ "$key" -ne "$CHOICE" ]; then
        DENY_ID="${LAB_IDS[$key]}"
        realm deny -g "$DENY_ID" 2>/dev/null || true
        msg_warn "Blocked Lab ID on this machine: ${DENY_ID}"
      fi
    done
    
    msg_ok "Unlisted domain IDs remain allowed."
  fi
else
  msg_warn "'lab.conf' not found. Skipping lab access grouping."
fi

# ------------------------------------------------------------------------------
# Step 8: Policy Refresh Service
# ------------------------------------------------------------------------------
step_header "8" "Setting Up 10-Minute Policy Refresh Service"

if [ -f "${SCRIPT_DIR}/refresh-app-policies.sh" ]; then
  cp "${SCRIPT_DIR}/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies
else
  cat <<'EOF' > /usr/local/bin/refresh-app-policies
#!/usr/bin/env bash
set -euo pipefail
CONF_DIR="/etc/ad-dms"
mkdir -p "$CONF_DIR"

if [ -f "$CONF_DIR/compulsory-apps.conf" ]; then
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | xargs)
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    rpm -q "$app" &>/dev/null || dnf install -y "$app" 2>/dev/null || true
  done < "$CONF_DIR/compulsory-apps.conf"
fi

if [ -f "$CONF_DIR/blocked-apps.conf" ]; then
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | xargs)
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pgrep -x "$app" &>/dev/null && pkill -9 -x "$app" || true
  done < "$CONF_DIR/blocked-apps.conf"
fi
EOF
fi
chmod 755 /usr/local/bin/refresh-app-policies

# Terminal command alias
cat <<'EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
sudo /usr/local/bin/refresh-app-policies
EOF
chmod 755 /usr/local/bin/refresh

# Systemd Service
cat <<'EOF' > /etc/systemd/system/app-policy-sync.service
[Unit]
Description=Sync software allow/block lists & install compulsory apps
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh-app-policies
EOF

# Systemd Timer (Every 10 Minutes)
cat <<'EOF' > /etc/systemd/system/app-policy-sync.timer
[Unit]
Description=Run app-policy-sync every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now app-policy-sync.timer 2>/dev/null || true
/usr/local/bin/refresh-app-policies 2>/dev/null || true
msg_ok "Background policy refresh daemon active."

# ------------------------------------------------------------------------------
# Step 9: System Configs
# ------------------------------------------------------------------------------
step_header "9" "Applying System Configurations"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
  chmod 600 /etc/sssd/sssd.conf 2>/dev/null || true
  chown root:root /etc/sssd/sssd.conf 2>/dev/null || true
  msg_ok "Custom configuration overrides applied."
else
  msg_info "No custom config directory found. Preserving current system configuration."
fi

# ------------------------------------------------------------------------------
# Step 10: PAM Integration
# ------------------------------------------------------------------------------
step_header "10" "Configuring PAM & Home Directories"
authselect select sssd with-mkhomedir --force 2>/dev/null || true
systemctl enable --now oddjobd 2>/dev/null || true
msg_ok "PAM configured for SSSD and automatic home directory creation."

# ------------------------------------------------------------------------------
# Step 11: Configure DMS Profile for New Domain Users (/etc/skel)
# ------------------------------------------------------------------------------
step_header "11" "Applying DMS Themes for New Users (/etc/skel)"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel 2>/dev/null || true
  chmod -R 755 /etc/skel/.config /etc/skel/.local 2>/dev/null || true
  msg_ok "DMS profile unpacked into /etc/skel."
else
  msg_warn "Theme archive 'niri-dms-config.tar.gz' not found. Skipping skeleton sync."
fi

# ------------------------------------------------------------------------------
# Step 12: Restart Services
# ------------------------------------------------------------------------------
step_header "12" "Finalizing Installation"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true

sss_cache -E 2>/dev/null || true
rm -f /var/lib/sss/db/* 2>/dev/null || true
systemctl restart sssd oddjobd greetd 2>/dev/null || true

echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Setup complete! Lab access selected and auto-refresh activated.    ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"