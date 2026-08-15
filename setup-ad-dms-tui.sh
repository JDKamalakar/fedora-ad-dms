#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Automated Setup & Access Enforcer (setup-ad-dms-tui.sh)
# Version: 3.1.0 (Pure TUI / Systemd Engine)
# ==============================================================================
set -euo pipefail

VERSION="3.1.0"

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root or with sudo.${NC}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/ad-dms"
LOCAL_CONFIG="${SCRIPT_DIR}/lab.conf"
LOCAL_TAR="${SCRIPT_DIR}/niri-dms-config.tar.gz"

echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|${BOLD}      GSFCU LAB SSSD & NIRI DMS AUTOMATED SETUP (v${VERSION})            ${NC}${CYAN}|${NC}"
echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
echo

# ------------------------------------------------------------------------------
# Cleanup Unsafe Profile Hooks
# ------------------------------------------------------------------------------
rm -f /etc/profile.d/ad-dms-login-refresh.sh /etc/sudoers.d/ad-dms

# ------------------------------------------------------------------------------
# STEP 1: PAM & Authselect Configuration
# ------------------------------------------------------------------------------
echo -e "${BLUE}::${NC} ${BOLD}[STEP 1/6] Configuring Fedora Authselect PAM Engine...${NC}"
if command -v authselect &>/dev/null; then
    authselect select sssd with-mkhomedir --force >/dev/null || true
    systemctl enable --now oddjobd.service >/dev/null 2>&1 || true
    echo -e "${GREEN}[OK] PAM configured for SSSD authentication and auto home directory creation.${NC}"
else
    echo -e "${RED}[ERROR] authselect binary not found on this system!${NC}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 2: Directory & Policy Initialization
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}::${NC} ${BOLD}[STEP 2/6] Preparing system policy directories at ${CONF_DIR}...${NC}"
mkdir -p "$CONF_DIR"

if [ -f "$LOCAL_CONFIG" ]; then
    cp "$LOCAL_CONFIG" /etc/lab.conf
    cp "$LOCAL_CONFIG" "$CONF_DIR/lab.conf"
fi

for app_conf in allowed-apps.conf blocked-apps.conf compulsory-apps.conf group-apps.conf blocked-users.conf; do
    if [ -f "${SCRIPT_DIR}/${app_conf}" ]; then
        cp "${SCRIPT_DIR}/${app_conf}" "${CONF_DIR}/${app_conf}"
        echo -e "  -> Installed policy: ${CYAN}${app_conf}${NC}"
    else
        touch "${CONF_DIR}/${app_conf}"
        echo -e "  -> Initialized blank template: ${CYAN}${app_conf}${NC}"
    fi
done

# ------------------------------------------------------------------------------
# STEP 3: Active Directory Access Control (SSSD Blacklist Strategy)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}::${NC} ${BOLD}[STEP 3/6] Generating Active Directory Access Control Rules...${NC}"
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

echo -e "  * Hostname       : ${BOLD}${RAW_HOSTNAME}${NC}"
echo -e "  * Detected Lab   : ${BOLD}${MATCHED_LAB:-General Machine}${NC}"
[ ${#DENY_GROUPS[@]} -gt 0 ] && echo -e "  * Blocked Groups : ${RED}${DENY_GROUPS[*]}${NC}"
[ ${#DENY_USERS[@]} -gt 0 ]  && echo -e "  * Blocked Users  : ${RED}${DENY_USERS[*]}${NC}"

echo -e "${CYAN}[INFO]${NC} Writing /etc/sssd/sssd.conf and clearing cache..."
systemctl stop sssd >/dev/null 2>&1 || true
systemctl reset-failed sssd >/dev/null 2>&1 || true

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
restorecon -v /etc/sssd/sssd.conf >/dev/null 2>&1 || true

rm -rf /var/lib/sss/db/*
systemctl start sssd
echo -e "${GREEN}[OK] SSSD service updated and active.${NC}"

# ------------------------------------------------------------------------------
# STEP 4: Deploy Niri DMS Desktop Configurations
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}::${NC} ${BOLD}[STEP 4/6] Deploying Niri DMS environment templates...${NC}"
if [ -f "$LOCAL_TAR" ]; then
    TMP_DIR="/tmp/niri-dms-config-extracted"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    tar -xzf "$LOCAL_TAR" -C "$TMP_DIR"

    # Copy to skeleton directory for future domain users
    cp -a "$TMP_DIR"/. /etc/skel/
    chmod -R a+rX /etc/skel
    echo -e "  -> Applied template to ${CYAN}/etc/skel${NC}"

    # Sync to existing local/domain accounts in /home
    for user_dir in /home/*; do
        if [ -d "$user_dir" ]; then
            u_name=$(basename "$user_dir")
            u_group=$(id -gn "$u_name" 2>/dev/null || echo "$u_name")
            cp -a "$TMP_DIR"/. "$user_dir/"
            chown -R "$u_name:$u_group" "$user_dir"
            echo -e "  -> Updated configuration for ${CYAN}$user_dir${NC}"
        fi
    done
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}[OK] Desktop configurations deployed successfully.${NC}"
else
    echo -e "${YELLOW}[WARN] Config Archive (${LOCAL_TAR}) missing. Skipping desktop template sync.${NC}"
fi

# ------------------------------------------------------------------------------
# STEP 5: Application Policy Enforcement Script
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}::${NC} ${BOLD}[STEP 5/6] Building Application Enforcement Engine...${NC}"

cat <<'EOF' > /usr/local/bin/ad-dms-app-enforcer
#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/ad-dms"

# Install mandatory applications
if [ -f "$CONF_DIR/compulsory-apps.conf" ]; then
    while IFS= read -r app || [ -n "$app" ]; do
        app=$(echo "$app" | xargs)
        [[ -z "$app" || "$app" =~ ^# ]] && continue
        if ! rpm -q "$app" &>/dev/null; then
            echo "[ENFORCER] Installing compulsory package: $app"
            dnf install -y "$app" || true
        fi
    done < "$CONF_DIR/compulsory-apps.conf"
fi

# Terminate prohibited applications
if [ -f "$CONF_DIR/blocked-apps.conf" ]; then
    while IFS= read -r app || [ -n "$app" ]; do
        app=$(echo "$app" | xargs)
        [[ -z "$app" || "$app" =~ ^# ]] && continue
        if pgrep -x "$app" &>/dev/null; then
            echo "[ENFORCER] Terminating blacklisted process: $app"
            pkill -9 -x "$app" || true
        fi
    done < "$CONF_DIR/blocked-apps.conf"
fi
EOF

chmod +x /usr/local/bin/ad-dms-app-enforcer
echo -e "${GREEN}[OK] Installed /usr/local/bin/ad-dms-app-enforcer${NC}"

# ------------------------------------------------------------------------------
# STEP 6: Systemd Daemon & Periodic Refresh Timer
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}::${NC} ${BOLD}[STEP 6/6] Registering Background Systemd Daemon...${NC}"

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

systemctl daemon-reload >/dev/null 2>&1
systemctl enable --now ad-dms-refresh.timer >/dev/null 2>&1
echo -e "${GREEN}[OK] Systemd timer activated (triggers 10s post-boot & every 10 mins).${NC}"

# Run initial pass
/usr/local/bin/ad-dms-app-enforcer >/dev/null 2>&1 || true

echo -e "\n${CYAN}+----------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|${BOLD}${GREEN}  [SUCCESS] AD DMS DEPLOYMENT COMPLETE (v${VERSION})                    ${NC}${CYAN}|${NC}"
echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
