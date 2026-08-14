#!/usr/bin/env bash
# ==============================================================================
# Fully Automated Host-Based SSSD Access Control
# ==============================================================================
set -euo pipefail

# Ensure script is executed as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# Configuration File Locations
CONFIG_FILE="/etc/lab.config"
if [ ! -f "$CONFIG_FILE" ] && [ -f "./lab.config" ]; then
    CONFIG_FILE="./lab.config"
fi

RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')

ALL_GROUPS=()
ALL_NAMES=()
ALL_PATTERNS=()

MATCHED_LAB_NAME=""
MATCHED_AD_GROUP=""

# ------------------------------------------------------------------------------
# 1. Parse `lab.config`
# ------------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        # Trim leading and trailing whitespace from each field
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')

        # Skip comments or empty lines
        [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

        ALL_GROUPS+=("$ad_group")
        ALL_NAMES+=("$lab_name")
        ALL_PATTERNS+=("$pattern")

        # Prefix Match Check (e.g., GSFCURDLAB002 matches GSFCURDLAB)
        if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
            MATCHED_LAB_NAME="$lab_name"
            MATCHED_AD_GROUP="$ad_group"
        fi
    done < "$CONFIG_FILE"
else
    echo "❌ Error: $CONFIG_FILE not found!" >&2
    exit 1
fi

echo "======================================================================"
echo "🖥️  AUTOMATIC LAB DETECTION & SSSD ACCESS CONTROL"
echo "======================================================================"
echo "📌 Hostname Detected : $RAW_HOSTNAME"

DENY_GROUPS=()

# ------------------------------------------------------------------------------
# 2. Build Deny Rules
# ------------------------------------------------------------------------------
if [ -n "$MATCHED_AD_GROUP" ]; then
    echo "✅ Matched Lab       : $MATCHED_LAB_NAME"
    echo "✅ Allowed Group     : $MATCHED_AD_GROUP (and unlisted IDs like 25bca001)"
    echo "----------------------------------------------------------------------"
    
    # Populate DENY_GROUPS with every lab group EXCEPT the current machine's lab
    for g in "${ALL_GROUPS[@]}"; do
        if [ "$g" != "$MATCHED_AD_GROUP" ]; then
            DENY_GROUPS+=("$g")
            echo "⛔ Blocked Lab Group : $g"
        fi
    done

    # Join blocked groups with commas
    DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
    ACCESS_BLOCK="access_provider = simple
simple_deny_groups = ${DENY_GROUPS_STR}"
else
    echo "⚠️ Warning: No lab pattern matched '$RAW_HOSTNAME' in $CONFIG_FILE."
    echo "   Defaulting to permit all domain users."
    ACCESS_BLOCK="access_provider = permit"
fi

# ------------------------------------------------------------------------------
# 3. Write SSSD Configuration
# ------------------------------------------------------------------------------
echo "----------------------------------------------------------------------"
echo "⏹️ Stopping SSSD service..."
systemctl stop sssd || true
systemctl reset-failed sssd || true

echo "📝 Writing /etc/sssd/sssd.conf..."
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

# ------------------------------------------------------------------------------
# 4. Security Enforcement & Cache Clearing
# ------------------------------------------------------------------------------
echo "🔒 Restricting file permissions..."
sed -i 's/\r$//' /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true

echo "🧹 Flushing cache database..."
rm -rf /var/lib/sss/db/*

echo "▶️ Starting SSSD Service..."
systemctl start sssd

# ------------------------------------------------------------------------------
# 5. Verification
# ------------------------------------------------------------------------------
echo "======================================================================"
if systemctl is-active --quiet sssd; then
    echo "✅ SSSD successfully configured and running!"
    echo "   • ALLOWED : ${MATCHED_AD_GROUP:-All} + Unlisted domain IDs (e.g., 25bca001)"
    echo "   • BLOCKED : ${DENY_GROUPS_STR:-None}"
else
    echo "❌ SSSD failed to start. Run 'journalctl -u sssd -xe' for details."
    exit 1
fi
echo "======================================================================"
