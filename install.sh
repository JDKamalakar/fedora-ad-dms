#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Bootstrapper (install.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# Point directly to the nested folder path in the repo
REPO_BASE="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/fedora-ad-dms"
WORK_DIR="/tmp/fedora-ad-dms"

echo "🚀 Starting AD DMS Installation Bootstrapper..."
echo "📂 Preparing temporary workspace at ${WORK_DIR}..."

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Downloading repository files from GitHub..."

fetch_file() {
    local file="$1"
    echo -n "   • Fetching ${file}... "
    if curl -fsSL "${REPO_BASE}/${file}" -o "${file}"; then
        echo "✅ OK"
    else
        echo "❌ FAILED (404 Not Found)"
        echo "❌ Error: Could not download '${file}' from ${REPO_BASE}/${file}" >&2
        exit 1
    fi
}

fetch_file "lab.config"
fetch_file "niri-dms-config.tar.gz"
fetch_file "setup-ad-dms-tui.sh"

chmod +x setup-ad-dms-tui.sh

echo "----------------------------------------------------------------------"
echo "▶️ Launching setup-ad-dms-tui.sh..."
exec ./setup-ad-dms-tui.sh
