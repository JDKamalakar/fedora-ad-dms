#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Full Setup & Enforcement Engine (setup-ad-dms-tui.sh)
# ==============================================================================
set -euo pipefail

VERSION="2.0.0"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/ad-dms"
LOCAL_CONFIG="${SCRIPT_DIR}/lab.conf"
LOCAL_TAR="${SCRIPT_DIR}/niri-dms-config.tar.gz"

# Terminal ANSI Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}       🖥️  GSFCU LAB SSSD & NIRI DMS AUTOMATED SETUP (v${VERSION})     ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo

# ------------------------------------------------------------------------------
# Step 1: Directory Setup & Configuration Deployment
# ------------------------------------------------------------------------------
echo -e "${YELLOW}📁 Preparing configuration directories at ${CONF_DIR}...${NC}"
mkdir -p "$CONF_DIR"

if [ -f "$LOCAL_CONFIG" ]; then
    cp "$LOCAL_CONFIG" /etc/lab.conf
    cp "$LOCAL_CONFIG" "$CONF_DIR/lab.conf"
fi

for app_conf in allowed-apps.conf blocked-apps.conf compulsory-apps.conf group-apps.conf; do
    if [ -f "${SCRIPT_DIR}/${app_conf}" ]; then
        cp "${SCRIPT_DIR}/${app_conf}" "${CONF_DIR}/${app_conf}"
        echo -e "   • Installed ${CYAN}${app_conf}${NC}"
    else
        touch "${CONF_DIR}/${app_conf}"
        echo -e "   • Created empty template for ${CYAN}${app_conf}${NC}"
    fi
done

# ------------------------------------------------------------------------------
# Step 2: SSSD Active Directory Group Filtering
# ------------------------------------------------------------------------------
RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
MATCHED_LAB=""
MATCHED_GROUP=""

if [ -f "/etc/lab.conf" ]; then
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')
        [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

        if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
            MATCHED_LAB="$lab_name"
            MATCHED_GROUP="$ad_group"
            break
        fi
    done < /etc/lab.conf
fi

echo -e "\n📌 ${BOLD}Hostname:${NC} $RAW_HOSTNAME"
if [ -n "$MATCHED_GROUP" ]; then
    echo -e "📌 ${BOLD}Detected Lab:${NC} $MATCHED_LAB (Allowed AD Group: $MATCHED_GROUP)"
else
    echo -e "${YELLOW}⚠️ No match found for hostname pattern in lab.conf. Allowing all AD logins.${NC}"
fi

ALL_GROUPS=()
if [ -f "/etc/lab.conf" ]; then
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        ad_group=$(echo "${ad_group:-}" | xargs)
        [[ -z "$ad_group" || "$lab_name" =~ ^# ]] && continue
        ALL_GROUPS+=("$ad_group")
    done < /etc/lab.conf
fi

if [ -n "$MATCHED_GROUP" ]; then
    DENY_GROUPS=()
    for g in "${ALL_GROUPS[@]}"; do
        if [ "$g" != "$MATCHED_GROUP" ]; then
            DENY_GROUPS+=("$g")
        fi
    done
    DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
    ACCESS_BLOCK="access_provider = simple
simple_deny_groups = ${DENY_GROUPS_STR}"
else
    ACCESS_BLOCK="access_provider = permit"
fi

echo -e "${YELLOW}⏹️ Restarting SSSD with updated access controls...${NC}"
systemctl stop sssd || true
systemctl reset-failed sssd || true

cat <<EOF > /etc/sssd/sssd.conf
[sssd]
services = nss, pam
domains = gsfcu.local

[domain/gsfcu.local]
id_provider = ad
${ACCESS_BLOCK}
ad_domain = gsfcu.local
krb5_realm = GSFCU.LOCAL
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
cache_credentials = True
EOF

sed -i 's/\r$//' /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true
rm -rf /var/lib/sss/db/*
systemctl start sssd
echo -e "${GREEN}✅ SSSD access control applied!${NC}"

# ------------------------------------------------------------------------------
# Step 3: Deploy Niri DMS Desktop Configuration
# ------------------------------------------------------------------------------
if [ -f "$LOCAL_TAR" ]; then
    echo -e "\n${YELLOW}📦 Extracting and deploying Niri DMS configurations...${NC}"
    TMP_DIR="/tmp/niri-dms-config-extracted"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    tar -xzf "$LOCAL_TAR" -C "$TMP_DIR"

    cp -r "$TMP_DIR"/. /etc/skel/ 2>/dev/null || cp -r "$TMP_DIR"/* /etc/skel/ 2>/dev/null || true

    for user_dir in /home/*; do
        if [ -d "$user_dir" ]; then
            u_name=$(basename "$user_dir")
            u_group=$(id -gn "$u_name" 2>/dev/null || echo "$u_name")
            cp -r "$TMP_DIR"/. "$user_dir/" 2>/dev/null || cp -r "$TMP_DIR"/* "$user_dir/" 2>/dev/null || true
            chown -R "$u_name:$u_group" "$user_dir" 2>/dev/null || true
            echo -e "   • Applied config to ${CYAN}$user_dir${NC}"
        fi
    done
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ Niri DMS configs deployed system-wide!${NC}"
fi

# ------------------------------------------------------------------------------
# Step 4: Create App Management Policy Engine Script
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}⚙️ Building Application Enforcement Engine (/usr/local/bin/ad-dms-app-enforcer)...${NC}"

cat <<'EOF' > /usr/local/bin/ad-dms-app-enforcer
#!/usr/bin/env bash
# AD DMS Application Policy Enforcer
set -euo pipefail

CONF_DIR="/etc/ad-dms"

# 1. Enforce Compulsory Apps (Install if missing)
if [ -f "$CONF_DIR/compulsory-apps.conf" ]; then
    while IFS= read -r app || [ -n "$app" ]; do
        app=$(echo "$app" | xargs)
        [[ -z "$app" || "$app" =~ ^# ]] && continue
        if ! rpm -q "$app" &>/dev/null; then
            echo "📦 Installing compulsory app: $app"
            dnf install -y "$app" || true
        fi
    done < "$CONF_DIR/compulsory-apps.conf"
fi

# 2. Enforce Blocked Apps (Kill running instances)
if [ -f "$CONF_DIR/blocked-apps.conf" ]; then
    while IFS= read -r app || [ -n "$app" ]; do
        app=$(echo "$app" | xargs)
        [[ -z "$app" || "$app" =~ ^# ]] && continue
        if pgrep -x "$app" &>/dev/null; then
            echo "🚫 Terminating blocked application: $app"
            pkill -9 -x "$app" || true
        fi
    done < "$CONF_DIR/blocked-apps.conf"
fi

EOF

chmod +x /usr/local/bin/ad-dms-app-enforcer

# ------------------------------------------------------------------------------
# Step 5: Systemd Timer (Refresh every 10 minutes)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}⏰ Creating 10-Minute Periodic Systemd Timer...${NC}"

cat <<EOF > /etc/systemd/system/ad-dms-refresh.service
[Unit]
Description=AD DMS Application Policy Enforcer Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ad-dms-app-enforcer
EOF

cat <<EOF > /etc/systemd/system/ad-dms-refresh.timer
[Unit]
Description=Run AD DMS App Enforcer every 10 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ad-dms-refresh.timer
echo -e "${GREEN}✅ 10-minute refresh timer activated!${NC}"

# ------------------------------------------------------------------------------
# Step 6: Login Hook (Run refresh on user login)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}🔑 Setting up User Login Execution Hook...${NC}"

cat <<EOF > /etc/profile.d/ad-dms-login-refresh.sh
# Run AD DMS App Refresh on User Login
if [ -n "\$bash" ] || [ -n "\$zsh" ] || [ -n "\$SSH_CLIENT" ] || [ -n "\$DISPLAY" ] || [ -n "\$WAYLAND_DISPLAY" ]; then
    sudo /usr/local/bin/ad-dms-app-enforcer &>/dev/null &
fi
EOF

chmod +x /etc/profile.d/ad-dms-login-refresh.sh

# Run enforcer immediately once
/usr/local/bin/ad-dms-app-enforcer || true

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${BOLD}🚀 AD DMS FULL SYSTEM DEPLOYMENT COMPLETED SUCCESSFULLY! (v${VERSION})${NC}"
echo -e "${GREEN}======================================================================${NC}"
