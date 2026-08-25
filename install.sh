#!/usr/bin/env bash
# ==============================================================================
# Repository Bootstrapper
# Script: install.sh
# ==============================================================================
set -euo pipefail

# ANSI Colors
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
API_PRESETS_URL="https://api.github.com/repos/JDKamalakar/fedora-ad-dms/contents/presets"
WORK_DIR="/tmp/fedora-ad-dms"

echo -e "${CYAN}🚀 Initializing AD-DMS Installer Bootstrapper V2.1...${NC}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/presets"
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
      rm -f "${file}" 2>/dev/null || true
    fi
  fi
}

# ------------------------------------------------------------------------------
# 1. Fetch Core System Components & Policy Configurations
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}[1/3] Downloading core installer scripts and domain configs...${NC}"
fetch_file "setup-ad-dms-tui.sh" "true"
fetch_file "lab.conf" "true"
fetch_file "domain.conf" "false"

# Policy Engine & App Configuration Files
fetch_file "config/refresh-app-policies.sh" "true"
fetch_file "config/remote-tasks.sh" "true"
fetch_file "config/allowed-apps.conf" "true"
fetch_file "config/blocked-apps.conf" "true"
fetch_file "config/compulsory-apps.conf" "true"
fetch_file "config/group-apps.conf" "true"

# ------------------------------------------------------------------------------
# 2. Dynamically Auto-Discover and Fetch All Presets
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}[2/3] Querying repository for desktop preset archives...${NC}"
PRESET_FILES=$(curl -fsSL "$API_PRESETS_URL" 2>/dev/null | grep '"name":' | cut -d'"' -f4 | grep -E '\.(tar\.gz|tgz)$' || true)

if [ -n "$PRESET_FILES" ]; then
  for preset in $PRESET_FILES; do
    fetch_file "presets/${preset}" "false"
  done
else
  echo -e "  ${YELLOW}[INFO] GitHub API query unavailable or rate-limited. Using fallback preset targets.${NC}"
  fetch_file "presets/niri-dms-config.tar.gz" "false"
  fetch_file "presets/DankMaterialShell.tar.gz" "false"
fi

# ------------------------------------------------------------------------------
# 3. Set Execution Permissions & Launch TUI Setup
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}[3/3] Preparing execution environment...${NC}"
chmod +x setup-ad-dms-tui.sh
[ -f refresh-app-policies.sh ] && chmod +x refresh-app-policies.sh
[ -f remote-tasks.sh ] && chmod +x remote-tasks.sh

echo -e "${GREEN}[OK] Handing over execution to setup-ad-dms-tui.sh...${NC}\n"
exec ./setup-ad-dms-tui.sh "$@"
