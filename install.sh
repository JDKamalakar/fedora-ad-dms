#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Bootstrapper (install.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

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
    local required="${2:-true}"
    echo -n "   • Downloading ${file}... "
    
    if curl -fsSL "${PRIMARY_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo "✅ OK"
    elif curl -fsSL "${FALLBACK_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo "✅ OK (found in subfolder)"
    else
        if [ "$required" = "true" ]; then
            echo "❌ FAILED"
            echo "❌ Critical Error: Required file '${file}' could not be located on GitHub!" >&2
            exit 1
        else
            echo "⚠️ Skipping optional file: ${file}"
        fi
    fi
}

# Required Core Files
fetch_file "lab.conf" "true"
fetch_file "niri-dms-config.tar.gz" "true"
fetch_file "setup-ad-dms-tui.sh" "true"

# App Management Policy Files (Optional if not created on repo yet)
fetch_file "allowed-apps.conf" "false"
fetch_file "blocked-apps.conf" "false"
fetch_file "compulsory-apps.conf" "false"
fetch_file "group-apps.conf" "false"

chmod +x setup-ad-dms-tui.sh

echo "----------------------------------------------------------------------"
echo "▶️ Launching setup-ad-dms-tui.sh..."
exec ./setup-ad-dms-tui.sh </dev/tty
