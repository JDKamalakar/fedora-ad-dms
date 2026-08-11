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

# Ensure Root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)."
  exit 1
fi

# Ensure Whiptail (newt package) is installed
if ! command -v whiptail &> /dev/null; then
  echo "Installing 'newt' package for Whiptail TUI..."
  dnf install -y newt > /dev/null 2>&1
fi

# Reset log file
echo "=== Active Directory & DMS Installation Log ===" > "$LOG_FILE"
echo "Date: $(date)" >> "$LOG_FILE"

# --- TUI CONFIGURATION INTERACTION ---

if [ "$ASSUME_YES" = false ]; then
  whiptail --title "Fedora AD & DMS Setup Wizard" \
    --msgbox "Welcome to the Fedora Active Directory & DMS Deployment Setup.\n\nThis wizard will configure system settings, domain authentication, lab access rules, and desktop environments." 12 68

  if ! whiptail --title "Confirmation" --yesno "Do you want to proceed with setup on this machine?" 10 60; then
    exit 0
  fi
fi

# Load domain.conf if available
DOMAIN_NAME="gsfcu.local"
REALM_NAME="GSFCU.LOCAL"
AD_DNS_IP=""
DOMAIN_USER="Administrator"

if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
fi

if [ "$ASSUME_YES" = false ]; then
  [ -z "${DOMAIN_NAME:-}" ] && DOMAIN_NAME=$(whiptail --title "Domain Configuration" --inputbox "Enter Active Directory Domain Name:" 10 60 "gsfcu.local" 3>&1 1>&2 2>&3)
  [ -z "${AD_DNS_IP:-}" ] && AD_DNS_IP=$(whiptail --title "Domain Configuration" --inputbox "Enter Active Directory DNS Server IP Address:" 10 60 "" 3>&1 1>&2 2>&3)
  [ -z "${DOMAIN_USER:-}" ] && DOMAIN_USER=$(whiptail --title "Domain Configuration" --inputbox "Enter Domain Admin Username:" 10 60 "Administrator" 3>&1 1>&2 2>&3)
  
  DOMAIN_PASS=$(whiptail --title "Authentication Required" --passwordbox "Enter Domain Admin Password for '${DOMAIN_USER}@${DOMAIN_NAME}':" 10 65 3>&1 1>&2 2>&3)
else
  if [ -z "${DOMAIN_PASS:-}" ]; then
    echo -n "Enter Domain Admin Password for '${DOMAIN_USER}@${DOMAIN_NAME}': "
    read -sp "" DOMAIN_PASS
    echo ""
  fi
fi

# --- DYNAMIC HOSTNAME AUTO-DETLECTION & LAB SELECTION ---

SELECTED_LAB_ID=""
LAB_CONF="${SCRIPT_DIR}/lab.conf"

if [ -f "$LAB_CONF" ]; then
  LAB_MENU_ARGS=()
  declare -A LAB_NAME_MAP
  
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

    # Match Hostname against 3rd column pattern in lab.conf
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
      
      # Build Whiptail menu with auto-detected default item highlight
      WHIPTAIL_OPTS=(whiptail --title "Lab Access Control Selection")
      
      if [ -n "$AUTO_MATCHED_ID" ]; then
        WHIPTAIL_OPTS+=(--default-item "$AUTO_MATCHED_ID")
        PROMPT_MSG="Detected Hostname: ${CURRENT_HOSTNAME}\nAuto-Matched Lab: ${AUTO_MATCHED_NAME} (${AUTO_MATCHED_ID})\n\nConfirm or change the allowed Lab ID for this machine:"
      else
        PROMPT_MSG="Detected Hostname: ${CURRENT_HOSTNAME}\n(No specific pattern match found in lab.conf)\n\nSelect the primary Lab ID allowed on this workstation:"
      fi

      SELECTED_LAB_ID=$("${WHIPTAIL_OPTS[@]}" \
        --menu "$PROMPT_MSG" 19 74 6 \
        "${LAB_MENU_ARGS[@]}" \
        3>&1 1>&2 2>&3)
    else
      # In unattended mode, use auto-matched ID or fall back to first entry
      SELECTED_LAB_ID="${AUTO_MATCHED_ID:-${LAB_MENU_ARGS[0]}}"
    fi
  fi
fi

# --- EXECUTION FUNCTIONS (Piped into Log File) ---

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
  echo "--- Installing Active Directory & Security Dependencies ---" >> "$LOG_FILE"
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
    
    # Explicitly block other lab IDs listed in lab.conf
    for key in "${!LAB_NAME_MAP[@]}"; do
      if [ "$key" != "$SELECTED_LAB_ID" ]; then
        realm deny -g "$key" >> "$LOG_FILE" 2>&1 || true
        echo "Denied group: $key" >> "$LOG_FILE"
      fi
    done
  fi
}

do_policy_sync_setup() {
  echo "--- Installing 10-Minute Policy Refresh Timer ---" >> "$LOG_FILE"
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

# --- TUI PROGRESS BAR EXECUTION LOOP ---

run_step() {
  local pct="$1"
  local text="$2"
  shift 2
  echo "$pct"
  echo "XXX"
  echo "$text"
  echo "XXX"
  "$@"
}

(
  run_step 10 "1/8: Swapping LibreOffice for ONLYOFFICE..." do_software_swap
  run_step 25 "2/8: Updating System Packages..." do_system_update
  run_step 40 "3/8: Installing Active Directory Dependencies..." do_install_deps
  run_step 55 "4/8: Installing Dank Material Shell (DMS)..." do_install_dms
  run_step 65 "5/8: Configuring AD DNS & Network Clock Sync..." do_network_dns
  run_step 75 "6/8: Joining Active Directory Realm..." do_realm_join
  run_step 85 "7/8: Applying Lab Access Control Rules..." do_lab_access_controls
  run_step 92 "8/8: Setting Up 10-Min Policy Sync Timer..." do_policy_sync_setup
  run_step 100 "Complete: Finalizing Desktop Themes & Services..." do_finalize_configs
) | whiptail --title "Fedora AD & DMS Setup Progress" --gauge "Initializing installation..." 8 70 0

# --- POST-INSTALLATION LOG SCROLLBACK SCREEN ---

whiptail --title "Installation Complete" \
  --msgbox "Setup completed successfully!\n\nSelect OK to open the full scrollable terminal log viewer." 12 65

whiptail --title "Execution Output Log (Use Arrow Keys / PgUp / PgDn to Scroll)" \
  --textbox "$LOG_FILE" 22 80