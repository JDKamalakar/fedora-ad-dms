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

# ==============================================================================
# CONFIGURABLE INSTALLATION COMMANDS & VARIABLES
# ==============================================================================
DMS_INSTALL_CMD="${DMS_INSTALL_CMD:-curl -fsSL https://install.danklinux.com | sh}"
TARGET_TIMEZONE="${SYSTEM_TIMEZONE:-Asia/Kolkata}"

# ------------------------------------------------------------------------------
# Phase 0: System Timezone & ProtonVPN (pVPN) Setup & Initial Connection
# ------------------------------------------------------------------------------
echo -e "${BOLD}${BLUE}[PHASE 0/7]${NC} ${BOLD}System Timezone & ProtonVPN (pVPN) Setup${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Synchronize System Timezone (Default: Asia/Kolkata / Indian Standard Time)
if command -v timedatectl &>/dev/null; then
  CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
  if [ "$CURRENT_TZ" != "$TARGET_TIMEZONE" ]; then
    msg_info "Configuring system timezone to '${TARGET_TIMEZONE}'..."
    timedatectl set-timezone "$TARGET_TIMEZONE" 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
    msg_ok "System timezone set to ${TARGET_TIMEZONE} ($(date +'%Z %z'))."
  else
    msg_ok "System timezone is already set to ${TARGET_TIMEZONE}."
  fi
fi

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
# Step 3: Install AD Prerequisites & Deploy System Policy Engine
# ------------------------------------------------------------------------------
step_header "3" "Installing AD Dependencies & Staging App Policy Configurations"
if dnf install -y dnf-plugins-core realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit flatpak 2>/dev/null; then
  msg_ok "All AD prerequisite packages and Flatpak installed."
else
  msg_warn "AD dependencies installed with minor package warnings. Proceeding..."
fi

msg_info "Configuring global Flathub remote repository..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
msg_ok "Flathub remote repository added system-wide."

CONF_DIR="/etc/ad-dms"
mkdir -p "$CONF_DIR"

msg_info "Deploying system app policy configurations to '${CONF_DIR}'..."
for config_file in allowed-apps.conf blocked-apps.conf compulsory-apps.conf group-apps.conf refresh-app-policies.sh remote-tasks.sh domain.conf device-rules.conf lab.conf; do
  if [ -f "${SCRIPT_DIR}/${config_file}" ]; then
    cp -f "${SCRIPT_DIR}/${config_file}" "${CONF_DIR}/"
    msg_ok "Deployed: ${config_file}"
  fi
done

chmod +x "${CONF_DIR}/"*sh 2>/dev/null || true

# ------------------------------------------------------------------------------
# Step 3a: System-Wide Refresh Command, Alias & Headless Background Timer
# ------------------------------------------------------------------------------
msg_info "Deploying refresh utility command..."
cat <<'EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
set -euo pipefail

# Support checking remaining timer interval without root privileges
if [ "${1:-}" = "-t" ] || [ "${1:-}" = "--t" ] || [ "${1:-}" = "--time" ] || [ "${1:-}" = "-time" ]; then
  if systemctl is-active --quiet ad-dms-refresh.timer 2>/dev/null; then
    TIMER_INFO=$(systemctl list-timers ad-dms-refresh.timer --no-pager 2>/dev/null | grep -E "ad-dms-refresh\.timer" || true)
    LEFT_TIME=$(echo "$TIMER_INFO" | awk '{print $3}' || echo "unknown")
    NEXT_DATE=$(echo "$TIMER_INFO" | awk '{print $1, $2}' || echo "unknown")
    echo -e "\033[1;36m[AD-DMS TIMER]\033[0m Next policy refresh scheduled in: \033[1;32m${LEFT_TIME}\033[0m (Next run: ${NEXT_DATE})"
  else
    echo -e "\033[1;33m[AD-DMS TIMER]\033[0m ad-dms-refresh.timer is currently inactive or not installed."
  fi
  exit 0
fi

# Support checking which service/source was used previously & live ping/probe status
if [ "${1:-}" = "-s" ] || [ "${1:-}" = "--s" ] || [ "${1:-}" = "-status" ] || [ "${1:-}" = "--status" ] || [ "${1:-}" = "-source" ] || [ "${1:-}" = "--source" ] || [ "${1:-}" = "-p" ] || [ "${1:-}" = "--p" ] || [ "${1:-}" = "-ping" ] || [ "${1:-}" = "--ping" ]; then
  echo -e "\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;36m║\033[0m                  \033[1;33mAD-DMS POLICY SOURCE & HOST PROBE STATUS\033[0m                \033[1;36m║\033[0m"
  echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m"

  CONF_DIR="/etc/ad-dms"
  SOURCE_LOG="${CONF_DIR}/.last_source"
  
  if [ -f "$SOURCE_LOG" ]; then
    echo -e "  \033[1;36m[PREVIOUS SYNC SOURCE]\033[0m \033[1;32m$(cat "$SOURCE_LOG")\033[0m"
  else
    echo -e "  \033[1;36m[PREVIOUS SYNC SOURCE]\033[0m \033[1;33mNo sync record yet\033[0m"
  fi

  # Load intranet and main host configuration from domain.conf
  INTRANET_HOST="GSFCUPLLAB203"
  INTRANET_IP="10.205.18.253"
  INTRANET_PORT="8080"
  if [ -f "${CONF_DIR}/domain.conf" ]; then
    # shellcheck source=/dev/null
    source "${CONF_DIR}/domain.conf" 2>/dev/null || true
    INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
    INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
    INTRANET_PORT="${INTRANET_PORT:-8080}"
  elif [ -f "/home/jk/Projects/fedora-ad-dms/domain.conf" ]; then
    source "/home/jk/Projects/fedora-ad-dms/domain.conf" 2>/dev/null || true
    INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
    INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
    INTRANET_PORT="${INTRANET_PORT:-8080}"
  fi

  MY_CURR_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
  echo -e "\n  \033[1;36m[MAIN HOST DEVICE TARGET]\033[0m \033[1;37m${INTRANET_HOST}\033[0m (Fallback IP: ${INTRANET_IP}, Port: ${INTRANET_PORT})"

  echo -e "\n  \033[1;36m[ICMP PING PROBE]\033[0m Pinging main host device..."
  ping_ok=false
  for ping_target in "127.0.0.1" "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
    if [ "$ping_target" = "127.0.0.1" ]; then
      if [ "${MY_CURR_HOST,,}" != "${INTRANET_HOST,,}" ]; then
        continue
      fi
    fi
    if ping -c 1 -W 1 "$ping_target" >/dev/null 2>&1; then
      if [ "$ping_target" = "127.0.0.1" ]; then
        echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Current machine is Central Host '${MY_CURR_HOST}')"
      else
        echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Host '${ping_target}' replied to ping)"
      fi
      ping_ok=true
      break
    fi
  done
  if [ "$ping_ok" = false ] && [ -n "$INTRANET_IP" ]; then
    if ping -c 1 -W 1 "$INTRANET_IP" >/dev/null 2>&1; then
      echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Fallback IP '${INTRANET_IP}' replied to ping)"
      ping_ok=true
    fi
  fi
  if [ "$ping_ok" = false ]; then
    echo -e "    -> \033[1;33m○ ICMP PING UNREACHABLE\033[0m (Host '${INTRANET_HOST}' did not answer ping request)"
  fi

  echo -e "\n  \033[1;36m[HTTP SERVICE PROBE]\033[0m Testing reachable upstream service..."
  live_found=false

  # Check localhost first if running on the host machine
  if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/"; then
    if curl -fsSL -m 2 "http://127.0.0.1:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> \033[1;32m● INTRANET HOST ONLINE\033[0m (Local host server active on port ${INTRANET_PORT})"
      live_found=true
    fi
  fi

  if [ "$live_found" = false ]; then
    for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
      if curl -fsSL -m 2 "http://${host_target}:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> \033[1;32m● INTRANET HOST ONLINE\033[0m (Connected via ${host_target}:${INTRANET_PORT})"
        live_found=true
        break
      fi
    done
  fi

  if [ "$live_found" = false ] && [ -n "$INTRANET_IP" ]; then
    if curl -fsSL -m 2 "http://${INTRANET_IP}:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> \033[1;32m● INTRANET IP ONLINE\033[0m (Connected via ${INTRANET_IP}:${INTRANET_PORT})"
      live_found=true
    fi
  fi

  if [ "$live_found" = false ]; then
    if curl -fsSL -m 3 "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> \033[1;34m☁ GITHUB CLOUD FALLBACK\033[0m (Intranet offline, GitHub reachable)."
    else
      echo -e "    -> \033[1;31m✖ ALL UPSTREAM SOURCES OFFLINE\033[0m (No network connectivity)."
    fi
  fi
  echo ""
  exit 0
fi

REPO_RAW_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/config"
CONF_DIR="/etc/ad-dms"

# Load local domain configuration if present to discover intranet host
INTRANET_HOST="GSFCUPLLAB203"
INTRANET_IP="10.205.18.253"
INTRANET_PORT="8080"
USE_INTRANET="yes"

if [ -f "${CONF_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/domain.conf" 2>/dev/null || true
  INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
  INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
  INTRANET_PORT="${INTRANET_PORT:-8080}"
  USE_INTRANET="${USE_INTRANET_FIRST:-yes}"
fi

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# Detect if running in headless background mode (no TTY)
if [ ! -t 1 ]; then
  exec >> /var/log/ad-dms-refresh.log 2>&1
  echo "=== Policy Sync Started: $(date) ==="
else
  echo -e "\033[1;36m[REFETCH] Updating policy engine configuration files (Intranet First & GitHub Fallback)...\033[0m"
fi

mkdir -p "$CONF_DIR"

FILES=(
  "refresh-app-policies.sh"
  "remote-tasks.sh"
  "allowed-apps.conf"
  "blocked-apps.conf"
  "compulsory-apps.conf"
  "group-apps.conf"
  "device-rules.conf"
  "domain.conf"
  "lab.conf"
)

for file in "${FILES[@]}"; do
  [ -t 1 ] && echo -n -e "  -> Fetching: ${file}... "
  fetched=false

  # 1. Try Local Host loopback first if on the intranet host itself
  if [ "$USE_INTRANET" = "yes" ]; then
    MY_CURR_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
    if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/"; then
      if curl -fsSL -m 3 "http://127.0.0.1:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://127.0.0.1:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
        [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet Localhost: 127.0.0.1)\033[0m"
        echo "Intranet Host (127.0.0.1:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
        chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
        fetched=true
      fi
    fi
  fi

  # 1b. Try Intranet Host via Hostname (Plain, .local, and FQDN)
  if [ "$fetched" = false ] && [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_HOST" ]; then
    for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
      if curl -fsSL -m 3 "http://${host_target}:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://${host_target}:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
        [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet Host: ${host_target})\033[0m"
        echo "Intranet Host (${host_target}:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
        chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
        fetched=true
        break
      fi
    done
  fi

  # 2. Try Intranet Host via Fallback IP
  if [ "$fetched" = false ] && [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_IP" ]; then
    if curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
      [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet IP: ${INTRANET_IP})\033[0m"
      echo "Intranet IP (${INTRANET_IP}:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
      chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
      fetched=true
    fi
  fi

  # 3. Fallback to GitHub Cloud CDN
  if [ "$fetched" = false ]; then
    if curl -fsSL "${REPO_RAW_URL}/${file}?$(date +%s)" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/${file}?$(date +%s)" -o "${CONF_DIR}/${file}" 2>/dev/null; then
      [ -t 1 ] && echo -e "\033[1;32m[OK] (GitHub Cloud)\033[0m"
      echo "GitHub Cloud (github.com/JDKamalakar/fedora-ad-dms) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
      chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
      fetched=true
    fi
  fi

  if [ "$fetched" = false ]; then
    [ -t 1 ] && echo -e "\033[1;33m[UNCHANGED / OFFLINE]\033[0m"
  fi
done

# Sync Siren alarm asset if missing or outdated
mkdir -p "${CONF_DIR}/assets"
if [ ! -f "${CONF_DIR}/assets/Siren.mp3" ]; then
  [ -t 1 ] && echo -n -e "  -> Downloading security asset: Siren.mp3... "
  if curl -fsSL -m 3 "http://${INTRANET_HOST}:${INTRANET_PORT}/assets/Siren.mp3" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null || curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/assets/Siren.mp3" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null || curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/assets/Siren.mp3?$(date +%s)" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null; then
    [ -t 1 ] && echo -e "\033[1;32m[OK]\033[0m"
  else
    [ -t 1 ] && echo -e "\033[1;33m[SKIP]\033[0m"
  fi
fi

# Dynamically synchronize ad-dms-refresh.timer interval if domain.conf was updated
if [ -f "${CONF_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/domain.conf" 2>/dev/null || true
  RAW_INT="${REFRESH_INTERVAL:-1h}"
  # Normalize human intervals (e.g. 1hrs -> 1h, 1hr -> 1h, 30mins -> 30m)
  NORM_INT=$(echo "$RAW_INT" | sed -E -e 's/([0-9]+)[[:space:]]*(hrs|hr|hours|hour)/\1h/g' -e 's/([0-9]+)[[:space:]]*(mins|min|minutes|minute)/\1m/g' -e 's/([0-9]+)[[:space:]]*(secs|sec|seconds|second)/\1s/g')
  
  CURRENT_TIMER_INT=$(systemctl show ad-dms-refresh.timer --property=Unit -p AccuracySec 2>/dev/null | grep -i "OnUnitActiveSec" || true)
  if [ -f /etc/systemd/system/ad-dms-refresh.timer ]; then
    cat <<TIMER_EOF > /etc/systemd/system/ad-dms-refresh.timer
[Unit]
Description=Run AD-DMS Policy Refresh Periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${NORM_INT}
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart ad-dms-refresh.timer 2>/dev/null || true
  fi
fi

chmod +x "${CONF_DIR}/"*sh 2>/dev/null || true

if [ -x "${CONF_DIR}/refresh-app-policies.sh" ]; then
  "${CONF_DIR}/refresh-app-policies.sh"
else
  echo "[ERROR] Missing executable engine script at '${CONF_DIR}/refresh-app-policies.sh'"
  exit 1
fi
EOF
chmod +x /usr/local/bin/refresh
msg_ok "Deployed: /usr/local/bin/refresh"

msg_info "Creating user command redirections and aliases..."
cat <<'EOF' > /etc/profile.d/99-ad-dms-aliases.sh
# AD-DMS Command Redirections & User Helpers
alias refresh='sudo /usr/local/bin/refresh'
alias violation='sudo /usr/local/bin/ad-dms-record-violation'
alias violations='sudo /usr/local/bin/ad-dms-record-violation'

dnf() {
  if [ "${1:-}" = "install" ]; then
    shift
    echo -e "\n\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║\033[0m \033[1;33m[AD-DMS NOTICE]\033[0m Please use the managed command: \033[1;32minstall $*\033[0m           \033[1;36m║\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m\n"
    /usr/local/bin/install "$@"
  else
    command dnf "$@"
  fi
}

flatpak() {
  if [ "${1:-}" = "install" ]; then
    shift
    echo -e "\n\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║\033[0m \033[1;33m[AD-DMS NOTICE]\033[0m Please use the managed command: \033[1;32minstall flatpak $*\033[0m   \033[1;36m║\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m\n"
    /usr/local/bin/install flatpak "$@"
  else
    command flatpak "$@"
  fi
}
EOF
chmod 0644 /etc/profile.d/99-ad-dms-aliases.sh

# ------------------------------------------------------------------------------
# Systemd Headless Background Timer Configuration
# ------------------------------------------------------------------------------
INTERVAL="${REFRESH_INTERVAL:-1h}"
msg_info "Configuring automated headless background timer (Interval: ${INTERVAL})..."

cat <<'EOF' > /etc/systemd/system/ad-dms-refresh.service
[Unit]
Description=AD-DMS Automated Headless Policy Refresh Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh
EOF

cat <<EOF > /etc/systemd/system/ad-dms-refresh.timer
[Unit]
Description=Run AD-DMS Policy Refresh Periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ad-dms-refresh.timer 2>/dev/null || true
msg_ok "Systemd background timer 'ad-dms-refresh.timer' activated (${INTERVAL} interval)."

# ------------------------------------------------------------------------------
# Step 3b: Intranet Host Central Server Daemon (Auto-Start web_server.py on port 8080)
# ------------------------------------------------------------------------------
if [ -f "/web_server.py" ]; then
  cat <<EOF > /etc/systemd/system/ad-dms-server.service
[Unit]
Description=AD-DMS Intranet Host Server & Live Control Center (Port 8080)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=
ExecStart=/usr/bin/python3 /web_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now ad-dms-server.service 2>/dev/null || true
  msg_ok "Activated central intranet web & API daemon (ad-dms-server.service on port 8080)."
fi

# ------------------------------------------------------------------------------
# Step 4: Install Dank Material Shell (DMS) & Deploy Profiles
# ------------------------------------------------------------------------------
step_header "4" "Installing Dank Material Shell (DMS)"
REAL_USER="${SUDO_USER:-}"

DMS_TARGET_USER=""
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  DMS_TARGET_USER="$REAL_USER"
else
  DMS_TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd || true)
fi

SHOULD_RUN_DMS_INSTALL=true
if command -v dms &>/dev/null; then
  CURRENT_DMS_VER=$(dms version 2>/dev/null | sed -e 's/^dms[[:space:]]*//' || echo "installed")
  msg_info "Detected existing Dank Material Shell version: ${CURRENT_DMS_VER}"
  if ! ask_yes_no "DMS is already installed. Re-run installation command?" "N"; then
    SHOULD_RUN_DMS_INSTALL=false
    msg_info "Skipping DMS installation command execution."
  fi
fi

if [ "$SHOULD_RUN_DMS_INSTALL" = true ]; then
  msg_info "Executing DMS installer command: '${DMS_INSTALL_CMD}'..."
  if [ -n "$DMS_TARGET_USER" ] && [ "$DMS_TARGET_USER" != "root" ]; then
    sudo -u "$DMS_TARGET_USER" bash -c "$DMS_INSTALL_CMD" 2>&1 || true
  else
    eval "$DMS_INSTALL_CMD" 2>&1 || true
  fi
  msg_ok "DMS installer command completed."
fi

msg_info "Configuring and synchronizing DMS COPR repositories..."
dnf copr enable -y avengemedia/dms 2>/dev/null || true
dnf copr enable -y avengemedia/dms-git 2>/dev/null || true
dnf copr enable -y avengemedia/danklinux 2>/dev/null || true

dnf install -y dms dms-greeter greetd niri kitty matugen quickshell 2>/dev/null || true
dnf upgrade -y dms dms-greeter 2>/dev/null || true
msg_ok "DMS packages and dependencies synchronized."

PRESETS_DIR=""
for cand_dir in "${SCRIPT_DIR}/presets" "/tmp/fedora-ad-dms/presets" "${SCRIPT_DIR}" "/tmp/fedora-ad-dms"; do
  if [ -d "$cand_dir" ] && ls "$cand_dir"/*.tar.gz &>/dev/null; then
    PRESETS_DIR="$cand_dir"
    break
  fi
done

deploy_presets() {
  local target_home="$1"
  local target_user="${2:-}"

  mkdir -p "${target_home}/.config" "${target_home}/.local/share"

  if [ -n "$PRESETS_DIR" ] && [ -d "$PRESETS_DIR" ]; then
    for preset_archive in "${PRESETS_DIR}"/*.tar.gz "${PRESETS_DIR}"/*.tgz; do
      [ -f "$preset_archive" ] || continue
      msg_info "Unpacking preset archive: $(basename "$preset_archive")"
      
      if tar -tzf "$preset_archive" 2>/dev/null | grep -q -E '^\.?/?(\.config|\.local|\.bash|\.zsh)'; then
        tar -xzf "$preset_archive" -C "$target_home" 2>/dev/null || true
      else
        tar -xzf "$preset_archive" -C "${target_home}/.config" 2>/dev/null || true
      fi
    done
  fi

  rm -f "${target_home}/.config/niri/dms/outputs.kdl"
  rm -f "${target_home}/.config/niri/config.kdl.backup"*

  # Ensure Niri automatically spawns DMS on session start (without duplicate spawn entries)
  local niri_conf="${target_home}/.config/niri/config.kdl"
  if [ -f "$niri_conf" ]; then
    # Do not prepend if already spawned or already configured in niri config
    if ! grep -E -q '(spawn-at-startup[[:space:]]+("dms"|dms))' "$niri_conf"; then
      sed -i '1s/^/spawn-at-startup "dms" "run"
/' "$niri_conf"
    fi
  fi

  # Also provide standard XDG desktop autostart entry for DMS as additional safeguard
  mkdir -p "${target_home}/.config/autostart"
  cat <<'AUTOS_EOF' > "${target_home}/.config/autostart/dms.desktop"
[Desktop Entry]
Type=Application
Name=Dank Material Shell
Exec=dms run
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOS_EOF

  if [ ! -d "${target_home}/.config/DankMaterialShell" ] && command -v dms &>/dev/null; then
    if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
      sudo -u "$target_user" dms setup 2>/dev/null || true
    fi
  fi

  if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    chown -R "${target_user}:" "${target_home}/.config" "${target_home}/.local" 2>/dev/null || true
  fi
}

msg_info "Deploying all preset archives from '${PRESETS_DIR:-presets/}' to '/etc/skel' and all user accounts..."
deploy_presets "/etc/skel"

# Deploy to ALL existing user home directories in /home/*
for udir in /home/*; do
  [ -d "$udir" ] || continue
  uname=$(basename "$udir")
  [ "$uname" = "*" ] && continue
  if id "$uname" &>/dev/null; then
    msg_info "Configuring DMS desktop presets for user '${uname}' (${udir})..."
    deploy_presets "$udir" "$uname"
  fi
done

msg_ok "All DMS and desktop preset configurations successfully deployed."

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

ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Configuring NetworkManager & systemd-resolved DNS (${AD_DNS_IP}) for domain ${TARGET_DOMAIN}..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$TARGET_DOMAIN" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
  
  if command -v resolvectl &>/dev/null; then
    resolvectl dns "$TARGET_CONN" "$AD_DNS_IP" 2>/dev/null || true
    resolvectl domain "$TARGET_CONN" "~${TARGET_DOMAIN}" "${TARGET_DOMAIN}" 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
  fi
fi

systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true
msg_ok "Network clock synchronized."

if realm list 2>/dev/null | grep -iq "${TARGET_DOMAIN}"; then
  if ask_yes_no "Machine is already joined to '${TARGET_REALM}'. Rejoin with updated credentials?" "N"; then
    msg_info "Leaving '${TARGET_REALM}' to allow re-enrollment..."
    realm leave "${TARGET_REALM}" 2>/dev/null || true
  else
    msg_ok "Keeping existing enrollment in '${TARGET_REALM}'."
  fi
fi

if ! realm list 2>/dev/null | grep -iq "${TARGET_DOMAIN}"; then
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

if [ ! -s /etc/krb5.conf ] || ! grep -qi "${TARGET_REALM}" /etc/krb5.conf 2>/dev/null; then
  msg_info "Writing /etc/krb5.conf for realm '${TARGET_REALM}'..."
  cat <<EOF > /etc/krb5.conf
# Kerberos configuration — auto-generated by setup-ad-dms-tui.sh
[libdefaults]
 default_realm = ${TARGET_REALM}
 dns_lookup_realm = true
 dns_lookup_kdc = true
 ticket_lifetime = 24h
 renew_lifetime = 7d
 forwardable = true
 rdns = false

[realms]
 ${TARGET_REALM} = {
  kdc = ${AD_DNS_IP:-}
  admin_server = ${AD_DNS_IP:-}
  default_domain = ${TARGET_DOMAIN}
 }

[domain_realm]
 .${TARGET_DOMAIN} = ${TARGET_REALM}
 ${TARGET_DOMAIN} = ${TARGET_REALM}
EOF
  msg_ok "/etc/krb5.conf written for realm '${TARGET_REALM}'."
fi

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

SSSD_SUFFIX=""
if [ "$USE_FQDN" = "True" ]; then
  SSSD_SUFFIX="default_domain_suffix = ${TARGET_DOMAIN}"
fi

if [ -f /etc/sssd/sssd.conf ]; then
  cat <<EOF > /etc/sssd/sssd.conf
[sssd]
domains = ${TARGET_DOMAIN}
config_file_version = 2
services = nss, pam
${SSSD_SUFFIX}

[domain/${TARGET_DOMAIN}]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = ${TARGET_REALM}
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
override_homedir = /home/%u
ad_domain = ${TARGET_DOMAIN}
use_fully_qualified_names = ${USE_FQDN}
ldap_id_mapping = True
access_provider = permit
ad_gpo_access_control = permissive
EOF

  chmod 600 /etc/sssd/sssd.conf
  chown root:root /etc/sssd/sssd.conf
  
  if command -v sssctl &>/dev/null; then
    sssctl config-check 2>/dev/null || true
  fi
  msg_ok "Configured SSSD (use_fully_qualified_names = ${USE_FQDN}, access_provider = permit)."
fi

authselect select sssd with-mkhomedir --force 2>/dev/null || true
systemctl enable --now oddjobd 2>/dev/null || true
msg_ok "PAM configured for SSSD and automatic home directory creation."

mkdir -p /etc/greetd
cat <<'EOF' > /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
command = "dms-greeter --command niri"
user = "greeter"
EOF

if ! id "greeter" &>/dev/null; then
  useradd -M -N -g 1000 -r -s /sbin/nologin -d /var/empty/greetd greeter 2>/dev/null || useradd -r -s /sbin/nologin greeter 2>/dev/null || true
fi
usermod -aG video,input greeter 2>/dev/null || true

mkdir -p /var/cache/dms-greeter/users
chmod -R 777 /var/cache/dms-greeter 2>/dev/null || true

if [ -n "${TARGET_ADMIN}" ]; then
  mkdir -p "/var/cache/dms-greeter/users/${TARGET_ADMIN}"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/settings.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/settings.json"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/session.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/session.json"
  [ ! -f "/var/cache/dms-greeter/users/${TARGET_ADMIN}/colors.json" ] && echo "{}" > "/var/cache/dms-greeter/users/${TARGET_ADMIN}/colors.json"
  chmod -R 777 "/var/cache/dms-greeter/users/${TARGET_ADMIN}" 2>/dev/null || true
fi

setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true
restorecon -R /etc/skel /etc/sssd /etc/pam.d /var/cache/dms-greeter /etc/greetd /etc/ad-dms 2>/dev/null || true

if command -v dms &>/dev/null; then
  msg_info "Synchronizing DMS greeter desktop sessions..."
  dms greeter sync 2>/dev/null || true
fi

if ask_yes_no "Restart authentication services (SSSD, Oddjob) now?" "Y"; then
  echo ""
  for i in 6 5 4 3 2 1; do
    echo -ne "  ${YELLOW}[WAIT]${NC} Restarting in ${BOLD}${i}${NC} seconds... (Ctrl+C to abort)\r"
    sleep 1
  done
  echo ""
  systemctl stop sssd oddjobd 2>/dev/null || true
  sss_cache -E 2>/dev/null || true
  rm -f /var/lib/sss/db/* 2>/dev/null || true
  systemctl restart sssd oddjobd 2>/dev/null || true
  msg_ok "Authentication services restarted."
fi

# ------------------------------------------------------------------------------
# Passwordless Privileges for Non-Admin / Non-Sudo Users (DNF & Refresh Command)
# ------------------------------------------------------------------------------
msg_info "Configuring passwordless package updates, refresh, and installation privileges for non-sudo users..."

cat <<'EOF' > /usr/local/bin/ad-dms-backend-install
#!/usr/bin/env bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi
exec dnf install -y "$@"
EOF
chmod +x /usr/local/bin/ad-dms-backend-install

cat <<'EOF' > /etc/sudoers.d/99-ad-dms-dnf-updates
# Allow all authenticated users to run DNF updates, policy refresh, and verified backend install
ALL ALL=(ALL) NOPASSWD: /usr/local/bin/refresh, /usr/bin/dnf update, /usr/bin/dnf update -y, /usr/bin/dnf upgrade, /usr/bin/dnf upgrade -y, /usr/bin/dnf5 update, /usr/bin/dnf5 update -y, /usr/bin/dnf5 upgrade, /usr/bin/dnf5 upgrade --refresh -y, /usr/bin/dnf5 upgrade -y, /usr/local/bin/ad-dms-backend-install *
EOF
chmod 0440 /etc/sudoers.d/99-ad-dms-dnf-updates

mkdir -p /etc/polkit-1/rules.d

cat <<'EOF' > /etc/polkit-1/rules.d/10-ad-admin-auth.rules
/* Allow wheel group, root, and Domain Admins to authenticate for administrative actions in GUI & Polkit */
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:wheel", "unix-group:Domain Admins", "unix-group:domain admins", "unix-user:root"];
});
EOF

cat <<'EOF' > /etc/polkit-1/rules.d/45-ad-dms-flatpak-allowlist.rules
/* Allow active users to install/manage user-level Flatpaks without root password */
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.Flatpak.app-install" ||
         action.id == "org.freedesktop.Flatpak.runtime-install" ||
         action.id == "org.freedesktop.Flatpak.app-uninstall" ||
         action.id == "org.freedesktop.Flatpak.modify-repo") && subject.active) {
        return polkit.Result.YES;
    }
});
EOF
msg_ok "Passwordless package update, user Flatpaks, and verified install privileges granted to all active users."

# ------------------------------------------------------------------------------
# AD Account Diagnostics
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}--- Active Directory Diagnostics ---${NC}"

echo -e "\n${CYAN}[1] Realm Status:${NC}"
realm list 2>/dev/null || echo "  (realm list returned nothing — machine may not be joined)"

echo -e "\n${CYAN}[2] SSSD Service Status:${NC}"
systemctl is-active sssd 2>/dev/null && systemctl status sssd --no-pager -l 2>/dev/null | tail -20 || echo "  SSSD is NOT running"

echo -e "\n${CYAN}[3] SSSD Config (/etc/sssd/sssd.conf):${NC}"
cat /etc/sssd/sssd.conf 2>/dev/null || echo "  (file not found)"

echo -e "\n${CYAN}[3b] SSSD Config Validation (sssctl config-check):${NC}"
if command -v sssctl &>/dev/null; then
  sssctl config-check 2>&1 || true
else
  echo "  (sssctl not available)"
fi

echo -e "\n${CYAN}[4] DNS Resolution — AD Domain SRV Records:${NC}"
if command -v host &>/dev/null; then
  host -t srv "_ldap._tcp.dc._msdcs.${TARGET_DOMAIN}" 2>&1 || true
  host -t srv "_kerberos._tcp.${TARGET_DOMAIN}" 2>&1 || true
else
  dig +short srv "_ldap._tcp.dc._msdcs.${TARGET_DOMAIN}" 2>&1 || true
fi

echo -e "\n${CYAN}[5] Kerberos Config (/etc/krb5.conf):${NC}"
cat /etc/krb5.conf 2>/dev/null || echo "  (no krb5.conf found)"

echo -e "\n${CYAN}[6] SSSD Log (last 30 lines):${NC}"
journalctl -u sssd -n 30 --no-pager 2>/dev/null || true

echo -e "\n${CYAN}[7] Test domain user lookup:${NC}"
echo -n "  id ${TARGET_ADMIN}: "
id "${TARGET_ADMIN}" 2>&1 || true
echo -n "  id ${TARGET_ADMIN}@${TARGET_DOMAIN}: "
id "${TARGET_ADMIN}@${TARGET_DOMAIN}" 2>&1 || true

# ------------------------------------------------------------------------------
# Post-Diagnostics Application Policy Sync
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}[POST-DIAGNOSTICS] Enforcing Application & System Policies...${NC}"
if [ -x "${CONF_DIR}/refresh-app-policies.sh" ]; then
  msg_info "Executing policy engine '${CONF_DIR}/refresh-app-policies.sh'..."
  "${CONF_DIR}/refresh-app-policies.sh" 2>&1 || true
  msg_ok "Application policy enforcement complete."
else
  msg_warn "Policy script not found at '${CONF_DIR}/refresh-app-policies.sh'."
fi

echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Installation steps complete successfully!                            ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"