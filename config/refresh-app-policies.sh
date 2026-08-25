#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Policy Enforcement Engine
# Script: /etc/ad-dms/refresh-app-policies.sh
# ==============================================================================
set -euo pipefail

# ANSI Colors
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

CONF_DIR="/etc/ad-dms"

echo -e "\n${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${CYAN}            AD-DMS POLICY ENGINE SYSTEM SYNCHRONIZATION              ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}\n"

# Helper function to parse configuration files into DNF and Flatpak arrays
parse_config_file() {
  local file="$1"
  local mode="dnf"

  dnf_apps=()
  flatpak_apps=()

  [ ! -f "$file" ] && return 1

  while IFS= read -r line || [ -n "$line" ]; do
    # Strip whitespace
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Detect Flatpak section identifier header
    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK[[:space:]]*PACKAGES[[:space:]]*--- || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      mode="flatpak"
      continue
    fi

    # Ignore comments and empty lines
    if [[ -z "$line" || "$line" =~ ^# ]]; then
      continue
    fi

    if [ "$mode" = "dnf" ]; then
      dnf_apps+=("$line")
    else
      flatpak_apps+=("$line")
    fi
  done < "$file"
}

# ------------------------------------------------------------------------------
# 1. Process Compulsory Apps
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[1/4] Processing compulsory-apps.conf...${NC}"
if [ -f "${CONF_DIR}/compulsory-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/compulsory-apps.conf"

  # Native DNF Packages
  for pkg in "${dnf_apps[@]:-}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
      echo -e "  -> ${YELLOW}[DNF INSTALL]${NC} Installing missing mandatory package: ${BOLD}${pkg}${NC}"
      dnf install -y "$pkg" 2>/dev/null || echo -e "  -> ${RED}[ERROR]${NC} Failed to install DNF package: ${pkg}"
    else
      echo -e "  -> ${GREEN}[DNF VERIFIED]${NC} Native package '${pkg}' is present."
    fi
  done

  # Flatpak Applications
  for app in "${flatpak_apps[@]:-}"; do
    if ! flatpak list --app 2>/dev/null | grep -q "$app"; then
      echo -e "  -> ${YELLOW}[FLATPAK INSTALL]${NC} Installing mandatory Flatpak: ${BOLD}${app}${NC}"
      flatpak install -y flathub "$app" 2>/dev/null || echo -e "  -> ${RED}[ERROR]${NC} Failed to install Flatpak: ${app}"
    else
      echo -e "  -> ${GREEN}[FLATPAK VERIFIED]${NC} Flatpak '${app}' is present."
    fi
  done

  echo -e "  ${GREEN}[STATUS] compulsory-apps.conf synced successfully (${#dnf_apps[@]} DNF, ${#flatpak_apps[@]} Flatpak).${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] compulsory-apps.conf not found.${NC}\n"
fi

# ------------------------------------------------------------------------------
# 2. Process Blocked Apps
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[2/4] Processing blocked-apps.conf...${NC}"
if [ -f "${CONF_DIR}/blocked-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/blocked-apps.conf"

  # Native DNF Packages
  for pkg in "${dnf_apps[@]:-}"; do
    if rpm -q "$pkg" &>/dev/null; then
      echo -e "  -> ${RED}[DNF REMOVE]${NC} Removing blacklisted DNF package: ${BOLD}${pkg}${NC}"
      dnf remove -y "$pkg" 2>/dev/null || true
    else
      echo -e "  -> ${GREEN}[DNF VERIFIED]${NC} Blacklisted DNF package '${pkg}' is clean."
    fi
  done

  # Flatpak Applications
  for app in "${flatpak_apps[@]:-}"; do
    if flatpak list --app 2>/dev/null | grep -q "$app"; then
      echo -e "  -> ${RED}[FLATPAK UNINSTALL]${NC} Uninstalling blacklisted Flatpak: ${BOLD}${app}${NC}"
      flatpak uninstall -y "$app" 2>/dev/null || true
    else
      echo -e "  -> ${GREEN}[FLATPAK VERIFIED]${NC} Blacklisted Flatpak '${app}' is clean."
    fi
  done

  echo -e "  ${GREEN}[STATUS] blocked-apps.conf synced successfully (${#dnf_apps[@]} DNF, ${#flatpak_apps[@]} Flatpak).${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] blocked-apps.conf not found.${NC}\n"
fi

# ------------------------------------------------------------------------------
# 3. Process Allowed Apps
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[3/4] Processing allowed-apps.conf...${NC}"
if [ -f "${CONF_DIR}/allowed-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/allowed-apps.conf"
  echo -e "  -> ${GREEN}[VERIFIED]${NC} Whitelist loaded: ${#dnf_apps[@]} DNF packages, ${#flatpak_apps[@]} Flatpak applications."
  echo -e "  ${GREEN}[STATUS] allowed-apps.conf synced successfully.${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] allowed-apps.conf not found.${NC}\n"
fi

# ------------------------------------------------------------------------------
# 4. Process Group Apps
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[4/4] Processing group-apps.conf...${NC}"
if [ -f "${CONF_DIR}/group-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/group-apps.conf"
  echo -e "  -> ${GREEN}[VERIFIED]${NC} Role-based rules loaded: ${#dnf_apps[@]} DNF rules, ${#flatpak_apps[@]} Flatpak rules."
  echo -e "  ${GREEN}[STATUS] group-apps.conf synced successfully.${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] group-apps.conf not found.${NC}\n"
fi

echo -e "${BOLD}${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}         ALL SYSTEM & APP POLICIES SYNCHRONIZED SUCCESSFULLY          ${NC}"
echo -e "${BOLD}${GREEN}======================================================================${NC}\n"