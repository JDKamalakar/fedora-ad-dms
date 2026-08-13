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

# --- CONFIGURATION DEFAULTS ---
PVPN_ENABLE="${PVPN_ENABLE:-yes}"
PVPN_ID="${PVPN_ID:-gsfcu@proton.me}"
PVPN_PASS="${PVPN_PASS:-Test@1199}"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    --lab-index=*) SELECTED_LAB_INDEX="${arg#*=}" ;;
  esac
done

draw_banner() {
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
  local hint="[Y/n]"

  if [[ "$default" =~ ^[Nn]$ ]]; then
    hint="[y/N]"
  fi

  if [ "$ASSUME_YES" = true ]; then
    if [[ "$default" =~ ^[Nn]$ ]]; then
      msg_info "${prompt} -> Auto-skipped (-y flag default N)"
      return 1
    else
      msg_info "${prompt} -> Auto-approved (-y flag)"
      return 0
    fi
  fi

  while true; do
    echo -en "  ${YELLOW}[PROMPT]${NC} ${prompt} ${hint}: "
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

if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
fi

# --- STEP 1: PROTON VPN SETUP ---
setup_pvpn() {
  step_header "1" "ProtonVPN (pVPN) Integration"
  
  local run_pvpn=false
  case "${PVPN_ENABLE,,}" in
    "yes") run_pvpn=true ;;
    "no")
      msg_info "pVPN installation disabled in configuration."
      return 0
      ;;
    "ask")
      if ask_yes_no "Do you want to install and connect ProtonVPN (pVPN)?" "Y"; then
        run_pvpn=true
      fi
      ;;
    *)
      msg_warn "Unknown PVPN_ENABLE setting '${PVPN_ENABLE}'. Skipping pVPN."
      return 0
      ;;
  esac

  if [ "$run_pvpn" = true ]; then
    msg_info "Installing pVPN daemon and CLI..."
    curl -fsSL https://raw.githubusercontent.com/YourDoritos/pVPN/main/install.sh | bash || msg_warn "pVPN installer notice."

    msg_info "Authenticating pVPN with '${PVPN_ID}'..."
    if command -v pvpnctl >/dev/null 2>&1; then
      pvpnctl login -u "$PVPN_ID" -p "$PVPN_PASS" 2>/dev/null || printf "%s\n%s\n" "$PVPN_ID" "$PVPN_PASS" | pvpnctl login 2>/dev/null || true
      pvpnctl connect fastest 2>/dev/null || pvpnctl connect 2>/dev/null || msg_warn "pVPN login attempted."
      msg_ok "pVPN setup complete."
    else
      msg_warn "pvpnctl binary not found in PATH."
    fi
  fi
}

setup_pvpn

# --- STEP 2: SOFTWARE SWAPPING ---
step_header "2" "Software Swapping (LibreOffice -> ONLYOFFICE)"
if rpm -q libreoffice-core >/dev/null 2>&1; then
  msg_info "Removing LibreOffice..."
  dnf remove -y "libreoffice*"
fi

msg_info "Installing ONLYOFFICE Desktop Editors..."
dnf install -y --setopt=strict=0 https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm || true
dnf install -y --setopt=strict=0 onlyoffice-desktopeditors || msg_warn "ONLYOFFICE installation encountered a repository warning."
msg_ok "Software swapping step finished."

# --- STEP 3: SYSTEM UPDATE ---
step_header "3" "Updating System Packages"
if ask_yes_no "Run full system update ('dnf update')?" "N"; then
  dnf update -y --setopt=strict=0 || msg_warn "System update completed with mirror warnings."
else
  msg_info "Skipping full system update."
fi

# --- STEP 4: AD DEPENDENCIES ---
step_header "4" "Installing AD & Security Dependencies"
REQUIRED_PKGS=(realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit)
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! rpm -q "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
  msg_ok "All required AD & security packages are already installed!"
else
  msg_info "Installing missing packages: ${MISSING_PKGS[*]}"
  dnf install -y --setopt=strict=0 "${MISSING_PKGS[@]}" || msg_warn "Some packages encountered download warnings."
fi

# --- STEP 5: INTERACTIVE DMS INSTALLATION ---
step_header "5" "Installing Dank Material Shell (DMS)"
DMS_TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1}' /etc/passwd | head -n1 || echo "")

if [ -n "$DMS_TARGET_USER" ]; then
  msg_info "Executing interactive DMS installer under user context '${DMS_TARGET_USER}'..."
  su - "$DMS_TARGET_USER" -c "curl -fsSL https://install.danklinux.com | sh" || msg_warn "DMS interactive installer finished with warnings."
else
  msg_info "Executing interactive DMS installer..."
  curl -fsSL https://install.danklinux.com | sh || msg_warn "DMS interactive installer finished with warnings."
fi
msg_ok "DMS installation process finished."

# --- STEP 6: DOMAIN SETTINGS ---
step_header "6" "Active Directory Configuration"
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "${DOMAIN_NAME:-gsfcu.local}" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
fi

systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true

# --- STEP 7: REALM JOIN ---
step_header "7" "Joining Active Directory Realm"
while true; do
  if [ "$ASSUME_YES" = true ]; then
    DOMAIN_PASS="${DOMAIN_PASS:-}"
  else
    echo -en "  ${YELLOW}[INPUT]${NC} Enter Domain Admin Password for '${DOMAIN_USER:-Administrator}@${DOMAIN_NAME:-gsfcu.local}': "
    read -sp "" DOMAIN_PASS < /dev/tty
    echo ""
  fi

  if echo "$DOMAIN_PASS" | realm join --user="${DOMAIN_USER:-Administrator}" "${DOMAIN_NAME:-gsfcu.local}" --verbose; then
    msg_ok "Joined Active Directory realm successfully."
    break
  else
    msg_warn "Could not join domain."
    
    if [ "$ASSUME_YES" = true ]; then
      msg_warn "Auto-continuing in Offline mode due to -y flag..."
      break
    fi

    if ask_yes_no "Would you like to retry Domain Join?" "N"; then
      msg_info "Retrying domain authentication..."
      continue
    else
      if ask_yes_no "Continue setup in Offline mode?" "Y"; then
        msg_warn "Proceeding with local policy setup..."
        break
      else
        msg_err "Aborting installation."
        exit 1
      fi
    fi
  fi
done

# --- STEP 8: AUTO-DETECT & CONFIGURE LAB RULES ---
step_header "8" "Configuring Lab Access Control Rules"
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
      if [[ "$entry" == *":"* ]]; then
        lab_name_raw="${entry%%:*}"
        lab_id_raw="${entry#*:}"
      else
        lab_name_raw="$entry"
        lab_id_raw="$entry"
      fi

      name=$(echo "$lab_name_raw" | xargs)
      id=$(echo "$lab_id_raw" | tr -cd 'a-zA-Z0-9_-')

      LAB_NAMES[$idx]="$name"
      LAB_IDS[$idx]="$id"
      
      CLEAN_NAME=$(echo "$name" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      CLEAN_ID=$(echo "$id" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      
      if [ -n "$SYS_HOSTNAME" ]; then
        if [[ "$SYS_HOSTNAME" == *"$CLEAN_NAME"* ]] || [[ "$SYS_HOSTNAME" == *"$CLEAN_ID"* ]]; then
          AUTO_DETECTED_INDEX="$idx"
        fi
      fi
      
      formatted_idx=$(printf "%02d" "$idx")
      echo -e "    ${CYAN}[${formatted_idx}]${NC} ${name}"
      ((idx++))
    done

    CHOICE="$SELECTED_LAB_INDEX"
    
    if [ -z "$CHOICE" ] && [ -n "$AUTO_DETECTED_INDEX" ]; then
      msg_ok "Auto-detected Lab from Hostname ('${SYS_HOSTNAME}'): ${LAB_NAMES[$AUTO_DETECTED_INDEX]}"
      if ask_yes_no "Use auto-detected lab selection [${LAB_NAMES[$AUTO_DETECTED_INDEX]}]?" "Y"; then
        CHOICE="$AUTO_DETECTED_INDEX"
      fi
    fi

    if [ -z "$CHOICE" ]; then
      if [ "$ASSUME_YES" = true ]; then
        CHOICE=1
      else
        while true; do
          echo -en "\n  ${YELLOW}[INPUT]${NC} Select Lab number [1-$((idx-1))]: "
          read -r RAW_CHOICE < /dev/tty
          CHOICE=$(echo "$RAW_CHOICE" | tr -cd '0-9' | sed 's/^0*//')
          CHOICE="${CHOICE:-0}"

          if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -lt "$idx" ]; then
            break
          fi
          msg_err "Invalid choice. Please enter a valid number."
        done
      fi
    fi

    ALLOWED_ID="${LAB_IDS[$CHOICE]}"
    ALLOWED_NAME="${LAB_NAMES[$CHOICE]}"
    
    msg_ok "Selected Lab: ${ALLOWED_NAME} (${ALLOWED_ID})"

    realm permit -g "$ALLOWED_ID" 2>/dev/null || msg_warn "Skipped 'realm permit'."

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

# --- STEP 9: SYNC CONFIGS & TIMER SERVICE ---
step_header "9" "Syncing App Configs & Setting Up Policy Service"
mkdir -p /etc/fedora-ad-dms
for conf_file in compulsory-apps.conf group-apps.conf allowed-apps.conf blocked-apps.conf domain.conf lab.conf; do
  if [ -f "${SCRIPT_DIR}/${conf_file}" ]; then
    cp "${SCRIPT_DIR}/${conf_file}" /etc/fedora-ad-dms/
    msg_ok "Copied ${conf_file} -> /etc/fedora-ad-dms/"
  fi
done

if [ -f "${SCRIPT_DIR}/refresh-app-policies.sh" ]; then
  cp "${SCRIPT_DIR}/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies
  chmod 755 /usr/local/bin/refresh-app-policies
fi

cat <<'EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
sudo /usr/local/bin/refresh-app-policies
EOF
chmod 755 /usr/local/bin/refresh

cat <<'EOF' > /etc/systemd/system/app-policy-sync.service
[Unit]
Description=Sync software allow/block lists & install compulsory apps
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh-app-policies
EOF

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

# --- STEP 10: SYSTEM CONFIGS ---
step_header "10" "Applying System Configurations"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
  chmod 600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf
fi

# --- STEP 11: PAM INTEGRATION ---
step_header "11" "Configuring PAM & Home Directories"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd 2>/dev/null || true

# --- STEP 12: DMS THEME & FINALIZE ---
step_header "12" "Deploying DMS Themes & Finalizing Setup"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  msg_ok "DMS profile unpacked into /etc/skel."

  for user_home in /home/*; do
    if [ -d "$user_home" ]; then
      owner=$(stat -c '%U' "$user_home" 2>/dev/null || true)
      group=$(stat -c '%G' "$user_home" 2>/dev/null || true)
      
      if [ -n "$owner" ] && [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ] && id "$owner" >/dev/null 2>&1; then
        msg_info "Deploying pre-configured DMS theme to: $user_home ($owner)"
        mkdir -p "$user_home/.config" "$user_home/.local/share"
        tar -xzf "$THEME_ARCHIVE" -C "$user_home" || true
        chown -R "$owner:$group" "$user_home/.config" "$user_home/.local" || true
      fi
    fi
  done
  msg_ok "Pre-configured DMS theme profiles applied."
fi

mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true

sss_cache -E 2>/dev/null || true
rm -f /var/lib/sss/db/* 2>/dev/null || true
systemctl restart sssd oddjobd greetd 2>/dev/null || true

echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Setup complete! Machine configured successfully.                  ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"