#!/usr/bin/env bash
# ==============================================================================
# Repository Bootstrapper
# Script: install.sh
# ==============================================================================
set -euo pipefail

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Bootstrapper requires root privileges. Run with sudo.${NC}" >&2
  exit 1
fi

PRIMARY_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
WORK_DIR="/tmp/fedora-ad-dms"

echo -e "${CYAN}🚀 Initializing AD-DMS Installer Bootstrapper V1.5...${NC}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

fetch_file() {
  local file="$1"
  local required="${2:-true}"
  echo -n -e "  -> Downloading ${file}... "
  if curl -fsSL "${PRIMARY_URL}/${file}" -o "${file}" 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC}"
  else
    if [ "$required" = "true" ]; then
      echo -e "${RED}[FAILED]${NC}"
      echo -e "${RED}[ERROR] Critical file missing: '${file}'${NC}" >&2
      exit 1
    else
      echo -e "${YELLOW}[SKIP] (Optional component missing)${NC}"
    fi
  fi
}

# Fetch repository components
fetch_file "setup-ad-dms-tui.sh" "true"
fetch_file "lab.conf" "true"
fetch_file "domain.conf" "false"
fetch_file "refresh-app-policies.sh" "false"
fetch_file "allowed-apps.conf" "false"
fetch_file "blocked-apps.conf" "false"
fetch_file "compulsory-apps.conf" "false"

# Fetch presets (preset configurations to be deployed across all user accounts)
mkdir -p presets
fetch_file "presets/niri-dms-config.tar.gz" "true"
fetch_file "presets/DankMaterialShell.tar.gz" "true"

chmod +x setup-ad-dms-tui.sh
[ -f refresh-app-policies.sh ] && chmod +x refresh-app-policies.sh

exec ./setup-ad-dms-tui.sh "$@"
