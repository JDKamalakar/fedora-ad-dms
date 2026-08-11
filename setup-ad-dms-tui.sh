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

# Step 1: Remove LibreOffice / Install ONLYOFFICE (Compulsory)
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
msg_info "Removing LibreOffice and installing ONLYOFFICE (Compulsory)..."
dnf remove -y "libreoffice*" || true
dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm || true
dnf install -y onlyoffice-desktopeditors || true
msg_ok "ONLYOFFICE installation complete."

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
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  msg_info "Executing native DMS installer as user '${SUDO_USER}'..."
  sudo -u "$SUDO_USER" bash -c "curl -fsSL https://install.danklinux.com | sh" || true
else
  msg_info "Executing native DMS installer..."
  curl -fsSL https://install.danklinux.com | sh || true
fi
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

# Step 6: Realm Join (With Retry Loop and Offline Fallback)
step_header "6" "Joining Active Directory Realm"

while true; do
  echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${DOMAIN_USER:-Administrator}@${DOMAIN_NAME:-gsfcu.local}': "
  read -sp "" DOMAIN_PASS < /dev/tty
  echo ""

  if echo "$DOMAIN_PASS" | realm join --user="${DOMAIN_USER:-Administrator}" "${DOMAIN_NAME:-gsfcu.local}" --verbose; then
    msg_ok "Joined Active Directory realm successfully."
    break
  else
    msg_warn "Could not join domain (Domain Controller unreachable or authentication failed)."
    
    if [ "$ASSUME_YES" = true ]; then
      msg_warn "Auto-continuing in Offline/Testing mode due to -y flag..."
      break
    fi

    if ask_yes_no "Would you like to retry Domain Join?" "N"; then
      msg_info "Retrying domain authentication..."
      continue
    else
      if ask_yes_no "Continue setup in Offline/Testing mode?" "Y"; then
        msg_warn "Proceeding with local policy setup, scripts, and theme configuration..."
        break
      else
        msg_err "Aborting installation."
        exit 1
      fi
    fi
  fi
done

# Step 7: Auto-detect and Configure Lab Access Rules
step_header "7" "Configuring Lab Access Control Rules"

LAB_CONF="${SCRIPT_DIR}/lab.conf"
if [ -f "$LAB_CONF" ]; then
  LAB_ENTRIES=()
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(echo "$line" | xargs)
    [[ -z "$trimmed" || "$trimmed" =~ ^# ]] && continue
    LAB_ENTRIES+=("$trimmed")
  done < "$LAB_CONF"
  
  if [ "${#LAB_ENTRIES[@]}" -gt 0 ]; then
    SYS_HOSTNAME=$(hostname -s 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo "")
    AUTO_DETECTED_INDEX=""
    
    idx=1
    declare -A LAB_NAMES
    declare -A LAB_IDS
    
    echo -e "  ${BOLD}Available Lab Configurations:${NC}\n"
    for entry in "${LAB_ENTRIES[@]}"; do
      IFS=':' read -r name id <<< "$entry"
      LAB_NAMES[$idx]="$name"
      LAB_IDS[$idx]="$id"
      
      # Match against system hostname (e.g. GSFCUOSLAB001 matches OSLAB or OS)
      CLEAN_NAME=$(echo "$name" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      CLEAN_ID=$(echo "$id" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      
      if [ -n "$SYS_HOSTNAME" ]; then
        if [[ "$SYS_HOSTNAME" == *"$CLEAN_NAME"* ]] || [[ "$SYS_HOSTNAME" == *"$CLEAN_ID"* ]]; then
          AUTO_DETECTED_INDEX="$idx"
        fi
      fi
      
      echo -e "    ${CYAN}[$idx]${NC} ${name} (${YELLOW}ID: ${id}${NC})"
      ((idx++))
    done

    CHOICE="$SELECTED_LAB_INDEX"
    
    # Auto-detection prompt
    if [ -z "$CHOICE" ] && [ -n "$AUTO_DETECTED_INDEX" ]; then
      msg_ok "Auto-detected Lab from Hostname ('${SYS_HOSTNAME}'): ${LAB_NAMES[$AUTO_DETECTED_INDEX]}"
      if ask_yes_no "Use auto-detected lab selection [${LAB_NAMES[$AUTO_DETECTED_INDEX]}]?" "Y"; then
        CHOICE="$AUTO_DETECTED_INDEX"
      fi
    fi

    # Fallback to manual selection if auto-detect wasn't chosen or available
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

    # Permit selected lab ID (warns if offline)
    realm permit -g "$ALLOWED_ID" 2>/dev/null || msg_warn "Skipped 'realm permit' (machine offline/not joined)."

    # Explicitly block other lab IDs listed in lab.conf
    for key in "${!LAB_IDS[@]}"; do
      if [ "$key" -ne "$CHOICE" ]; then
        DENY_ID="${LAB_IDS[$key]}"
        realm deny -g "$DENY_ID" 2>/dev/null || true
        msg_warn "Recorded block rule for Lab ID: ${DENY_ID}"
      fi
    done
    
    msg_ok "Unlisted domain IDs remain allowed."
  fi
fi

# Step 8: Setup Policy Folder, Refresh Script, Auto-installer, and Systemd Timer
step_header "8" "Syncing App Configs & Setting Up 10-Minute Policy Service"

mkdir -p /etc/fedora-ad-dms
for conf_file in compulsory-apps.conf group-apps.conf allowed-apps.conf blocked-apps.conf domain.conf lab.conf; do
  if [ -f "${SCRIPT_DIR}/${conf_file}" ]; then
    cp "${SCRIPT_DIR}/${conf_file}" /etc/fedora-ad-dms/
    msg_ok "Copied ${conf_file} -> /etc/fedora-ad-dms/"
  fi
done

cp "${SCRIPT_DIR}/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies
chmod 755 /usr/local/bin/refresh-app-policies

# Terminal command helper
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

# Step 11: Configure DMS Profile for ALL Users
step_header "11" "Applying DMS Themes for New & Existing Users"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  # 1. Apply to /etc/skel (For ALL Future/New Users)
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  msg_ok "DMS profile unpacked into /etc/skel (for new users)."

  # 2. Apply to ALL Existing User Home Directories (/home/*)
  for user_home in /home/*; do
    if [ -d "$user_home" ]; then
      owner=$(stat -c '%U' "$user_home" 2>/dev/null || true)
      group=$(stat -c '%G' "$user_home" 2>/dev/null || true)
      
      if [ -n "$owner" ] && [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ]; then
        msg_info "Applying DMS theme profile to existing user home: $user_home ($owner)"
        mkdir -p "$user_home/.config" "$user_home/.local/share"
        tar -xzf "$THEME_ARCHIVE" -C "$user_home" || true
        chown -R "$owner:$group" "$user_home/.config" "$user_home/.local" || true
      fi
    fi
  done
  msg_ok "DMS themes applied to all existing user profiles."
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
echo -e "${GREEN}|${NC} ${BOLD}Setup complete! Offline rules tested & auto-refresh activated.    ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"