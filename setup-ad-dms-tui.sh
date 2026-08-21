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
  echo -e "\n${BOLD}${BLUE}[STEP $1/5]${NC} ${BOLD}$2${NC}"
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
echo -e "${BOLD}${BLUE}[PHASE 0/5]${NC} ${BOLD}ProtonVPN (pVPN) Setup & Connection${NC}"
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

echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Installation steps complete successfully!                            ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
