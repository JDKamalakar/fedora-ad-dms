#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/fedora-ad-setup.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
  esac
done

# Ensure root privilege
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)."
  exit 1
fi

# Ensure Whiptail (newt) is installed for full-screen TUI buffer
if ! command -v whiptail &> /dev/null; then
  echo "Installing 'newt' package for Whiptail full-screen TUI..."
  dnf install -y newt > /dev/null 2>&1
fi

# Reset log file
echo "=== Active Directory & DMS Installation Log ===" > "$LOG_FILE"
echo "Date: $(date)" >> "$LOG_FILE"

# Set global backtitle for consistent installer branding
export NEWT_COLORS='
root=,blue
window=,lightgray
border=black,lightgray
textbox=black,lightgray
button=black,cyan
'

# --- 1. FULL-SCREEN WELCOME & CONFIRMATION ---

if [ "$ASSUME_YES" = false ]; then
  whiptail --backtitle "Fedora Workstation Deployment System" \
    --title " Active Directory & DMS Setup Wizard " \
    --msgbox "Welcome to the Fedora AD & DMS Deployment Setup.\n\nThis wizard will configure:\n  • Active Directory Domain Authentication\n  • Hostname-based Lab Access Rules\n  • Software Management Policies & Timers\n  • Dank Material Shell (DMS) Desktop Environment" 14 68

  if ! whiptail --backtitle "Fedora Workstation Deployment System" \
    --title " Confirmation Required " \
    --yesno "Are you sure you want to deploy AD & DMS on this machine?" 10 60; then
    exit 0
  fi
fi

# --- 2. CONFIGURATION PROMPTS ---

DOMAIN_NAME="gsfcu.local"
REALM_NAME="GSFCU.LOCAL"
AD_DNS_IP=""
DOMAIN_USER="Administrator"

if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
fi

if [ "$ASSUME_YES" = false ]; then
  DOMAIN_NAME=$(whiptail --backtitle "Fedora Workstation Deployment System" --title " Domain Configuration (1/4) " --inputbox "Enter Active Directory Domain Name:" 10 60 "$DOMAIN_NAME" 3>&1 1>&2 2>&3)
  AD_DNS_IP=$(whiptail --backtitle "Fedora Workstation Deployment System" --title " Domain Configuration (2/4) " --inputbox "Enter Active Directory DNS Server IP Address:" 10 60 "$AD_DNS_IP" 3>&1 1>&2 2>&3)
  DOMAIN_USER=$(whiptail --backtitle "Fedora Workstation Deployment System" --title " Domain Configuration (3/4) " --inputbox "Enter Domain Admin Username:" 10 60 "$DOMAIN_USER" 3>&1 1>&2 2>&3)
  DOMAIN_PASS=$(whiptail --backtitle "Fedora Workstation Deployment System" --title " Domain Configuration (4/4) " --passwordbox "Enter Password for '${DOMAIN_USER}@${DOMAIN_NAME}':" 10 65 3>&1 1>&2 2>&3)
else
  if [ -z "${DOMAIN_PASS:-}" ]; then
    echo -n "Enter Domain Admin Password for '${DOMAIN_USER}@${DOMAIN_NAME}': "
    read -sp "" DOMAIN_PASS
    echo ""
  fi
fi

# --- 3. DYNAMIC HOSTNAME LAB DETECTION ---

SELECTED_LAB_ID=""
LAB_CONF="${SCRIPT_DIR}/lab.conf"
declare -A LAB_NAME_MAP

if [ -f "$LAB_CONF" ]; then
  LAB_MENU_ARGS=()
  
  CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || echo "$HOSTNAME")"
  HOST_UPPER="$(echo "$CURRENT_HOSTNAME" | tr '[:lower:]' '[:upper:]')"
  
  AUTO_MATCHED_ID=""
  AUTO_MATCHED_NAME=""

  while IFS=':' read -r name id pattern || [ -n "$name" ]; do
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$name" ]] && continue
    
    name="$(echo "$name" | xargs)"
    id="$(echo "$id" | xargs)"
    pattern="$(echo "${pattern:-}" | xargs)"

    LAB_MENU_ARGS+=("$id" "$name")
    LAB_NAME_MAP["$id"]="$name"

    if [ -n "$pattern" ]; then
      PATTERN_UPPER="$(echo "$pattern" | tr '[:lower:]' '[:upper:]')"
      if [[ "$HOST_UPPER" == *"$PATTERN_UPPER"* ]]; then
        AUTO_MATCHED_ID="$id"
        AUTO_MATCHED_NAME="$name"
      fi
    fi
  done < "$LAB_CONF"

  if [ "${#LAB_MENU_ARGS[@]}" -gt 0 ]; then
    if [ "$ASSUME_YES" = false ]; then
      
      WHIPTAIL_OPTS=(whiptail --backtitle "Fedora Workstation Deployment System" --title " Lab Access Assignment ")
      
      if [ -n "$AUTO_MATCHED_ID" ]; then
        WHIPTAIL_OPTS+=(--default-item "$AUTO_MATCHED_ID")
        PROMPT_MSG="Detected Hostname: ${CURRENT_HOSTNAME}\nMatched Lab Pattern: ${AUTO_MATCHED_NAME} (${AUTO_MATCHED_ID})\n\nConfirm or select the primary Lab ID allowed on this host:"
      else
        PROMPT_MSG="Detected Hostname: ${CURRENT_HOSTNAME}\n(No matching pattern in lab.conf)\n\nSelect the primary Lab ID allowed on this host:"
      fi

      SELECTED_LAB_ID=$("${WHIPTAIL_OPTS[@]}" \
        --menu "$PROMPT_MSG" 18 72 6 \
        "${LAB_MENU_ARGS[@]}" \
        3>&1 1>&2 2>&3)
    else
      SELECTED_LAB_ID="${AUTO_MATCHED_ID:-${LAB_MENU_ARGS[0]}}"
    fi
  fi
fi

# --- EXPORT VARIABLES FOR WORKER FUNCTIONS ---

export LOG_FILE SCRIPT_DIR DOMAIN_NAME REALM_NAME AD_DNS_IP DOMAIN_USER DOMAIN_PASS SELECTED_LAB_ID

# --- TASK EXECUTION FUNCTIONS ---

do_software_swap() {
  echo "--- Removing LibreOffice & Installing ONLYOFFICE ---" >> "$LOG_FILE"
  dnf remove -y "libreoffice*" >> "$LOG_FILE" 2>&1 || true
  dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm >> "$LOG_FILE" 2>&1 || true
  dnf install -y onlyoffice-desktopeditors >> "$LOG_FILE" 2>&1 || true
}

do_system_update() {
  echo "--- Updating System Packages ---" >> "$LOG_FILE"
  dnf update -y >> "$LOG_FILE" 2>&1
}

do_install_deps() {
  echo "--- Installing Active Directory Dependencies ---" >> "$LOG_FILE"
  dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit >> "$LOG_FILE" 2>&1
}

do_install_dms() {
  echo "--- Installing Dank Material Shell (DMS) ---" >> "$LOG_FILE"
  curl -fsSL https://install.danklinux.com -o /tmp/dms-install.sh >> "$LOG_FILE" 2>&1
  chmod 777 /tmp/dms-install.sh
  
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    sudo -u "$REAL_USER" bash /tmp/dms-install.sh >> "$LOG_FILE" 2>&1 || true
  else
    bash /tmp/dms-install.sh >> "$LOG_FILE" 2>&1 || true
  fi
  rm -f /tmp/dms-install.sh
}

do_network_dns() {
  echo "--- Configuring NetworkManager DNS & Time Sync ---" >> "$LOG_FILE"
  ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active | grep ethernet | head -n1 | cut -d: -f1 || true)
  TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

  if [ -n "${AD_DNS_IP:-}" ]; then
    nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$DOMAIN_NAME" ipv4.ignore-auto-dns yes >> "$LOG_FILE" 2>&1 || true
    nmcli connection up "$TARGET_CONN" >> "$LOG_FILE" 2>&1 || true
  fi

  systemctl enable --now chronyd >> "$LOG_FILE" 2>&1 || true
  chronyc makestep >> "$LOG_FILE" 2>&1 || true
}

do_realm_join() {
  echo "--- Joining Active Directory Domain (${DOMAIN_NAME}) ---" >> "$LOG_FILE"
  if ! echo "$DOMAIN_PASS" | realm join --user="$DOMAIN_USER" "$DOMAIN_NAME" --verbose >> "$LOG_FILE" 2>&1; then
    echo "ERROR: Realm join failed." >> "$LOG_FILE"
    return 1
  fi
}

do_lab_access_controls() {
  echo "--- Applying Lab Access Control Rules ---" >> "$LOG_FILE"
  if [ -n "$SELECTED_LAB_ID" ]; then
    realm permit -g "$SELECTED_LAB_ID" >> "$LOG_FILE" 2>&1 || true
    
    if [ -f "$LAB_CONF" ]; then
      while IFS=':' read -r name id pattern || [ -n "$id" ]; do
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        id="$(echo "$id" | xargs)"
        if [ -n "$id" ] && [ "$id" != "$SELECTED_LAB_ID" ]; then
          realm deny -g "$id" >> "$LOG_FILE" 2>&1 || true
        fi
      done < "$LAB_CONF"
    fi
  fi
}

do_policy_sync_setup() {
  echo "--- Installing Policy Refresh Timer & PAM Hooks ---" >> "$LOG_FILE"
  cp "${SCRIPT_DIR}/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies
  chmod 755 /usr/local/bin/refresh-app-policies

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

  systemctl daemon-reload >> "$LOG_FILE" 2>&1
  systemctl enable --now app-policy-sync.timer >> "$LOG_FILE" 2>&1

  if ! grep -q "refresh-app-policies" /etc/pam.d/postlogin 2>/dev/null; then
    echo "session optional pam_exec.so type=open_session /usr/local/bin/refresh-app-policies" >> /etc/pam.d/postlogin
  fi

  /usr/local/bin/refresh-app-policies >> "$LOG_FILE" 2>&1 || true
}

do_finalize_configs() {
  echo "--- Finalizing System & Theme Inheritance (/etc/skel) ---" >> "$LOG_FILE"
  if [ -d "${SCRIPT_DIR}/configs" ]; then
    [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
    [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
    [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
    chmod 600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf
  fi

  authselect select sssd with-mkhomedir --force >> "$LOG_FILE" 2>&1
  systemctl enable --now oddjobd >> "$LOG_FILE" 2>&1

  THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"
  if [ -f "$THEME_ARCHIVE" ]; then
    mkdir -p /etc/skel/.config /etc/skel/.local/share
    tar -xzf "$THEME_ARCHIVE" -C /etc/skel
    chmod -R 755 /etc/skel/.config /etc/skel/.local
  fi

  mkdir -p /var/cache/dms-greeter
  chmod 777 /var/cache/dms-greeter
  setsebool -P allow_polyinstantiation 1 >> "$LOG_FILE" 2>&1 || true
  setsebool -P nis_enabled 1 >> "$LOG_FILE" 2>&1 || true
  setsebool -P use_nfs_home_dirs 1 >> "$LOG_FILE" 2>&1 || true

  sss_cache -E >> "$LOG_FILE" 2>&1 || true
  rm -f /var/lib/sss/db/* >> "$LOG_FILE" 2>&1 || true
  systemctl restart sssd oddjobd greetd >> "$LOG_FILE" 2>&1 || true
}

# Export functions so subshell loops can execute them safely
export -f do_software_swap do_system_update do_install_deps do_install_dms do_network_dns do_realm_join do_lab_access_controls do_policy_sync_setup do_finalize_configs

# --- 4. FULL-SCREEN PROGRESS BAR EXECUTION LOOP ---

run_step() {
  local pct="$1"
  local text="$2"
  local fn="$3"
  echo "$pct"
  echo "XXX"
  echo "$text"
  echo "XXX"
  "$fn"
}

export -f run_step

(
  run_step 10 "1/8: Swapping LibreOffice for ONLYOFFICE..." do_software_swap
  run_step 25 "2/8: Updating System Packages..." do_system_update
  run_step 40 "3/8: Installing Active Directory Dependencies..." do_install_deps
  run_step 55 "4/8: Installing Dank Material Shell (DMS)..." do_install_dms
  run_step 65 "5/8: Configuring AD DNS & Network Clock Sync..." do_network_dns
  run_step 75 "6/8: Joining Active Directory Realm..." do_realm_join
  run_step 85 "7/8: Applying Lab Access Control Rules..." do_lab_access_controls
  run_step 92 "8/8: Setting Up Policy Refresh & PAM Hooks..." do_policy_sync_setup
  run_step 100 "Complete: Finalizing Desktop Themes & Services..." do_finalize_configs
) | whiptail --backtitle "Fedora Workstation Deployment System" \
             --title " Installation Progress " \
             --gauge "Initializing deployment process..." 8 70 0

# --- 5. FULL-SCREEN COMPLETION & LOG VIEWER ---

whiptail --backtitle "Fedora Workstation Deployment System" \
  --title " Setup Complete " \
  --msgbox "Installation completed successfully!\n\nPress OK to view the complete scrollable deployment log." 12 65

whiptail --backtitle "Fedora Workstation Deployment System" \
  --title " Deployment Log Viewer (Use Arrow Keys / PgUp / PgDn to scroll) " \
  --textbox "$LOG_FILE" 22 80
