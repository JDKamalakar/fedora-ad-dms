#!/usr/bin/env bash
# ==============================================================================
# Fully Automated Host-Based SSSD & Niri DMS Installer (install.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

REPO_BASE="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
CONFIG_FILE="/etc/lab.config"

# ------------------------------------------------------------------------------
# 1. Fetch & Parse `lab.config`
# ------------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "📥 Fetching 'lab.config' from repository..."
    curl -fsSL "${REPO_BASE}/lab.config" -o /etc/lab.config
fi

RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
ALL_GROUPS=()
MATCHED_LAB_NAME=""
MATCHED_AD_GROUP=""

while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
    lab_name=$(echo "${lab_name:-}" | xargs)
    ad_group=$(echo "${ad_group:-}" | xargs)
    pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')

    [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue
    ALL_GROUPS+=("$ad_group")

    if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
        MATCHED_LAB_NAME="$lab_name"
        MATCHED_AD_GROUP="$ad_group"
    fi
done < "$CONFIG_FILE"

echo "======================================================================"
echo "🖥️  AUTOMATED SSSD & NIRI DMS DEPLOYMENT"
echo "======================================================================"
echo "📌 Hostname Detected : $RAW_HOSTNAME"

# ------------------------------------------------------------------------------
# 2. Configure SSSD
# ------------------------------------------------------------------------------
DENY_GROUPS=()
if [ -n "$MATCHED_AD_GROUP" ]; then
    echo "✅ Matched Lab       : $MATCHED_LAB_NAME"
    echo "✅ Allowed Group     : $MATCHED_AD_GROUP (and unlisted IDs like 25bca001)"
    
    for g in "${ALL_GROUPS[@]}"; do
        if [ "$g" != "$MATCHED_AD_GROUP" ]; then
            DENY_GROUPS+=("$g")
        fi
    done
    DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
    ACCESS_BLOCK="access_provider = simple
simple_deny_groups = ${DENY_GROUPS_STR}"
else
    echo "⚠️ No lab pattern matched. Defaulting to unrestricted domain access."
    ACCESS_BLOCK="access_provider = permit"
fi

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

# ------------------------------------------------------------------------------
# 3. Deploy `niri-dms-config.tar.gz` System-Wide
# ------------------------------------------------------------------------------
echo "----------------------------------------------------------------------"
echo "📦 Downloading and deploying 'niri-dms-config.tar.gz'..."
TMP_TAR="/tmp/niri-dms-config.tar.gz"
TMP_DIR="/tmp/niri-dms-config-extracted"

curl -fsSL "${REPO_BASE}/niri-dms-config.tar.gz" -o "$TMP_TAR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xzf "$TMP_TAR" -C "$TMP_DIR"

# Deploy to /etc/skel for future logins
cp -r "$TMP_DIR"/. /etc/skel/ 2>/dev/null || cp -r "$TMP_DIR"/* /etc/skel/ 2>/dev/null || true

# Deploy to all existing users in /home/
for user_dir in /home/*; do
    if [ -d "$user_dir" ]; then
        u_name=$(basename "$user_dir")
        u_group=$(id -gn "$u_name" 2>/dev/null || echo "$u_name")
        cp -r "$TMP_DIR"/. "$user_dir/" 2>/dev/null || cp -r "$TMP_DIR"/* "$user_dir/" 2>/dev/null || true
        chown -R "$u_name:$u_group" "$user_dir" 2>/dev/null || true
        echo "   • Synchronized configuration to $user_dir"
    fi
done

rm -rf "$TMP_TAR" "$TMP_DIR"
echo "✅ Niri DMS configuration deployed for all users!"
echo "======================================================================"
