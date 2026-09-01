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

GITHUB_RAW_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main"
API_PRESETS_URL="https://api.github.com/repos/JDKamalakar/fedora-ad-dms/contents/presets"
WORK_DIR="/tmp/fedora-ad-dms"

# Intranet Host Discovery (Hostname/mDNS first, then fallback IP)
INTRANET_HOST="${INTRANET_HOST:-GSFCUPLLAB203}"
INTRANET_IP="${INTRANET_IP:-10.205.18.253}"
INTRANET_PORT="${INTRANET_PORT:-8080}"

echo -e "${CYAN}🚀 Initializing AD-DMS Installer Bootstrapper V3.0 (Intranet & Cloud Hybrid)...${NC}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/presets" "$WORK_DIR/config"
cd "$WORK_DIR"

fetch_file() {
  local file="$1"
  local required="${2:-true}"
  
  mkdir -p "$(dirname "${file}")"
  echo -n -e "  -> Fetching ${file}... "

  # 1. Try Intranet Host via Hostname / mDNS
  if curl -fsSL -m 3 "http://${INTRANET_HOST}:${INTRANET_PORT}/${file}" -o "${file}" 2>/dev/null; then
    echo -e "${GREEN}[OK] (Intranet Host: ${INTRANET_HOST})${NC}"
    return 0
  fi

  # 2. Try Intranet Host via Backup IP
  if [ -n "$INTRANET_IP" ] && curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/${file}" -o "${file}" 2>/dev/null; then
    echo -e "${GREEN}[OK] (Intranet IP: ${INTRANET_IP})${NC}"
    return 0
  fi

  # 3. Fallback to GitHub Raw CDN
  if curl -fsSL "${GITHUB_RAW_URL}/${file}?$(date +%s)" -o "${file}" 2>/dev/null; then
    echo -e "${GREEN}[OK] (GitHub Cloud)${NC}"
    return 0
  fi

  if [ "$required" = "true" ]; then
    echo -e "${RED}[FAILED]${NC}"
    echo -e "${RED}[ERROR] Critical file missing: '${file}'${NC}" >&2
    exit 1
  else
    echo -e "${YELLOW}[SKIP] (Optional)${NC}"
    rm -f "${file}" 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------------------
# 1. Fetch Core System Components & Policy Configurations
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}[1/3] Downloading core installer scripts and domain configs...${NC}"
fetch_file "setup-ad-dms-tui.sh" "true"
fetch_file "lab.conf" "true"
fetch_file "domain.conf" "false"

# Policy Engine & App Configuration Files (from repository config/ directory)
fetch_file "config/refresh-app-policies.sh" "true"
fetch_file "config/remote-tasks.sh" "true"
fetch_file "config/allowed-apps.conf" "true"
fetch_file "config/blocked-apps.conf" "true"
fetch_file "config/compulsory-apps.conf" "true"
fetch_file "config/group-apps.conf" "true"

# Flatten config directory into work root for setup-ad-dms-tui.sh compatibility
cp -f config/* . 2>/dev/null || true

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
[ -f config/refresh-app-policies.sh ] && chmod +x config/refresh-app-policies.sh
[ -f config/remote-tasks.sh ] && chmod +x config/remote-tasks.sh

echo -e "${GREEN}[OK] Handing over execution to setup-ad-dms-tui.sh...${NC}\n"

# Report installation event to Intranet Host (if reachable)
(
  CUR_HOST=$(hostname -s 2>/dev/null || echo "FEDORA-NODE")
  CUR_USER="${SUDO_USER:-root}"
  curl -s -m 2 -X POST "http://${INTRANET_HOST}:${INTRANET_PORT}/api/register-install" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\": \"${CUR_HOST}\", \"user\": \"${CUR_USER}\"}" &>/dev/null || true
) &>/dev/null || true

exec ./setup-ad-dms-tui.sh "$@"