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

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)."
  exit 1
fi

# Auto-download modern 'gum' TUI engine if missing
if ! command -v gum &> /dev/null; then
  echo "Fetching modern TUI engine (gum)..."
  curl -fsSL https://github.com/charmbracelet/gum/releases/download/v0.13.0/gum_0.13.0_Linux_x86_64.tar.gz -o /tmp/gum.tar.gz
  tar -xzf /tmp/gum.tar.gz -C /tmp
  mv /tmp/gum_0.13.0_Linux_x86_64/gum /usr/local/bin/gum
  chmod +x /usr/local/bin/gum
  rm -rf /tmp/gum*
fi

echo "=== Active Directory & DMS Installation Log ===" > "$LOG_FILE"
echo "Date: $(date)" >> "$LOG_FILE"

# --- MODERN BANNER & CONFIRMATION ---

gum style \
  --foreground 212 --border-foreground 99 --border rounded \
  --margin "1 1" --padding "1 2" \
  "Fedora Active Directory & DMS Deployment Setup Wizard" \
  "" \
  "Configures AD Domain Join, Lab Access Controls, and DMS Theme Settings."

if [ "$ASSUME_YES" = false ]; then
  if ! gum confirm "Do you want to proceed with setup on this machine?"; then
    echo "Setup cancelled."
    exit 0
  fi
fi

# Load domain.conf
DOMAIN_NAME="gsfcu.local"
REALM_NAME="GSFCU.LOCAL"
AD_DNS_IP=""
DOMAIN_USER="Administrator"

if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
fi

if [ "$ASSUME_YES" = false ]; then
  [ -z "${DOMAIN_NAME:-}" ] && DOMAIN_NAME=$(gum input --value "gsfcu.local" --placeholder "Domain Name")
  [ -z "${AD_DNS_IP:-}" ] && AD_DNS_IP=$(gum input --placeholder "AD DNS Server IP (e.g., 192.168.1.10)")
  [ -z "${DOMAIN_USER:-}" ] && DOMAIN_USER=$(gum input --value "Administrator" --placeholder "Domain Admin Username")
  
  DOMAIN_PASS=$(gum input --password --placeholder "Enter Domain Admin Password for '${DOMAIN_USER}@${DOMAIN_NAME}'")
else
  if [ -z "${DOMAIN_PASS:-}" ]; then
    echo -n "Enter Domain Admin Password for '${DOMAIN_USER}@${DOMAIN_NAME}': "
    read -sp "" DOMAIN_PASS
    echo ""
  fi
fi

# --- HOSTNAME AUTO-DETECTION & LAB SELECTION ---

SELECTED_LAB_ID=""
LAB_CONF="${SCRIPT_DIR}/lab.conf"

if [ -f "$LAB_CONF" ]; then
  LAB_OPTIONS=()
  declare -A LAB_NAME_MAP
  declare -A LAB_ID_LOOKUP
  
  CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || echo "$HOSTNAME")"
  HOST_UPPER="$(echo "$CURRENT_HOSTNAME" | tr '[:lower:]' '[:upper:]')"
  
  AUTO_MATCHED_ID=""

  while IFS=':' read -r name id pattern || [ -n "$name" ]; do
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$name" ]] && continue
    
    name="$(echo "$name" | xargs)"
    id="$(echo "$id" | xargs)"
    pattern="$(echo "${pattern:-}" | xargs)"

    DISPLAY_LABEL="${name} (${id})"
    LAB_OPTIONS+=("$DISPLAY_LABEL")
    LAB_NAME_MAP["$id"]="$name"
    LAB_ID_LOOKUP["$DISPLAY_LABEL"]="$id"

    if [ -n "$pattern" ]; then
      PATTERN_UPPER="$(echo "$pattern" | tr '[:lower:]' '[:upper:]')"
      if [[ "$HOST_UPPER" == *"$PATTERN_UPPER"* ]]; then
        AUTO_MATCHED_ID="$id"
      fi
    fi
  done < "$LAB_CONF"

  if [ "${#LAB_OPTIONS[@]}" -gt 0 ]; then
    if [ "$ASSUME_YES" = false ]; then
      echo ""
      gum style --foreground 212 "Host Detected: ${CURRENT_HOSTNAME}"
      
      SELECTED_LABEL=$(gum choose \
        --header "Select the Primary Allowed Lab ID for this workstation:" \
        --cursor.foreground "212" \
        "${LAB_OPTIONS[@]}")
      
      SELECTED_LAB_ID="${LAB_ID_LOOKUP["$SELECTED_LABEL"]}"
    else
      SELECTED_LAB_ID="${AUTO_MATCHED_ID:-${LAB_ID_LOOKUP["${LAB_OPTIONS[0]}"]}}"
    fi
  fi
fi

# --- EXECUTION FUNCTIONS ---

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
    
    for key in "${!LAB_NAME_MAP[@]}"; do
      if [ "$key" != "$SELECTED_LAB_ID" ]; then
        realm deny -g "$key" >> "$LOG_FILE" 2>&1 || true
      fi
    done
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

# --- ANIMATED SPINNER EXECUTION PIPELINE ---

echo ""
gum style --foreground 212 "Executing Setup Tasks..."

gum spin --spinner dot --title "1/8: Swapping LibreOffice for ONLYOFFICE..." -- bash -c "do_software_swap"
gum spin --spinner dot --title "2/8: Updating System Packages..." -- bash -c "do_system_update"
gum spin --spinner dot --title "3/8: Installing Active Directory Dependencies..." -- bash -c "do_install_deps"
gum spin --spinner dot --title "4/8: Installing Dank Material Shell (DMS)..." -- bash -c "do_install_dms"
gum spin --spinner dot --title "5/8: Configuring AD DNS & Network Clock Sync..." -- bash -c "do_network_dns"
gum spin --spinner dot --title "6/8: Joining Active Directory Realm..." -- bash -c "do_realm_join"
gum spin --spinner dot --title "7/8: Applying Lab Access Control Rules..." -- bash -c "do_lab_access_controls"
gum spin --spinner dot --title "8/8: Setting Up Policy Refresh & PAM Hooks..." -- bash -c "do_policy_sync_setup"
gum spin --spinner dot --title "Complete: Finalizing Desktop Themes..." -- bash -c "do_finalize_configs"

echo ""
gum style \
  --foreground 82 --border-foreground 82 --border rounded \
  --padding "0 2" \
  "Installation Completed Successfully!"

echo ""
if gum confirm "Would you like to inspect the complete installation log now?"; then
  gum pager < "$LOG_FILE"
fi
