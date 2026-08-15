#!/usr/bin/env bash
# ==============================================================================
# Fedora AD DMS Bootstrapper (install.sh)
# ==============================================================================
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root or with sudo.${NC}" >&2
    exit 1
fi

PRIMARY_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
FALLBACK_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/fedora-ad-dms"
WORK_DIR="/tmp/fedora-ad-dms"

echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
echo -e "${CYAN}|${BOLD}        FEDORA AD DMS INSTALLATION BOOTSTRAPPER                       ${NC}${CYAN}|${NC}"
echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
echo -e "${CYAN}[INFO]${NC} Workspace directory: ${WORK_DIR}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo -e "${CYAN}[INFO]${NC} Fetching system components from GitHub repository..."

fetch_file() {
    local file="$1"
    local required="${2:-true}"
    echo -n -e "  -> Downloading ${file}... "
    
    if curl -fsSL "${PRIMARY_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC}"
    elif curl -fsSL "${FALLBACK_URL}/${file}" -o "${file}" 2>/dev/null; then
        echo -e "${GREEN}[OK] (subfolder fallback)${NC}"
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}[FAILED]${NC}"
            echo -e "${RED}[ERROR] Critical file missing: '${file}' could not be located.${NC}" >&2
            exit 1
        else
            echo -e "${YELLOW}[SKIP] File not found (optional)${NC}"
        fi
    fi
}

# Core Files
fetch_file "lab.conf" "true"
fetch_file "niri-dms-config.tar.gz" "true"
fetch_file "setup-ad-dms-tui.sh" "true"

# Optional Policy Overrides
fetch_file "allowed-apps.conf" "false"
fetch_file "blocked-apps.conf" "false"
fetch_file "compulsory-apps.conf" "false"
fetch_file "group-apps.conf" "false"
fetch_file "blocked-users.conf" "false"

chmod +x setup-ad-dms-tui.sh

echo -e "${CYAN}+----------------------------------------------------------------------+${NC}"
echo -e "${CYAN}[INFO]${NC} Launching main configuration engine..."
exec ./setup-ad-dms-tui.sh
