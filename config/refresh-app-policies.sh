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
    # Strip leading/trailing whitespace
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Detect Flatpak section identifier header
    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK[[:space:]]*PACKAGES[[:space:]]*--- || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      mode="flatpak"
      continue
    fi

    # Ignore comments, empty lines, and KEY=VALUE configuration variables
    if [[ -z "$line" || "$line" =~ ^# || "$line" =~ = ]]; then
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
    if ! rpm -qa "$pkg" 2>/dev/null | grep -q .; then
      echo -e "  -> ${YELLOW}[DNF INSTALL]${NC} Installing missing mandatory package: ${BOLD}${pkg}${NC}"
      dnf install -y "$pkg" 2>/dev/null || echo -e "  -> ${RED}[ERROR]${NC} Failed to install DNF package: ${pkg}"
    else
      echo -e "  -> ${GREEN}[DNF VERIFIED]${NC} Native package '${pkg}' is present."
    fi
  done

  # Flatpak Applications
  for app in "${flatpak_apps[@]:-}"; do
    if ! flatpak list --app --columns=application 2>/dev/null | grep -q -i -E "^${app}$"; then
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
# 2. Process Blocked Apps & System Restrictions
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[2/4] Processing blocked-apps.conf...${NC}"
if [ -f "${CONF_DIR}/blocked-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/blocked-apps.conf"

  BLOCK_ALL_FLATPAKS="false"
  if grep -qi "^BLOCK_ALL_FLATPAK_INSTALLS=true" "${CONF_DIR}/blocked-apps.conf"; then
    BLOCK_ALL_FLATPAKS="true"
  fi

  # 1. Remove & Exclude DNF Packages (Using rpm -qa for wildcard glob expansion)
  EXCLUDE_LIST=""
  for pkg in "${dnf_apps[@]:-}"; do
    EXCLUDE_LIST="${EXCLUDE_LIST} ${pkg}"
    
    if rpm -qa "$pkg" 2>/dev/null | grep -q .; then
      echo -e "  -> ${RED}[DNF REMOVE]${NC} Removing blacklisted DNF package/pattern: ${BOLD}${pkg}${NC}"
      dnf remove -y "$pkg" 2>/dev/null || true
    else
      echo -e "  -> ${GREEN}[DNF VERIFIED]${NC} DNF package '${pkg}' is clean."
    fi
  done

  # Synchronize DNF exclude rules in /etc/dnf/dnf.conf
  if [ -n "$EXCLUDE_LIST" ]; then
    sed -i '/^excludepkgs=/d' /etc/dnf/dnf.conf 2>/dev/null || true
    echo "excludepkgs=${EXCLUDE_LIST}" >> /etc/dnf/dnf.conf
    echo -e "  -> ${GREEN}[DNF POLICY]${NC} Exclude list written to /etc/dnf/dnf.conf"
  fi

  # 2. Uninstall Blacklisted Flatpaks (Checks system and user scopes)
  for app in "${flatpak_apps[@]:-}"; do
    if flatpak list --app --columns=application 2>/dev/null | grep -q -i -E "^${app}$"; then
      echo -e "  -> ${RED}[FLATPAK UNINSTALL]${NC} Uninstalling blacklisted Flatpak: ${BOLD}${app}${NC}"
      flatpak uninstall -y --system "$app" 2>/dev/null || true
      flatpak uninstall -y --user "$app" 2>/dev/null || true
    else
      echo -e "  -> ${GREEN}[FLATPAK VERIFIED]${NC} Flatpak '${app}' is clean."
    fi
  done

  # 3. Handle System-Wide Non-Root Flatpak Restrictions via Polkit
  POLKIT_FLATPAK_RULE="/etc/polkit-1/rules.d/50-block-flatpak-install.rules"
  if [ "$BLOCK_ALL_FLATPAKS" = "true" ]; then
    cat <<'EOF' > "$POLKIT_FLATPAK_RULE"
/* Block non-root users from installing or modifying Flatpaks */
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.Flatpak.app-install" ||
         action.id == "org.freedesktop.Flatpak.runtime-install" ||
         action.id == "org.freedesktop.Flatpak.modify-repo") &&
        !subject.isInGroup("wheel") && subject.user != "root") {
        return polkit.Result.NO;
    }
});
EOF
    echo -e "  -> ${YELLOW}[POLKIT ENFORCED]${NC} Non-root Flatpak installations completely disabled."
  else
    rm -f "$POLKIT_FLATPAK_RULE" 2>/dev/null || true
    echo -e "  -> ${GREEN}[POLKIT VERIFIED]${NC} Non-root Flatpak installation permissions active."
  fi

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
# 4. Process Group Apps (Hostname / Lab Specific)
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[4/4] Processing group-apps.conf...${NC}"
if [ -f "${CONF_DIR}/group-apps.conf" ]; then
  SYS_HOST=$(hostname -s 2>/dev/null || echo "${HOSTNAME:-}")
  SYS_HOST_UPPER=$(echo "$SYS_HOST" | tr '[:lower:]' '[:upper:]')

  echo -e "  -> ${CYAN}[HOSTNAME]${NC} Detected local system hostname: ${BOLD}${SYS_HOST_UPPER}${NC}"

  mode="dnf"
  dnf_matched_count=0
  flatpak_matched_count=0

  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK[[:space:]]*PACKAGES[[:space:]]*--- || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      mode="flatpak"
      continue
    fi

    if [[ -z "$line" || "$line" =~ ^# ]]; then
      continue
    fi

    if [[ "$line" == *":"* ]]; then
      pattern=$(echo "$line" | cut -d':' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
      packages=$(echo "$line" | cut -d':' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

      if [ -n "$pattern" ] && [[ "$SYS_HOST_UPPER" == *"$pattern"* ]]; then
        echo -e "  -> ${YELLOW}[MATCH FOUND]${NC} Hostname matches lab pattern: ${BOLD}${pattern}${NC}"

        for pkg in $packages; do
          if [ "$mode" = "dnf" ]; then
            if ! rpm -qa "$pkg" 2>/dev/null | grep -q .; then
              echo -e "    -> ${YELLOW}[DNF GROUP INSTALL]${NC} Installing DNF package: ${BOLD}${pkg}${NC}"
              dnf install -y "$pkg" 2>/dev/null || echo -e "    -> ${RED}[ERROR]${NC} Failed to install DNF package: ${pkg}"
            else
              echo -e "    -> ${GREEN}[DNF VERIFIED]${NC} DNF package '${pkg}' is present."
            fi
            ((dnf_matched_count++))
          else
            if ! flatpak list --app --columns=application 2>/dev/null | grep -q -i -E "^${pkg}$"; then
              echo -e "    -> ${YELLOW}[FLATPAK GROUP INSTALL]${NC} Installing Flatpak: ${BOLD}${pkg}${NC}"
              flatpak install -y flathub "$pkg" 2>/dev/null || echo -e "    -> ${RED}[ERROR]${NC} Failed to install Flatpak: ${pkg}"
            else
              echo -e "    -> ${GREEN}[FLATPAK VERIFIED]${NC} Flatpak '${pkg}' is present."
            fi
            ((flatpak_matched_count++))
          fi
        done
      fi
    fi
  done < "${CONF_DIR}/group-apps.conf"

  echo -e "  ${GREEN}[STATUS] group-apps.conf synced successfully (${dnf_matched_count} DNF rules, ${flatpak_matched_count} Flatpak rules evaluated).${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] group-apps.conf not found.${NC}\n"
fi

echo -e "${BOLD}${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}         ALL SYSTEM & APP POLICIES SYNCHRONIZED SUCCESSFULLY          ${NC}"
echo -e "${BOLD}${GREEN}======================================================================${NC}\n"