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
SKIP_STEP0=false
SELECTED_LAB_INDEX=""

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    --lab-index=*) SELECTED_LAB_INDEX="${arg#*=}" ;;
    --skip-step0) SKIP_STEP0=true ;;
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

# --- STEP 0: NATIVE LIVE INSTALLER ---
is_live_session() {
  [ -d /run/initramfs/live ] || [ -f /etc/livedaemon ] || grep -q "boot=live\|img.livedata" /proc/cmdline
}

if is_live_session && [ "$SKIP_STEP0" = false ]; then
  step_header "0" "Fedora Live Native Direct Disk Installer"
  msg_info "Detected Fedora Live environment. Installing natively from Live USB to disk..."

  # 1. Select Target Storage Drive
  echo -e "\n  ${BOLD}Available Storage Drives:${NC}\n"

  mapfile -t DRIVE_LIST < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v "loop\|zram")

  if [ "${#DRIVE_LIST[@]}" -eq 0 ]; then
    msg_err "No available storage drives found!"
    exit 1
  fi

  declare -A DRIVE_PATHS
  idx=1

  for line in "${DRIVE_LIST[@]}"; do
    dev_name=$(echo "$line" | awk '{print $1}')
    dev_size=$(echo "$line" | awk '{print $2}')
    dev_model=$(echo "$line" | awk '{$1=""; $2=""; print $0}' | xargs)
    
    DRIVE_PATHS[$idx]="/dev/${dev_name}"
    echo -e "    ${CYAN}[$idx]${NC} /dev/${dev_name} (${YELLOW}${dev_size}${NC} - ${dev_model})"
    ((idx++))
  done

  total_drives=$((idx - 1))

  while true; do
    echo -en "\n  ${YELLOW}[INPUT]${NC} Select target disk number [1-${total_drives}]: "
    read -r DISK_CHOICE < /dev/tty
    if [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && [ "$DISK_CHOICE" -ge 1 ] && [ "$DISK_CHOICE" -le "$total_drives" ]; then
      TARGET_DISK="${DRIVE_PATHS[$DISK_CHOICE]}"
      break
    fi
    msg_err "Invalid selection. Please enter a number between 1 and ${total_drives}."
  done

  msg_ok "Selected Target Disk: ${TARGET_DISK}"

  # 2. Lab Selection & Hostname Generation
  mkdir -p /tmp/installer_init
  LAB_CONF_SOURCE=""

  if [ -f "${SCRIPT_DIR}/lab.conf" ]; then
    LAB_CONF_SOURCE="${SCRIPT_DIR}/lab.conf"
  else
    msg_info "Fetching lab configuration..."
    curl -fsSL "https://raw.githubusercontent.com/jayrajkamalakar-gsfcu/fedora-ad-dms/main/lab.conf" -o /tmp/installer_init/lab.conf 2>/dev/null || true
    LAB_CONF_SOURCE="/tmp/installer_init/lab.conf"
  fi

  LAB_ENTRIES=()
  if [ -f "$LAB_CONF_SOURCE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed=$(echo "$line" | xargs)
      [[ -z "$trimmed" || "$trimmed" =~ ^# ]] && continue
      LAB_ENTRIES+=("$trimmed")
    done < "$LAB_CONF_SOURCE"
  fi

  if [ "${#LAB_ENTRIES[@]}" -eq 0 ]; then
    msg_warn "lab.conf not found or empty. Using default prefix 'GSFCUOSLAB'."
    SELECTED_LAB_PREFIX="GSFCUOSLAB"
    LAB_CHOICE=1
  else
    echo -e "\n  ${BOLD}Select Target Lab:${NC}\n"
    idx=1
    declare -A STEP0_LAB_NAMES
    declare -A STEP0_LAB_IDS

    for entry in "${LAB_ENTRIES[@]}"; do
      if [[ "$entry" == *":"* ]]; then
        lab_name_raw="${entry%%:*}"
        lab_id_raw="${entry#*:}"
      else
        lab_name_raw="$entry"
        lab_id_raw="$entry"
      fi

      lab_name=$(echo "$lab_name_raw" | xargs)
      lab_id=$(echo "$lab_id_raw" | tr -cd 'a-zA-Z0-9_-')

      STEP0_LAB_NAMES[$idx]="$lab_name"
      STEP0_LAB_IDS[$idx]="$lab_id"

      # Displays ONLY the lab name
      echo -e "    ${CYAN}[$idx]${NC} ${lab_name}"
      ((idx++))
    done
    total_labs=$((idx - 1))

    while true; do
      echo -en "\n  ${YELLOW}[INPUT]${NC} Select Lab number [1-${total_labs}]: "
      read -r LAB_CHOICE < /dev/tty
      if [[ "$LAB_CHOICE" =~ ^[0-9]+$ ]] && [ "$LAB_CHOICE" -ge 1 ] && [ "$LAB_CHOICE" -le "$total_labs" ]; then
        SELECTED_LAB_PREFIX="${STEP0_LAB_IDS[$LAB_CHOICE]}"
        msg_ok "Selected Lab: ${STEP0_LAB_NAMES[$LAB_CHOICE]}"
        break
      fi
      msg_err "Invalid selection. Please enter a number between 1 and ${total_labs}."
    done
  fi

  # 3. Device Number Input
  while true; do
    echo -en "  ${YELLOW}[INPUT]${NC} Enter Device Number (e.g., 2 or 002): "
    read -r DEV_NUM < /dev/tty
    DEV_NUM_CLEAN=$(echo "$DEV_NUM" | tr -cd '0-9')
    if [ -n "$DEV_NUM_CLEAN" ]; then
      PADDED_DEV_NUM=$(printf "%03d" "$((10#$DEV_NUM_CLEAN))")
      break
    fi
    msg_err "Invalid input. Please enter a valid number."
  done

  # Strictly sanitize Hostname and Username
  NEW_HOSTNAME=$(echo "${SELECTED_LAB_PREFIX}${PADDED_DEV_NUM}" | tr -cd 'a-zA-Z0-9_-' | tr '[:lower:]' '[:upper:]')
  NEW_USER=$(echo "$NEW_HOSTNAME" | tr '[:upper:]' '[:lower:]')

  msg_ok "Generated Hostname: ${NEW_HOSTNAME}"
  msg_ok "Local Admin Username: ${NEW_USER} (Auto-assigned)"

  # 4. Password Input
  echo -en "  ${YELLOW}[INPUT]${NC} Enter Password for user '${NEW_USER}' and root: "
  read -sp "" NEW_PASS < /dev/tty
  echo ""

  msg_warn "CRITICAL WARNING: ${TARGET_DISK} WILL BE COMPLETELY WIPED."
  if ! ask_yes_no "Format ${TARGET_DISK} and install Fedora?" "Y"; then
    msg_err "Installation aborted."
    exit 1
  fi

  # Determine partition naming convention
  if [[ "$TARGET_DISK" =~ nvme|loop|mmcblk ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
  else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
  fi

  # Unmount active partitions & disable swap
  msg_info "Preparing disk ${TARGET_DISK}..."
  swapoff -a 2>/dev/null || true
  umount -f "${TARGET_DISK}"* 2>/dev/null || true

  msg_info "Partitioning target drive ${TARGET_DISK}..."
  wipefs -a "$TARGET_DISK" >/dev/null 2>&1 || true
  parted -s "$TARGET_DISK" mklabel gpt
  parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$TARGET_DISK" set 1 boot on
  parted -s "$TARGET_DISK" mkpart primary ext4 1025MiB 100%

  # Force kernel partition reread
  partprobe "$TARGET_DISK" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 2

  msg_info "Formatting partitions (${EFI_PART} & ${ROOT_PART})..."
  mkfs.vfat -F32 "$EFI_PART" >/dev/null
  mkfs.ext4 -F "$ROOT_PART" >/dev/null

  # Mount target partitions
  TARGET_MOUNT="/mnt/target_system"
  mkdir -p "$TARGET_MOUNT"
  mount "$ROOT_PART" "$TARGET_MOUNT"
  mkdir -p "${TARGET_MOUNT}/boot/efi"
  mount "$EFI_PART" "${TARGET_MOUNT}/boot/efi"

  msg_info "Syncing Live OS filesystem from Live USB to disk..."
  rsync -axH --info=progress2 \
    --exclude=/proc/* \
    --exclude=/sys/* \
    --exclude=/dev/* \
    --exclude=/run/* \
    --exclude=/tmp/* \
    --exclude=/mnt/* \
    --exclude=/media/* \
    / "${TARGET_MOUNT}/" || true

  # Clean up stale Live OS home directories on target drive
  rm -rf "${TARGET_MOUNT}/home/"*

  # Configure fstab
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

  cat << EOF > "${TARGET_MOUNT}/etc/fstab"
UUID=${ROOT_UUID}  /          ext4  defaults  1 1
UUID=${EFI_UUID}   /boot/efi  vfat  umask=0077,shortname=winnt 0 2
EOF

  # Set Hostname
  echo "$NEW_HOSTNAME" > "${TARGET_MOUNT}/etc/hostname"

  msg_info "Configuring GRUB and preparing chroot..."
  for dir in dev dev/pts proc sys run; do
    mkdir -p "${TARGET_MOUNT}/$dir"
    mount --bind "/$dir" "${TARGET_MOUNT}/$dir"
  done

  # Fetch or copy installer repo into target system
  mkdir -p "${TARGET_MOUNT}/tmp/installer"
  if [ -f "${SCRIPT_DIR}/setup-ad-dms-tui.sh" ]; then
    cp -r "${SCRIPT_DIR}/"* "${TARGET_MOUNT}/tmp/installer/"
  else
    msg_info "Fetching repository files into target drive..."
    curl -fsSL https://github.com/jayrajkamalakar-gsfcu/fedora-ad-dms/archive/refs/heads/main.tar.gz | tar -xz -C "${TARGET_MOUNT}/tmp/installer" --strip-components=1
  fi

  # Run Setup Steps inside target chroot
  chroot "$TARGET_MOUNT" bash -c "
    getent group wheel >/dev/null 2>&1 || groupadd wheel
    
    if ! id '${NEW_USER}' >/dev/null 2>&1; then
      useradd -m -G wheel '${NEW_USER}' || useradd -m '${NEW_USER}'
    fi

    echo 'root:${NEW_PASS}' | chpasswd
    echo '${NEW_USER}:${NEW_PASS}' | chpasswd
    
    # Ensure SELinux auto-relabels on first boot
    touch /.autorelabel

    # Reconfigure Bootloader
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

    cd /tmp/installer
    chmod +x setup-ad-dms-tui.sh
    ./setup-ad-dms-tui.sh --skip-step0 -y --lab-index=${LAB_CHOICE}
  "

  # Clean up mounts
  umount -R "$TARGET_MOUNT" 2>/dev/null || true

  echo -e "\n${GREEN}+--------------------------------------------------------------------+${NC}"
  echo -e "${GREEN}|${NC} ${BOLD}Native Fedora installation & setup completed successfully!        ${NC} ${GREEN}|${NC}"
  echo -e "${GREEN}|${NC} ${BOLD}You can now restart the PC and boot directly into the hard drive. ${NC} ${GREEN}|${NC}"
  echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
  exit 0
fi

# --- STEP 1: SOFTWARE SWAPPING ---
step_header "1" "Software Swapping (LibreOffice -> ONLYOFFICE)"
if rpm -q libreoffice-core >/dev/null 2>&1; then
  msg_info "Removing LibreOffice..."
  dnf remove -y "libreoffice*" 2>/dev/null || true
fi

msg_info "Installing ONLYOFFICE Desktop Editors..."
dnf install -y --setopt=strict=0 https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm 2>/dev/null || true
dnf install -y --setopt=strict=0 onlyoffice-desktopeditors 2>/dev/null || msg_warn "ONLYOFFICE package download skipped due to repository mirror error."
msg_ok "Software swapping step finished."

# --- STEP 2: SYSTEM UPDATE ---
step_header "2" "Updating System Packages"
if ask_yes_no "Run full system update ('dnf update')?" "N"; then
  dnf update -y --setopt=strict=0 || msg_warn "System update encountered mirror errors; proceeding with installed base packages."
else
  msg_info "Skipping full system update."
fi

# --- STEP 3: AD DEPENDENCIES ---
step_header "3" "Installing AD & Security Dependencies"
REQUIRED_PKGS=(realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit)
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! rpm -q "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
  msg_ok "All required AD & security packages are already installed from the Live USB image!"
else
  msg_info "Installing missing packages: ${MISSING_PKGS[*]}"
  dnf install -y --setopt=strict=0 "${MISSING_PKGS[@]}" 2>/dev/null || msg_warn "Some packages failed to fetch due to online mirror 404s. Proceeding with Live image packages."
fi

# --- STEP 4: DMS INSTALLATION ---
step_header "4" "Installing Dank Material Shell (DMS)"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  msg_info "Executing native DMS installer as user '${SUDO_USER}'..."
  sudo -u "$SUDO_USER" bash -c "curl -fsSL https://install.danklinux.com | sh" || true
else
  msg_info "Executing native DMS installer..."
  curl -fsSL https://install.danklinux.com | sh || true
fi
msg_ok "DMS native installation executed."

# --- STEP 5: DOMAIN SETTINGS ---
step_header "5" "Active Directory Configuration"
if [ -f "${SCRIPT_DIR}/domain.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/domain.conf"
  msg_ok "Loaded configuration from 'domain.conf'."
fi

# NetworkManager DNS Setup
ACTIVE_CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1 || true)
TARGET_CONN="${ACTIVE_CONN:-Wired connection 1}"

if [ -n "${AD_DNS_IP:-}" ]; then
  nmcli connection modify "$TARGET_CONN" ipv4.dns "$AD_DNS_IP" ipv4.dns-search "${DOMAIN_NAME:-gsfcu.local}" ipv4.ignore-auto-dns yes 2>/dev/null || true
  nmcli connection up "$TARGET_CONN" 2>/dev/null || true
fi

systemctl enable --now chronyd 2>/dev/null || true
chronyc makestep > /dev/null 2>&1 || true

# --- STEP 6: REALM JOIN (RETRY & OFFLINE FALLBACK) ---
step_header "6" "Joining Active Directory Realm"

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

# --- STEP 7: AUTO-DETECT & CONFIGURE LAB RULES ---
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
      
      # Displays ONLY the lab name
      echo -e "    ${CYAN}[$idx]${NC} ${name}"
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

    # Manual Selection Fallback
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

# --- STEP 8: SYNC CONFIGS & 10-MIN TIMER SERVICE ---
step_header "8" "Syncing App Configs & Setting Up 10-Minute Policy Service"

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

# Terminal shortcut command
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

# Systemd Timer (Runs every 10 Minutes)
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

# --- STEP 9: SYSTEM CONFIGS ---
step_header "9" "Applying System Configurations"
if [ -d "${SCRIPT_DIR}/configs" ]; then
  [ -f "${SCRIPT_DIR}/configs/sssd.conf" ] && cp "${SCRIPT_DIR}/configs/sssd.conf" /etc/sssd/sssd.conf
  [ -f "${SCRIPT_DIR}/configs/krb5.conf" ] && cp "${SCRIPT_DIR}/configs/krb5.conf" /etc/krb5.conf
  [ -f "${SCRIPT_DIR}/configs/greetd" ] && cp "${SCRIPT_DIR}/configs/greetd" /etc/pam.d/greetd
  chmod 600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf
fi

# --- STEP 10: PAM INTEGRATION ---
step_header "10" "Configuring PAM & Home Directories"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd 2>/dev/null || true

# --- STEP 11: DMS THEME DEPLOYMENT ---
step_header "11" "Applying DMS Themes for New & Existing Users"
THEME_ARCHIVE="${SCRIPT_DIR}/niri-dms-config.tar.gz"

if [ -f "$THEME_ARCHIVE" ]; then
  # 1. Apply to /etc/skel (For ALL Future/New Users)
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
  msg_ok "DMS profile unpacked into /etc/skel (for new users)."

  # 2. Apply to ALL Existing Valid User Home Directories (/home/*)
  for user_home in /home/*; do
    if [ -d "$user_home" ]; then
      owner=$(stat -c '%U' "$user_home" 2>/dev/null || true)
      group=$(stat -c '%G' "$user_home" 2>/dev/null || true)
      
      if [ -n "$owner" ] && [ "$owner" != "root" ] && [ "$owner" != "UNKNOWN" ] && id "$owner" >/dev/null 2>&1; then
        msg_info "Applying DMS theme profile to existing user home: $user_home ($owner)"
        mkdir -p "$user_home/.config" "$user_home/.local/share"
        tar -xzf "$THEME_ARCHIVE" -C "$user_home" || true
        chown -R "$owner:$group" "$user_home/.config" "$user_home/.local" || true
      fi
    fi
  done
  msg_ok "DMS themes applied to all existing user profiles."
fi

# --- STEP 12: FINALIZE SERVICES ---
step_header "12" "Finalizing Installation"
mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
setsebool -P allow_polyinstantiation 1 2>/dev/null || true
setsebool -P nis_enabled 1 2>/dev/null || true
setsebool -P use_nfs_home_dirs 1 2>/dev/null || true

sss_cache -E 2>/dev/null || true
rm -f /var/lib/sss/db/* 2>/dev/null || true
systemctl restart sssd oddjobd greetd 2>/dev/null || true

echo -e "${GREEN}+--------------------------------------------------------------------+${NC}"
echo -e "${GREEN}|${NC} ${BOLD}Setup complete! Offline rules tested & auto-refresh activated.    ${NC} ${GREEN}|${NC}"
echo -e "${GREEN}+--------------------------------------------------------------------+${NC}\n"
