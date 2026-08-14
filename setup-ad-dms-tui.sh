#!/usr/bin/env bash

# Script Versioning (Incremented to 1.0.4)
SCRIPT_VERSION="1.0.4"

# Auto-re-execute with Bash if launched via 'sh' or another shell
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -eu

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
UPDATE_SYSTEM="" # Empty = prompt, true = force update, false = force skip

# --- CONFIGURATION DEFAULTS ---
PVPN_ENABLE="${PVPN_ENABLE:-yes}"
PVPN_ID="${PVPN_ID:-gsfcu@proton.me}"
PVPN_PASS="${PVPN_PASS:-Test@1199}"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    --lab-index=*) SELECTED_LAB_INDEX="${arg#*=}" ;;
    --update|--update-system) UPDATE_SYSTEM=true ;;
    --no-update|--skip-update) UPDATE_SYSTEM=false ;;
  esac
done

draw_banner() {
  printf "%b+--------------------------------------------------------------------+%b\n" "$CYAN" "$NC"
  printf "%b|%b %b%b FEDORA ACTIVE DIRECTORY & DMS SETUP v%-8s%b            %b|%b\n" "$CYAN" "$NC" "$BOLD" "$MAGENTA" "$SCRIPT_VERSION" "$NC" "$CYAN" "$NC"
  printf "%b+--------------------------------------------------------------------+%b\n\n" "$CYAN" "$NC"
}

step_header() {
  step_num="${1:-1}"
  step_title="${2:-}"
  printf "\n%b%b[STEP %s/11]%b %b%s%b\n" "$BOLD" "$BLUE" "$step_num" "$NC" "$BOLD" "$step_title" "$NC"
  printf "%b======================================================================%b\n" "$BLUE" "$NC"
}

msg_info()  { printf "  %b[INFO]%b %s\n" "$CYAN" "$NC" "$1"; }
msg_ok()    { printf "  %b[OK]%b %s\n" "$GREEN" "$NC" "$1"; }
msg_warn()  { printf "  %b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
msg_err()   { printf "  %b[ERROR]%b %s\n" "$RED" "$NC" "$1"; }

ask_yes_no() {
  prompt="$1"
  default="${2:-Y}"
  hint="[Y/n]"

  case "$default" in
    [Nn]*) hint="[y/N]" ;;
  esac

  if [ "$ASSUME_YES" = true ]; then
    case "$default" in
      [Nn]*)
        msg_info "${prompt} -> Auto-skipped (-y flag default N)"
        return 1
        ;;
      *)
        msg_info "${prompt} -> Auto-approved (-y flag)"
        return 0
        ;;
    esac
  fi

  while true; do
    printf "  %b[PROMPT]%b %s %s: " "$YELLOW" "$NC" "$prompt" "$hint"
    read -r resp < /dev/tty || resp=""
    if [ -z "$resp" ]; then
      resp="$default"
    fi
    case "$resp" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) msg_err "Invalid input. Please enter 'y' or 'n'." ;;
    esac
  done
}

EUID_VAL=$(id -u 2>/dev/null || echo 0)
if [ "$EUID_VAL" -ne 0 ]; then
  draw_banner
  msg_err "This script requires administrative privileges. Run with 'sudo'."
  exit 1
fi

draw_banner
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "$PWD")"
case "$SCRIPT_DIR" in
  /dev*) SCRIPT_DIR="$PWD" ;;
esac

# Load domain configuration accurately
load_domain_conf() {
  DOMAIN_CONF_FILE=""

  if [ -f "${SCRIPT_DIR}/dominos.config" ]; then
    DOMAIN_CONF_FILE="${SCRIPT_DIR}/dominos.config"
  elif [ -f "${SCRIPT_DIR}/domain.conf" ]; then
    DOMAIN_CONF_FILE="${SCRIPT_DIR}/domain.conf"
  elif [ -f "${SCRIPT_DIR}/configs/domain.conf" ]; then
    DOMAIN_CONF_FILE="${SCRIPT_DIR}/configs/domain.conf"
  elif [ -f "./dominos.config" ]; then
    DOMAIN_CONF_FILE="./dominos.config"
  elif [ -f "./domain.conf" ]; then
    DOMAIN_CONF_FILE="./domain.conf"
  elif [ -f "/etc/fedora-ad-dms/domain.conf" ]; then
    DOMAIN_CONF_FILE="/etc/fedora-ad-dms/domain.conf"
  fi

  if [ -n "$DOMAIN_CONF_FILE" ] && [ -f "$DOMAIN_CONF_FILE" ]; then
    sed -i 's/\r$//' "$DOMAIN_CONF_FILE" 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$DOMAIN_CONF_FILE" 2>/dev/null || . "$DOMAIN_CONF_FILE" 2>/dev/null || true
  fi

  # Variable fallbacks & strict formatting (Kerberos Realm MUST be UPPERCASE)
  DOMAIN_NAME=$(echo "${DOMAIN_NAME:-${REALM_NAME:-gsfcu.local}}" | tr '[:upper:]' '[:lower:]')
  REALM_NAME=$(echo "${REALM_NAME:-${REALM:-$DOMAIN_NAME}}" | tr '[:lower:]' '[:upper:]')
  DOMAIN_USER="${DOMAIN_USER:-${DOMAIN_ADMIN:-${ADMIN_USER:-Administrator}}}"
  AD_DNS_IP="${AD_DNS_IP:-}"
}

load_domain_conf

# --- STEP 1: PROTON VPN SETUP ---
setup_pvpn() {
  step_header "1" "ProtonVPN (pVPN) Integration"
  
  run_pvpn=false
  PVPN_ENABLE_LOWER=$(echo "${PVPN_ENABLE:-yes}" | tr '[:upper:]' '[:lower:]')
  
  case "$PVPN_ENABLE_LOWER" in
    "yes") run_pvpn=true ;;
    "no")
      msg_info "pVPN disabled in domain.conf. Skipping installation & connection entirely."
      return 0
      ;;
    "ask")
      if ask_yes_no "Do you want to install and connect ProtonVPN (pVPN)?" "Y"; then
        run_pvpn=true
      else
        msg_info "pVPN installation denied by user. Skipping entirely."
        return 0
      fi
      ;;
    *)
      msg_warn "Unknown PVPN_ENABLE setting '${PVPN_ENABLE}'. Skipping pVPN."
      return 0
      ;;
  esac

  if [ "$run_pvpn" = true ]; then
    if command -v pvpnctl >/dev/null 2>&1; then
      msg_ok "pVPN CLI (pvpnctl) is already installed. Skipping installation."
    else
      msg_info "Installing system-wide pVPN CLI..."
      curl -fsSL https://raw.githubusercontent.com/YourDoritos/pVPN/main/install.sh | bash

      if ! command -v pvpnctl >/dev/null 2>&1; then
        msg_err "pvpnctl binary not found. Installation failed."
        exit 1
      fi
    fi

    msg_info "Checking current pVPN connection status..."
    if pvpnctl status 2>/dev/null | grep -iq "connected"; then
      msg_ok "pVPN is already connected! Skipping login and connection steps."
      return 0
    fi

    msg_info "Logging into pVPN..."
    pvpnctl login "$PVPN_ID" "$PVPN_PASS"

    msg_info "Connecting pVPN..."
    pvpnctl connect

    msg_info "Verifying pVPN connection status..."
    attempts=0
    max_attempts=10
    is_connected=false

    while [ "$attempts" -lt "$max_attempts" ]; do
      if pvpnctl status 2>/dev/null | grep -iq "connected"; then
        is_connected=true
        break
      fi
      attempts=$((attempts + 1))
      msg_info "Waiting for active pVPN connection... ($attempts/$max_attempts)"
      sleep 3
    done

    if [ "$is_connected" = true ]; then
      msg_ok "pVPN is connected! Proceeding with setup..."
    else
      msg_err "pVPN failed to connect after multiple checks. Cannot proceed."
      exit 1
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
run_update=false

msg_info "Checking for available system updates..."
CHECK_UPD_EXIT=0
dnf check-update --quiet >/dev/null 2>&1 || CHECK_UPD_EXIT=$?

if [ "$CHECK_UPD_EXIT" -eq 100 ]; then
  msg_info "System updates are available."
  if [ "$UPDATE_SYSTEM" = true ]; then
    run_update=true
    msg_info "System update explicitly requested via CLI flag."
  elif [ "$UPDATE_SYSTEM" = false ]; then
    run_update=false
    msg_info "System update explicitly skipped via CLI flag."
  else
    if ask_yes_no "Updates are available. Do you want to run a full system update ('dnf update')?" "N"; then
      run_update=true
    fi
  fi
else
  msg_ok "No updates available. System is already up to date."
  run_update=false
fi

if [ "$run_update" = true ]; then
  msg_info "Running full system update..."
  dnf update -y --setopt=strict=0 || msg_warn "System update completed with mirror warnings."
else
  msg_info "Skipping system update."
fi

# --- STEP 4: AD DEPENDENCIES ---
step_header "4" "Installing AD & Security Dependencies"
REQUIRED_PKGS="realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit kitty dnf-plugins-core"
MISSING_PKGS=""

for pkg in $REQUIRED_PKGS; do
  if ! rpm -q "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS="$MISSING_PKGS $pkg"
  fi
done

MISSING_CLEAN=$(echo "$MISSING_PKGS" | xargs || true)
if [ -z "$MISSING_CLEAN" ]; then
  msg_ok "All required AD & security packages are already installed!"
else
  msg_info "Installing missing packages: $MISSING_CLEAN"
  dnf install -y --setopt=strict=0 $MISSING_CLEAN || msg_warn "Some packages encountered download warnings."
fi

# --- STEP 5: DMS INSTALLATION ---
step_header "5" "Installing Dank Material Shell (DMS)"

DMS_USER="${SUDO_USER:-}"
if [ -z "$DMS_USER" ] || [ "$DMS_USER" = "root" ]; then
  DMS_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd || true)
fi

if [ -n "$DMS_USER" ] && id "$DMS_USER" >/dev/null 2>&1; then
  if command -v dms >/dev/null 2>&1 || rpm -q dms >/dev/null 2>&1 || [ -f "/usr/bin/dms" ] || [ -f "/usr/local/bin/dms" ] || [ -f "/home/${DMS_USER}/.local/bin/dms" ]; then
    msg_ok "Dank Material Shell (DMS) is already installed. Skipping installer script."
  else
    msg_info "Executing DMS installer script as non-root user '$DMS_USER'..."
    if sudo -u "$DMS_USER" -H sh -c "curl -fsSL https://install.danklinux.com | sh"; then
      msg_ok "DMS installer script executed successfully."
    else
      msg_err "DMS installer script failed."
      exit 1
    fi
  fi
else
  msg_err "No non-root user found to execute the DMS installer script. Exiting."
  exit 1
fi

# --- STEP 6: DOMAIN SETTINGS & REALM JOIN ---
step_header "6" "Active Directory Configuration & Realm Join"

# Ensure domain configuration is loaded
load_domain_conf

# Pre-execution Inspection Display
printf "\n  %b%b+--------------------------------------------------------------------+%b\n" "$BOLD" "$CYAN" "$NC"
printf "  %b%b|              DOMAIN CONFIGURATION DETECTION SUMMARY                 |%b\n" "$BOLD" "$CYAN" "$NC"
printf "  %b%b+--------------------------------------------------------------------+%b\n" "$BOLD" "$CYAN" "$NC"

if [ -n "${DOMAIN_CONF_FILE:-}" ] && [ -f "$DOMAIN_CONF_FILE" ]; then
  msg_ok "Config File Status  : FOUND (${DOMAIN_CONF_FILE})"
else
  msg_warn "Config File Status  : NOT FOUND (Using built-in defaults)"
fi

msg_info "Domain Name (DNS)   : '${DOMAIN_NAME}'"
msg_info "Realm Name (KRB)    : '${REALM_NAME}'"
msg_info "Domain Admin User   : '${DOMAIN_USER}'"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_ok "AD DNS Server IP    : '${AD_DNS_IP}'"
else
  msg_warn "AD DNS Server IP    : NOT SPECIFIED (Relying on existing network DNS)"
fi

printf "  %b+--------------------------------------------------------------------+%b\n\n" "$CYAN" "$NC"

# Apply Persistent NetworkManager DNS & Search Domain
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep -E 'ethernet|802-3-ethernet|wireless|lan' | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  msg_info "Applying AD DNS (${AD_DNS_IP}) & Search Domain (${DOMAIN_NAME}) to '${TARGET_CONN}'..."
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$DOMAIN_NAME" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  # Direct write to /etc/resolv.conf for immediate resolution fallback
  cat <<EOF > /etc/resolv.conf
nameserver ${AD_DNS_IP}
search ${DOMAIN_NAME}
EOF
  msg_ok "NetworkManager DNS and Search Domain configured."
fi

# Time Synchronization (Mandatory for Active Directory Kerberos)
msg_info "Synchronizing system clock with network time..."
systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true

# Check if machine is already joined to domain
if realm list 2>/dev/null | grep -iq "$DOMAIN_NAME"; then
  msg_ok "System is already joined to realm '$DOMAIN_NAME'. Skipping domain join."
else
  while true; do
    if [ "$ASSUME_YES" = true ]; then
      DOMAIN_PASS_EXEC="${DOMAIN_PASS:-}"
    else
      printf "  %b[INPUT]%b Enter Domain Admin Password for '%s@%s': " "$YELLOW" "$NC" "$DOMAIN_USER" "$REALM_NAME"
      read -s -r DOMAIN_PASS_EXEC < /dev/tty || DOMAIN_PASS_EXEC=""
      printf "\n"
    fi

    msg_info "Enrolling system into Active Directory realm '${REALM_NAME}'..."
    if echo "$DOMAIN_PASS_EXEC" | realm join --user="$DOMAIN_USER" "$REALM_NAME" --verbose; then
      msg_ok "Successfully joined Active Directory realm '${REALM_NAME}'!"
      
      # Auto-tune SSSD for short username logins & home directories
      if [ -f /etc/sssd/sssd.conf ]; then
        sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf 2>/dev/null || true
        sed -i 's/fallback_homedir = .*/fallback_homedir = \/home\/%u@%d/' /etc/sssd/sssd.conf 2>/dev/null || true
        chmod 600 /etc/sssd/sssd.conf
      fi
      break
    else
      msg_warn "Could not join Active Directory domain."
      
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
fi

# --- STEP 7: LAB ACCESS CONTROL RULES ---
step_header "7" "Configuring Lab Access Control Rules"
LAB_CONF="${SCRIPT_DIR}/lab.conf"
if [ -f "$LAB_CONF" ]; then
  sed -i 's/\r$//' "$LAB_CONF" 2>/dev/null || true
  CLEAN_LABS=$(grep -v -E '^\s*#|^\s*$' "$LAB_CONF" 2>/dev/null | xargs -L1 || true)
  
  if [ -n "$CLEAN_LABS" ]; then
    SYS_HOSTNAME=$(hostname -s 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo "")
    AUTO_DETECTED_INDEX=""
    
    idx=1
    printf "  %bAvailable Lab Configurations:%b\n\n" "$BOLD" "$NC"
    
    printf "%s\n" "$CLEAN_LABS" | while IFS= read -r line; do
      if [ -z "$line" ]; then continue; fi
      
      case "$line" in
        *:*)
          lab_name_raw="${line%%:*}"
          lab_id_raw="${line#*:}"
          ;;
        *)
          lab_name_raw="$line"
          lab_id_raw="$line"
          ;;
      esac

      name=$(echo "$lab_name_raw" | xargs || true)
      id=$(echo "$lab_id_raw" | tr -cd 'a-zA-Z0-9_-')

      CLEAN_NAME=$(echo "$name" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      CLEAN_ID=$(echo "$id" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      
      if [ -n "$SYS_HOSTNAME" ]; then
        case "$SYS_HOSTNAME" in
          *"$CLEAN_NAME"*|*"$CLEAN_ID"*)
            AUTO_DETECTED_INDEX="$idx"
            ;;
        esac
      fi
      
      formatted_idx=$(printf "%02d" "$idx")
      printf "    %b[%s]%b %s\n" "$CYAN" "$formatted_idx" "$NC" "$name"
      idx=$((idx + 1))
    done

    total_labs=$(printf "%s\n" "$CLEAN_LABS" | grep -c . || echo 1)
    CHOICE="$SELECTED_LAB_INDEX"
    
    if [ -z "$CHOICE" ] && [ -n "$AUTO_DETECTED_INDEX" ]; then
      DETECTED_LINE=$(printf "%s\n" "$CLEAN_LABS" | sed -n "${AUTO_DETECTED_INDEX}p")
      DETECTED_NAME=$(echo "${DETECTED_LINE%%:*}" | xargs || true)
      msg_ok "Auto-detected Lab from Hostname ('${SYS_HOSTNAME}'): ${DETECTED_NAME}"
      if ask_yes_no "Use auto-detected lab selection [${DETECTED_NAME}]?" "Y"; then
        CHOICE="$AUTO_DETECTED_INDEX"
      fi
    fi

    if [ -z "$CHOICE" ]; then
      if [ "$ASSUME_YES" = true ]; then
        CHOICE=1
      else
        while true; do
          printf "\n  %b[INPUT]%b Select Lab number [1-%s]: " "$YELLOW" "$NC" "$total_labs"
          read -r RAW_CHOICE < /dev/tty || RAW_CHOICE=""
          CHOICE=$(echo "$RAW_CHOICE" | tr -cd '0-9' | sed 's/^0*//')
          CHOICE="${CHOICE:-0}"

          if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$total_labs" ]; then
            break
          fi
          msg_err "Invalid choice. Please enter a valid number."
        done
      fi
    fi

    curr_idx=1
    printf "%s\n" "$CLEAN_LABS" | while IFS= read -r line; do
      if [ -z "$line" ]; then continue; fi
      
      case "$line" in
        *:*)
          lab_name_raw="${line%%:*}"
          lab_id_raw="${line#*:}"
          ;;
        *)
          lab_name_raw="$line"
          lab_id_raw="$line"
          ;;
      esac
      
      name=$(echo "$lab_name_raw" | xargs || true)
      id=$(echo "$lab_id_raw" | tr -cd 'a-zA-Z0-9_-')

      if [ "$curr_idx" -eq "$CHOICE" ]; then
        msg_ok "Selected Lab: ${name} (${id})"
        realm permit -g "$id" 2>/dev/null || msg_warn "Skipped 'realm permit'."
      else
        realm deny -g "$id" 2>/dev/null || true
        msg_warn "Recorded block rule for Lab ID: ${id}"
      fi
      curr_idx=$((curr_idx + 1))
    done
    
    msg_ok "Unlisted domain IDs remain allowed."
  fi
fi

# --- STEP 8: SYNC CONFIGS & TIMER SERVICE ---
step_header "8" "Syncing App Configs & Setting Up Policy Service"
mkdir -p /etc/fedora-ad-dms
for conf_file in compulsory-apps.conf group-apps.conf allowed-apps.conf blocked-apps.conf domain.conf dominos.config lab.conf; do
  if [ -f "${SCRIPT_DIR}/${conf_file}" ]; then
    cp "${SCRIPT_DIR}/${conf_file}" /etc/fedora-ad-dms/
    msg_ok "Copied ${conf_file} -> /etc/fedora-ad-dms/"
  fi
done

if [ -f /etc/fedora-ad-dms/domain.conf ]; then
  chmod 600 /etc/fedora-ad-dms/domain.conf 2>/dev/null || true
fi
if [ -f /etc/fedora-ad-dms/dominos.config ]; then
  chmod 600 /etc/fedora-ad-dms/dominos.config 2>/dev/null || true
fi

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

# --- STEP 9: SYSTEM CONFIGS & PAM ---
step_header "9" "Applying System Configurations & PAM Rules"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  # Only copy static sssd.conf if domain join failed or if realmd didn't create one
  if [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && [ ! -s /etc/sssd/sssd.conf ]; then
    cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  fi
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
fi

if [ -f /etc/sssd/sssd.conf ]; then
  chmod 600 /etc/sssd/sssd.conf
  chown root:root /etc/sssd/sssd.conf
fi

authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd 2>/dev/null || true

# --- STEP 10: DMS & KITTY CONF SETUP ---
step_header "10" "Deploying Theme & Mandatory Kitty Terminal Configuration"

msg_info "Creating compulsory Kitty configuration..."
mkdir -p /etc/skel/.config/kitty

cat <<'EOF' > /etc/skel/.config/kitty/kitty.conf
# ==============================================================================
# MANDATORY KITTY TERMINAL QOL CONFIGURATION
# ==============================================================================
font_size 11.0
scrollback_lines 10000
mouse_hide_wait 3.0
copy_on_select yes
enable_audio_bell no
remember_window_size yes
confirm_os_window_close 0

# Copy & Paste Shortcuts
map ctrl+shift+c copy_to_clipboard
map ctrl+shift+v paste_from_clipboard
map ctrl+c copy_or_interrupt
map ctrl+v paste_from_clipboard
EOF
chmod -R 755 /etc/skel/.config/kitty
msg_ok "Compulsory Kitty config populated in /etc/skel/.config/kitty/kitty.conf"

for user_home in /home/*; do
  if [ -d "$user_home" ]; then
    owner=$(stat -c '%U' "$user_home" 2>/dev/null || true)
    group=$(stat -c '%G' "$user_home" 2>/dev/null || true)
    
    if [ -n "$owner" ] && [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ] && id "$owner" >/dev/null 2>&1; then
      mkdir -p "$user_home/.config/kitty"
      cp /etc/skel/.config/kitty/kitty.conf "$user_home/.config/kitty/kitty.conf"
      chown -R "$owner:$group" "$user_home/.config/kitty"
      msg_ok "Synced Kitty QOL config to user home: $user_home"
    fi
  fi
done

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

# --- STEP 11: FINALIZE SERVICES ---
step_header "11" "Finalizing Installation"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true

# Safely stop SSSD before resetting database
systemctl stop sssd 2>/dev/null || true
sss_cache -E 2>/dev/null || true
rm -f /var/lib/sss/db/* 2>/dev/null || true
systemctl restart sssd oddjobd greetd 2>/dev/null || true

printf "%b+--------------------------------------------------------------------+%b\n" "$GREEN" "$NC"
printf "%b|%b %bSetup complete! Pre-baked DMS, Kitty & pVPN deployment ready.     %b %b|%b\n" "$GREEN" "$NC" "$BOLD" "$NC" "$GREEN" "$NC"
printf "%b+--------------------------------------------------------------------+%b\n\n" "$GREEN" "$NC"
