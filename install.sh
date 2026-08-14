#!/usr/bin/env bash
# ==============================================================================
# Fully Automated Host-Based SSSD Access Control (install.sh)
# ==============================================================================
set -euo pipefail

# Ensure script is executed as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Locate or Download `lab.conf`
# ------------------------------------------------------------------------------
CONFIG_FILE="/etc/lab.conf"
CONFIG_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/lab.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "./lab.conf" ]; then
        CONFIG_FILE="./lab.conf"
    else
        echo "📥 'lab.conf' not found locally or at /etc/lab.conf."
        echo "   Fetching latest 'lab.conf' from GitHub repository..."
        if command -v curl &>/dev/null; then
            curl -fsSL "$CONFIG_URL" -o /etc/lab.conf
        elif command -v wget &>/dev/null; then
            wget -qO /etc/lab.conf "$CONFIG_URL"
        else
            echo "❌ Error: Neither curl nor wget is available to download lab.conf." >&2
            exit 1
        fi
        CONFIG_FILE="/etc/lab.conf"
        echo "✅ Saved configuration to /etc/lab.conf"
    fi
fi

RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')

ALL_GROUPS=()
ALL_NAMES=()
ALL_PATTERNS=()

MATCHED_LAB_NAME=""
MATCHED_AD_GROUP=""

if [ -f "$CONFIG_FILE" ]; then
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        # Trim leading/trailing whitespace
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')

        # Skip comments or empty lines
        [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

        ALL_GROUPS+=("$ad_group")
        ALL_NAMES+=("$lab_name")
        ALL_PATTERNS+=("$pattern")

        # Match hostname prefix (e.g., GSFCUOSLAB172 matching pattern GSFCUOSLAB)
        if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
            MATCHED_LAB_NAME="$lab_name"
            MATCHED_AD_GROUP="$ad_group"
        fi
    done < "$CONFIG_FILE"
else
    echo "❌ Error: Could not load configuration file!" >&2
    exit 1
fi

echo "======================================================================"
echo "🖥️  AUTOMATED LAB DETECTION & SSSD ACCESS CONTROL"
echo "======================================================================"
echo "📌 Hostname Detected : $RAW_HOSTNAME"

DENY_GROUPS=()

# ------------------------------------------------------------------------------
# 2. Build Deny Group Rules
# ------------------------------------------------------------------------------
if [ -n "$MATCHED_AD_GROUP" ]; then
    echo "✅ Matched Lab       : $MATCHED_LAB_NAME"
    echo "✅ Allowed Group     : $MATCHED_AD_GROUP (and unlisted IDs like 25bca001)"
    echo "----------------------------------------------------------------------"
    
    # Populate DENY_GROUPS with every lab group EXCEPT the matched lab group
    for g in "${ALL_GROUPS[@]}"; do
        if [ "$g" != "$MATCHED_AD_GROUP" ]; then
            DENY_GROUPS+=("$g")
            echo "⛔ Blocked Lab Group : $g"
        fi
    done

    # Format comma-separated list for simple_deny_groups
    DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
    ACCESS_BLOCK="access_provider = simple
simple_deny_groups = ${DENY_GROUPS_STR}"
else
    echo "⚠️ Warning: No lab pattern matched '$RAW_HOSTNAME' in $CONFIG_FILE."
    echo "   Defaulting to unrestricted domain access."
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
echo "🔒 Restricting file permissions and fixing line endings..."
sed -i 's/\r$//' /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf
restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true

echo "🧹 Flushing SSSD database cache..."
rm -rf /var/lib/sss/db/*

echo "▶️ Starting SSSD Service..."
systemctl start sssd

# ------------------------------------------------------------------------------
# 5. Verification
# ------------------------------------------------------------------------------
echo "======================================================================"
if systemctl is-active --quiet sssd; then
    echo "✅ SSSD successfully configured and running!"
    echo "   • ALLOWED : ${MATCHED_AD_GROUP:-All} + General domain users (e.g. 25bca001)"
    echo "   • BLOCKED : ${DENY_GROUPS_STR:-None}"
else
    echo "❌ SSSD failed to start. Run 'journalctl -u sssd -xe' for details."
    exit 1
fi
echo "======================================================================"
