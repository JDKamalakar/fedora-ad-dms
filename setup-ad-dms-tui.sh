#!/usr/bin/env bash
set -e

LOG_FILE="/var/log/fedora-ad-setup.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: This script must be run as root (use sudo)."
  exit 1
fi

# Log output to both stdout and logfile
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================================="
echo "   Fedora AD & DMS Deployment Setup (Bash Engine)"
echo "   Started at: $(date)"
echo "=========================================================="
echo ""

# --- DEFAULTS & CONFIG LOADING ---
DOMAIN_NAME="gsfcu.local"
DOMAIN_USER="admin"
AD_DNS_IP=""
UPDATE_SYSTEM="y"

# Load domain.conf
DOMAIN_CONF_PATHS=(
  "$SCRIPT_DIR/domain.conf"
  "/etc/fedora-ad-dms/domain.conf"
)

for p in "${DOMAIN_CONF_PATHS[@]}"; do
  if [ -f "$p" ]; then
    echo "📄 Found domain config at: $p"
    source "$p" 2>/dev/null || true
    [ -n "$DOMAIN_NAME" ] && DOMAIN_NAME="$DOMAIN_NAME"
    [ -n "$AD_DNS_IP" ] && AD_DNS_IP="$AD_DNS_IP"
    [ -n "$DOMAIN_USER" ] && DOMAIN_USER="$DOMAIN_USER"
    break
  fi
done

# Load lab.conf & Auto-Detect Hostname Match
HOST_NAME="$(hostname | tr '[:lower:]' '[:upper:]')"
MATCHED_LAB=""
MATCHED_LAB_NAME=""

LAB_CONF_PATH="$SCRIPT_DIR/lab.conf"
declare -A LAB_MAP

if [ -f "$LAB_CONF_PATH" ]; then
  while IFS=':' read -r lab_name lab_id pattern; do
    # Trim whitespace & ignore comments
    lab_name=$(echo "$lab_name" | xargs)
    lab_id=$(echo "$lab_id" | xargs)
    pattern=$(echo "$pattern" | xargs)

    [[ -z "$lab_name" || "$lab_name" =~ ^# ]] && continue

    LAB_MAP["$lab_id"]="$lab_name"

    if [ -n "$pattern" ]; then
      pattern_upper=$(echo "$pattern" | tr '[:lower:]' '[:upper:]')
      if [[ "$HOST_NAME" == *"$pattern_upper"* ]]; then
        MATCHED_LAB="$lab_id"
        MATCHED_LAB_NAME="$lab_name"
      fi
    fi
  done < "$LAB_CONF_PATH"
fi

# --- PROMPT USER FOR INPUTS ---
echo "----------------------------------------------------------"
echo " ⚙️ Configuration Setup"
echo "----------------------------------------------------------"
echo "Host Name:     $(hostname)"
if [ -n "$MATCHED_LAB_NAME" ]; then
  echo "Matched Lab:   $MATCHED_LAB_NAME ($MATCHED_LAB)"
else
  echo "Matched Lab:   None detected"
fi
echo ""

read -rp "Domain Name [$DOMAIN_NAME]: " input_domain
DOMAIN_NAME="${input_domain:-$DOMAIN_NAME}"

read -rp "AD DNS IP [$AD_DNS_IP]: " input_dns
AD_DNS_IP="${input_dns:-$AD_DNS_IP}"

read -rp "Admin User [$DOMAIN_USER]: " input_user
DOMAIN_USER="${input_user:-$DOMAIN_USER}"

while true; do
  read -srp "Admin Password (required): " DOMAIN_PASS
  echo ""
  if [ -n "$DOMAIN_PASS" ]; then
    break
  fi
  echo "❌ Password cannot be empty! Please try again."
done

if [ ${#LAB_MAP[@]} -gt 0 ]; then
  echo ""
  echo "Available Labs:"
  for id in "${!LAB_MAP[@]}"; do
    echo " - $id : ${LAB_MAP[$id]}"
  done
  read -rp "Selected Lab ID [${MATCHED_LAB:-none}]: " input_lab
  SELECTED_LAB="${input_lab:-$MATCHED_LAB}"
else
  SELECTED_LAB="$MATCHED_LAB"
fi

read -rp "Update System Packages? (y/n) [y]: " input_update
input_update="${input_update:-y}"
if [[ "$input_update" =~ ^[Yy] ]]; then
  UPDATE_SYSTEM="y"
else
  UPDATE_SYSTEM="n"
fi

echo ""
echo "----------------------------------------------------------"
echo " 🚀 Starting Deployment Tasks"
echo "----------------------------------------------------------"

log_step() {
  echo ""
  echo "=========================================================="
  echo "▶️ [$1/$2] $3"
  echo "=========================================================="
}

TOTAL_STEPS=9
[ "$UPDATE_SYSTEM" = "y" ] && TOTAL_STEPS=10
STEP=1

# 1. Releasing Locks
log_step $((STEP++)) $TOTAL_STEPS "Releasing Package Manager Locks"
systemctl stop packagekit || true
pkill -9 packagekitd || true
pkill -9 dnf || true

# 2. Swap LibreOffice
log_step $((STEP++)) $TOTAL_STEPS "Swapping LibreOffice for ONLYOFFICE"
dnf remove -y 'libreoffice*'
dnf install -y --nogpgcheck https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm onlyoffice-desktopeditors

# 3. System Update (Optional)
if [ "$UPDATE_SYSTEM" = "y" ]; then
  log_step $((STEP++)) $TOTAL_STEPS "Updating System Packages"
  dnf update -y --nogpgcheck
fi

# 4. Dependencies
log_step $((STEP++)) $TOTAL_STEPS "Installing AD & Security Dependencies"
dnf install -y --nogpgcheck realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit

# 5. Dank Material Shell (DMS)
log_step $((STEP++)) $TOTAL_STEPS "Installing Dank Material Shell (DMS)"
curl -fsSL https://install.danklinux.com -o /tmp/dms-install.sh
chmod 777 /tmp/dms-install.sh
bash /tmp/dms-install.sh </dev/null
rm -f /tmp/dms-install.sh

# 6. Network & DNS
log_step $((STEP++)) $TOTAL_STEPS "Configuring DNS & Clock Sync"
if [ -n "$AD_DNS_IP" ]; then
  nmcli connection modify 'Wired connection 1' ipv4.dns "$AD_DNS_IP" ipv4.dns-search "$DOMAIN_NAME" ipv4.ignore-auto-dns yes || true
  nmcli connection up 'Wired connection 1' || true
fi
systemctl enable --now chronyd
chronyc makestep || true

# 7. Realm Join
log_step $((STEP++)) $TOTAL_STEPS "Joining Active Directory Realm"
printf '%s\n' "$DOMAIN_PASS" | realm join --user="$DOMAIN_USER" "$DOMAIN_NAME" --verbose

# 8. Lab Access Rules
log_step $((STEP++)) $TOTAL_STEPS "Applying Lab Access Rules"
if [ -n "$SELECTED_LAB" ]; then
  realm permit -g "$SELECTED_LAB"
  for id in "${!LAB_MAP[@]}"; do
    if [ "$id" != "$SELECTED_LAB" ]; then
      realm deny -g "$id" || true
    fi
  done
else
  echo "⚠️ No lab selected, skipping access rules."
fi

# 9. Policy Refresh & PAM
log_step $((STEP++)) $TOTAL_STEPS "Installing Policy Refresh & PAM Hooks"
cp -f "$SCRIPT_DIR/refresh-app-policies.sh" /usr/local/bin/refresh-app-policies || true
chmod 755 /usr/local/bin/refresh-app-policies || true

cat << 'EOF' > /usr/local/bin/refresh
#!/bin/bash
sudo /usr/local/bin/refresh-app-policies
EOF
chmod 755 /usr/local/bin/refresh

if ! grep -q 'refresh-app-policies' /etc/pam.d/postlogin 2>/dev/null; then
  echo 'session optional pam_exec.so type=open_session /usr/local/bin/refresh-app-policies' >> /etc/pam.d/postlogin
fi
/usr/local/bin/refresh-app-policies || true

# 10. Finalize Services
log_step $((STEP++)) $TOTAL_STEPS "Finalizing /etc/skel & System Services"
authselect select sssd with-mkhomedir --force
systemctl enable --now oddjobd

THEME_ARCHIVE="$SCRIPT_DIR/niri-dms-config.tar.gz"
if [ -f "$THEME_ARCHIVE" ]; then
  mkdir -p /etc/skel/.config /etc/skel/.local/share
  tar -xzf "$THEME_ARCHIVE" -C /etc/skel
  chmod -R 755 /etc/skel/.config /etc/skel/.local
fi

mkdir -p /var/cache/dms-greeter
chmod 777 /var/cache/dms-greeter
sss_cache -E || true
systemctl restart sssd oddjobd greetd || true

echo ""
echo "=========================================================="
echo " 🎉 Deployment Finished Successfully!"
echo " Log file saved to: $LOG_FILE"
echo "=========================================================="