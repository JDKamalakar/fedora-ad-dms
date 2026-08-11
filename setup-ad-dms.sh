#!/usr/bin/env bash
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

# Step 1: Remove LibreOffice / Install ONLYOFFICE (Optional Prompt)
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
if ask_yes_no "Remove LibreOffice and install ONLYOFFICE?" "Y"; then
  dnf remove -y "libreoffice*" || true
  dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm || true
  dnf install -y onlyoffice-desktopeditors || true
  msg_ok "ONLYOFFICE installed successfully."
else
  msg_info "Skipping ONLYOFFICE software swap."
fi

# Step 2: System Update
step_header "2" "Updating System Packages"
if ask_yes_no "Run full system update ('dnf update')?" "Y"; then
  dnf update -y
fi

# Step 3: Install AD Prerequisites
step_header "3" "Installing AD & Security Dependencies"
dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit

# Step 4: Install Dank Material Shell (DMS) via Native Script
step_header "4" "Installing Dank Material Shell (DMS)"
msg_info "Executing native DMS installer..."
curl -fsSL https://install.danklinux.com | sh || true
msg_ok "DMS native installation executed."

# Step 5: Read Domain Settings
step_header "5" "Active Directory Configuration"
if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
  msg_ok "Loaded configuration from 'domain.conf'."
fi

# NetworkManager DNS
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "${DOMAIN_NAME:-gsfcu.local}" ipv4.ignore-auto-dns yes || true
  nmcli connection up "$TARGET_CONN" || true
fi

systemctl enable --now chronyd || true
chronyc makestep > /dev/null 2>&1 || true

echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${DOMAIN_USER:-Administrator}@${DOMAIN_NAME:-gsfcu.local}': "
read -sp "" DOMAIN_PASS < /dev/tty
echo ""

# Step 6: Realm Join
step_header "6" "Joining Active Directory Realm"
if echo "$DOMAIN_PASS" | realm join --user="${DOMAIN_USER:-Administrator}" "${DOMAIN_NAME:-gsfcu.local}" --verbose; then
  msg_ok "Joined Active Directory realm successfully."
else
  msg_err "Failed to join domain."
  exit 1
fi

# Step 7: Interactive Lab Access Selection
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
    realm permit -g "$ALLOWED_ID" || true

    # Explicitly block other lab IDs listed in lab.conf
    for key in "${!LAB_IDS[@]}"; do
      if [ "$key" -ne "$CHOICE" ]; then
        DENY_ID="${LAB_IDS[$key]}"
        realm deny -g "$DENY_ID" || true
        msg_warn "Blocked Lab ID on this machine: ${DENY_ID}"
      fi
    done
    
    msg_ok "Unlisted domain IDs remain allowed."
  fi
fi

# Step 8: Setup Refresh Script, Auto-installer, and Systemd Timer
step_header "8" "Setting Up 10-Minute Policy Refresh Service"

cp "${SCRIPT_DIR}/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies
chmod 755 /usr/local/bin/refresh-app-policies

# Create 'refresh' terminal alias/command
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
systemctl enable --now app-policy-sync.timer
/usr/local/bin/refresh-app-policies || true

# Step 9: System Configs
step_header "9" "Applying System Configurations"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
  chmod 600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf
fi

# Step 10: PAM Integration
step_header "10" "Configuring PAM & Home Directories"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd

# Step 11: Configure DMS Profile for New Domain Users (/etc/skel)
step_header "11" "Applying DMS Themes for New Users (/etc/skel)"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  msg_ok "DMS profile unpacked into /etc/skel."
fi

# Step 12: Restart Services
step_header "12" "Finalizing Installation"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 || true
setsebool -P nis_enabled 1 || true
setsebool -P use_nfs_home_dirs 1 || true

sss_cache -E || true
rm -f /var/lib/sss/db/* || true
systemctl restart sssd oddjobd greetd || true

echo -e "${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Setup complete! Lab access selected and auto-refresh activated.    ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"