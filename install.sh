#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Bootstrapper (install.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

REPO_BASE="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
WORK_DIR="/tmp/fedora-ad-dms"

echo "🚀 Starting AD DMS Installation Bootstrapper..."
echo "📂 Preparing temporary workspace at ${WORK_DIR}..."

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Downloading repository files from GitHub..."
curl -fsSL "${REPO_BASE}/lab.config" -o lab.config
curl -fsSL "${REPO_BASE}/niri-dms-config.tar.gz" -o niri-dms-config.tar.gz
curl -fsSL "${REPO_BASE}/setup-ad-dms-tui.sh" -o setup-ad-dms-tui.sh

chmod +x setup-ad-dms-tui.sh

echo "✅ Download complete!"
echo "▶️ Launching setup-ad-dms-tui.sh..."
echo "----------------------------------------------------------------------"

exec ./setup-ad-dms-tui.sh
