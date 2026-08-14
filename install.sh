#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Bootstrapper (install.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# Primary & Fallback repositories
PRIMARY_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
FALLBACK_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/fedora-ad-dms"
WORK_DIR="/tmp/fedora-ad-dms"

echo "🚀 Starting AD DMS Installation Bootstrapper..."
echo "📂 Workspace: ${WORK_DIR}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Downloading repository components..."

fetch_file() {
    local file="$1"
    echo -n "   • Downloading ${file}... "
    
    if curl -fsSL "${PRIMARY_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo "✅ OK"
    elif curl -fsSL "${FALLBACK_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo "✅ OK (found in subfolder)"
    else
        echo "❌ FAILED"
        echo "❌ Error: '${file}' could not be located on GitHub!" >&2
        echo "   Please verify that '${file}' is uploaded to the main branch on GitHub." >&2
        exit 1
    fi
}

# Fetch lab.conf instead of lab.config
fetch_file "lab.conf"
fetch_file "niri-dms-config.tar.gz"
fetch_file "setup-ad-dms-tui.sh"

chmod +x setup-ad-dms-tui.sh

echo "----------------------------------------------------------------------"
echo "▶️ Launching setup-ad-dms-tui.sh..."
exec ./setup-ad-dms-tui.sh
