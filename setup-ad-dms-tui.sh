#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Automated Setup & Access Enforcer (setup-ad-dms-tui.sh)
# Version: 3.0.0 (Bulletproof Daemon Architecture - Zero Shell Hooks)
# ==============================================================================
set -euo pipefail

VERSION="3.0.0"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/ad-dms"
LOCAL_CONFIG="${SCRIPT_DIR}/lab.conf"
LOCAL_TAR="${SCRIPT_DIR}/niri-dms-config.tar.gz"

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}   🖥️  GSFCU LAB SSSD & NIRI DMS AUTOMATED SETUP - v${VERSION}         ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo

# ------------------------------------------------------------------------------
# Cleanup Legacy/Unsafe Profile Hooks (Safety Measure)
# ------------------------------------------------------------------------------
rm -f /etc/profile.d/ad-dms-login-refresh.sh /etc/sudoers.d/ad-dms

# ------------------------------------------------------------------------------
# Step 1: Configure Fedora PAM via authselect
# ------------------------------------------------------------------------------
echo -e "${YELLOW}🔒 Setting up Authselect (SSSD + Auto Home Directory Creation)...${NC}"
if command -v authselect &>/dev/null; then
    authselect select sssd with-mkhomedir --force || true
    systemctl enable --now oddjobd.service 2>/dev/null || true
    echo -e "${GREEN}✅ PAM configured successfully!${NC}"
fi

# ------------------------------------------------------------------------------
# Step 2: Directory Setup & Policy File Copy
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}📁 Preparing configuration directories at ${CONF_DIR}...${NC}"
mkdir -p "$CONF_DIR"

if [ -f "$LOCAL_CONFIG" ]; then
    cp "$LOCAL_CONFIG" /etc/lab.conf
    cp "$LOCAL_CONFIG" "$CONF_DIR/lab.conf"
fi

for app_conf in allowed-apps.conf blocked-apps.conf compulsory-apps.conf group-apps.conf blocked-users.conf; do
    if [ -f "${SCRIPT_DIR}/${app_conf}" ]; then
        cp "${SCRIPT_DIR}/${app_conf}" "${CONF_DIR}/${app_conf}"
        echo -e "   • Installed ${CYAN}${app_conf}${NC}"
    else
        touch "${CONF_DIR}/${app_conf}"
        echo -e "   • Created empty template for ${CYAN}${app_conf}${NC}"
    fi
done

# ------------------------------------------------------------------------------
# Step 3: SSSD Active Directory Access Rules (Blacklist Strategy)
# ------------------------------------------------------------------------------
RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
MATCHED_LAB=""
DENY_GROUPS=()

if [ -f "/etc/lab.conf" ]; then
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')
        [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

        if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
            MATCHED_LAB="$lab_name"
        else
            [ -n "$ad_group" ] && DENY_GROUPS+=("$ad_group")
        fi
    done < /etc/lab.conf
fi

DENY_USERS=()
if [ -f "$CONF_DIR/blocked-users.conf" ]; then
    while IFS= read -r u || [ -n "$u" ]; do
        u=$(echo "$u" | xargs)
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        DENY_USERS+=("$u")
    done < "$CONF_DIR/blocked-users.conf"
fi

DENY_CONFIG_BLOCK="access_provider = simple"

if [ ${#DENY_GROUPS[@]} -gt 0 ]; then
    DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
    DENY_CONFIG_BLOCK="${DENY_CONFIG_BLOCK}
simple_deny_groups = ${DENY_GROUPS_STR}"
fi

if [ ${#DENY_USERS[@]} -gt 0 ]; then
    DENY_USERS_STR=$(IFS=,; echo "${DENY_USERS[*]}")
    DENY_CONFIG_BLOCK="${DENY_CONFIG_BLOCK}
simple_deny_users = ${DENY_USERS_STR}"
fi

echo -e "\n📌 ${BOLD}Hostname:${NC} $RAW_HOSTNAME"
echo -e "📌 ${BOLD}Current Machine Lab:${NC} ${MATCHED_LAB:-General Machine}"

echo -e "${YELLOW}⏹️ Writing SSSD configuration and flushing cache...${NC}"
systemctl stop sssd || true
systemctl reset-failed sssd || true

cat <<EOF > /etc/sssd/sssd.conf
[sssd]
services = nss, pam
domains = gsfcu.local

[domain/gsfcu.local]
id_provider = ad
${DENY_CONFIG_BLOCK}
ad_domain = gsfcu.local
krb5_realm = GSFCU.LOCAL
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
cache_credentials = True
case_sensitive = false
EOF

sed -i 's/\r$//' /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true

rm -rf /var/lib/sss/db/*
systemctl start sssd
echo -e "${GREEN}✅ SSSD rules applied cleanly!${NC}"

# ------------------------------------------------------------------------------
# Step 4: Deploy Niri DMS Configs to /etc/skel & Existing Homes
# ------------------------------------------------------------------------------
if [ -f "$LOCAL_TAR" ]; then
    echo -e "\n${YELLOW}📦 Deploying Niri DMS configs to /etc/skel...${NC}"
    TMP_DIR="/tmp/niri-dms-config-extracted"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    tar -xzf "$LOCAL_TAR" -C "$TMP_DIR"

    cp -a "$TMP_DIR"/. /etc/skel/
    chmod -R a+rX /etc/skel

    for user_dir in /home/*; do
        if [ -d "$user_dir" ]; then
            u_name=$(basename "$user_dir")
            u_group=$(id -gn "$u_name" 2>/dev/null || echo "$u_name")
            cp -a "$TMP_DIR"/. "$user_dir/"
            chown -R "$u_name:$u_group" "$user_dir"
            echo -e "   • Applied config to ${CYAN}$user_dir${NC}"
        fi
    done
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ Niri DMS configs deployed system-wide!${NC}"
fi

# ------------------------------------------------------------------------------
# Step 5: Application Enforcement Engine Script
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}⚙️ Installing Application Enforcement Engine...${NC}"

cat <<'EOF' > /usr/local/bin/ad-dms-app-enforcer
#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/ad-dms"

# Install compulsory applications
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

# Kill blocked applications
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
# Step 6: Pure Systemd Refresh Service & Timer (Runs as Root Background Service)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}⏰ Creating Background Systemd Timer Daemon...${NC}"

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
Description=Run AD DMS App Enforcer at Boot and Every 10 Minutes

[Timer]
OnBootSec=10s
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ad-dms-refresh.timer
echo -e "${GREEN}✅ Systemd timer activated (Runs on boot + every 10 mins)!${NC}"

# Execute once now to apply immediately
/usr/local/bin/ad-dms-app-enforcer || true

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${BOLD}🚀 AD DMS DEPLOYMENT COMPLETE! (v${VERSION})${NC}"
echo -e "${GREEN}======================================================================${NC}"