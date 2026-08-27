#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Policy Enforcement & Permission Engine
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
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK[[:space:]]*PACKAGES[[:space:]]*--- || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      mode="flatpak"
      continue
    fi

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

# Collect all allowed software across compulsory, allowed, and group configs
ALL_ALLOWED_DNF=()
ALL_ALLOWED_FLATPAK=()

collect_allowed_apps() {
  local file="$1"
  [ ! -f "$file" ] && return 0

  parse_config_file "$file"
  ALL_ALLOWED_DNF+=("${dnf_apps[@]:-}")
  ALL_ALLOWED_FLATPAK+=("${flatpak_apps[@]:-}")
}

# ------------------------------------------------------------------------------
# 1. Process Compulsory Apps
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[1/4] Processing compulsory-apps.conf...${NC}"
if [ -f "${CONF_DIR}/compulsory-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/compulsory-apps.conf"

  for pkg in "${dnf_apps[@]:-}"; do
    if ! rpm -qa "$pkg" 2>/dev/null | grep -q .; then
      echo -e "  -> ${YELLOW}[DNF INSTALL]${NC} Installing missing mandatory package: ${BOLD}${pkg}${NC}"
      dnf install -y "$pkg" 2>/dev/null || echo -e "  -> ${RED}[ERROR]${NC} Failed to install DNF package: ${pkg}"
    else
      echo -e "  -> ${GREEN}[DNF VERIFIED]${NC} Native package '${pkg}' is present."
    fi
  done

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

  # Extract and block all packages belonging to the DNF 'games' group
  echo -e "  -> ${CYAN}[DNF GROUP PARSE]${NC} Querying and blocking all packages from 'games' package group..."
  GAMES_PKGS=$(dnf group info games 2>/dev/null | awk -F':' '/(Mandatory|Default|Optional) packages/ {flag=1; next} /^[A-Z][a-zA-Z0-9 ]*:/ {flag=0} flag && NF {print $NF}' | tr -d ' ' | sort -u || true)
  for gpkg in $GAMES_PKGS; do
    [ -z "$gpkg" ] && continue
    dnf_apps+=("$gpkg")
  done

  # Remove duplicates across explicit config entries and parsed group packages
  dnf_apps=($(echo "${dnf_apps[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

  EXCLUDE_LIST=""
  for pkg in "${dnf_apps[@]:-}"; do
    EXCLUDE_LIST="${EXCLUDE_LIST} ${pkg}"
    if rpm -qa "$pkg" 2>/dev/null | grep -q .; then
      echo -e "  -> ${RED}[DNF REMOVE]${NC} Removing blacklisted DNF package/pattern: ${BOLD}${pkg}${NC}"
      dnf remove -y "$pkg" 2>/dev/null || true
    fi
  done

  if [ -n "$EXCLUDE_LIST" ]; then
    sed -i '/^excludepkgs=/d' /etc/dnf/dnf.conf 2>/dev/null || true
    echo "excludepkgs=${EXCLUDE_LIST}" >> /etc/dnf/dnf.conf
    echo -e "  -> ${GREEN}[DNF POLICY]${NC} Exclude list written to /etc/dnf/dnf.conf (${#dnf_apps[@]} blocked DNF packages/patterns)."
  fi

  # Query and extract game Flatpaks via flatpak search & AppStream XML metadata
  echo -e "  -> ${CYAN}[FLATPAK SEARCH & APPSTREAM PARSE]${NC} Discovering all game Flatpak application IDs..."
  
  # 1. Parse Flatpaks from AppStream metadata XML (<category>Game</category>)
  if command -v python3 &>/dev/null; then
    DYNAMIC_FP_GAMES=$(python3 -c '
import glob, xml.etree.ElementTree as ET
games = set()
for path in glob.glob("/var/lib/flatpak/appstream/**/appstream.xml", recursive=True):
    try:
        tree = ET.parse(path)
        for comp in tree.getroot().findall("component"):
            cats = [c.text for c in comp.findall("categories/category") if c.text]
            if "Game" in cats or "Games" in cats:
                app_id = comp.find("id")
                if app_id is not None and app_id.text:
                    games.add(app_id.text.removesuffix(".desktop"))
    except Exception:
        pass
print("\n".join(games))
' 2>/dev/null || true)
    for fp_game in $DYNAMIC_FP_GAMES; do
      [ -z "$fp_game" ] && continue
      flatpak_apps+=("$fp_game")
    done
  fi

  # 2. Parse Flatpaks from flatpak search
  if command -v flatpak &>/dev/null; then
    SEARCH_FP_GAMES=$(flatpak search game 2>/dev/null | awk -F'\t' '{print $3}' | grep -v '^$' || true)
    for s_game in $SEARCH_FP_GAMES; do
      [ -z "$s_game" ] && continue
      flatpak_apps+=("$s_game")
    done
  fi

  # Remove duplicates across explicit config entries and dynamically discovered game Flatpaks
  flatpak_apps=($(echo "${flatpak_apps[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

  # Uninstall blacklisted Flatpaks across system and user installations
  for app in "${flatpak_apps[@]:-}"; do
    if flatpak list --app --columns=application 2>/dev/null | grep -q -i -E "^${app}$"; then
      echo -e "  -> ${RED}[FLATPAK UNINSTALL]${NC} Uninstalling blacklisted Flatpak: ${BOLD}${app}${NC}"
      flatpak uninstall -y --system "$app" 2>/dev/null || true
      flatpak uninstall -y --user "$app" 2>/dev/null || true
    fi
  done

  # Apply Flatpak Masking to block installation & auto-updates for all blocked Flatpaks
  if command -v flatpak &>/dev/null && [ ${#flatpak_apps[@]} -gt 0 ]; then
    echo -e "  -> ${GREEN}[FLATPAK MASK]${NC} Enforcing flatpak mask rules for ${#flatpak_apps[@]} blocked applications..."
    for app in "${flatpak_apps[@]}"; do
      flatpak mask --system "$app" 2>/dev/null || true
    done
  fi

  echo -e "  ${GREEN}[STATUS] blocked-apps.conf synced successfully (${#dnf_apps[@]} DNF, ${#flatpak_apps[@]} Flatpak blocked & masked).${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] blocked-apps.conf not found.${NC}\n"
fi

# ------------------------------------------------------------------------------
# 3. Process Allowed Apps & Generate Dynamic Permissions
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[3/4] Processing allowed-apps.conf & generating permission policies...${NC}"

collect_allowed_apps "${CONF_DIR}/compulsory-apps.conf"
collect_allowed_apps "${CONF_DIR}/allowed-apps.conf"

# Remove duplicate entries
ALLOWED_DNF_UNIQUE=($(echo "${ALL_ALLOWED_DNF[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
ALLOWED_FLATPAK_UNIQUE=($(echo "${ALL_ALLOWED_FLATPAK[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# A. Generate Dynamic Flatpak Polkit Rule
POLKIT_FLATPAK_RULE="/etc/polkit-1/rules.d/45-ad-dms-flatpak-allowlist.rules"
mkdir -p /etc/polkit-1/rules.d

FLATPAK_JS_ARRAY=""
for fp in "${ALLOWED_FLATPAK_UNIQUE[@]:-}"; do
  [ -z "$fp" ] && continue
  FLATPAK_JS_ARRAY="${FLATPAK_JS_ARRAY}\"${fp}\", "
done
FLATPAK_JS_ARRAY="${FLATPAK_JS_ARRAY%, }"

cat <<EOF > "$POLKIT_FLATPAK_RULE"
/* Dynamically generated by AD-DMS Policy Engine */
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.Flatpak.app-install" ||
         action.id == "org.freedesktop.Flatpak.runtime-install") && subject.active) {
        var ref = action.lookup("app_ref");
        if (ref) {
            /* Allow all runtime dependencies automatically */
            if (ref.indexOf("runtime/") === 0) {
                return polkit.Result.YES;
            }
            var allowedApps = [ ${FLATPAK_JS_ARRAY} ];
            for (var i = 0; i < allowedApps.length; i++) {
                if (ref.indexOf("app/" + allowedApps[i] + "/") === 0) {
                    return polkit.Result.YES;
                }
            }
        }
        /* Demand admin auth for unapproved Flatpaks */
        if (!subject.isInGroup("wheel") && subject.user != "root") {
            return polkit.Result.AUTH_ADMIN;
        }
    }
});
EOF
echo -e "  -> ${GREEN}[POLKIT DYNAMIC]${NC} Flatpak passwordless rules updated for ${#ALLOWED_FLATPAK_UNIQUE[@]} allowed apps."

# B. Generate Dynamic DNF Sudoers Rule
SUDOERS_FILE="/etc/sudoers.d/99-ad-dms-dnf-updates"
DNF_CMD_RULES="/usr/local/bin/refresh, /usr/bin/dnf update, /usr/bin/dnf update -y, /usr/bin/dnf upgrade, /usr/bin/dnf upgrade -y, /usr/bin/dnf5 update, /usr/bin/dnf5 update -y, /usr/bin/dnf5 upgrade, /usr/bin/dnf5 upgrade --refresh -y, /usr/bin/dnf5 upgrade -y"

for pkg in "${ALLOWED_DNF_UNIQUE[@]:-}"; do
  [ -z "$pkg" ] && continue
  DNF_CMD_RULES="${DNF_CMD_RULES}, /usr/bin/dnf install ${pkg}, /usr/bin/dnf install -y ${pkg}, /usr/bin/dnf5 install ${pkg}, /usr/bin/dnf5 install -y ${pkg}"
done

cat <<EOF > "$SUDOERS_FILE"
# Dynamically generated by AD-DMS Policy Engine
ALL ALL=(ALL) NOPASSWD: ${DNF_CMD_RULES}
EOF
chmod 0440 "$SUDOERS_FILE"
echo -e "  -> ${GREEN}[SUDOERS DYNAMIC]${NC} DNF passwordless install privileges updated for ${#ALLOWED_DNF_UNIQUE[@]} allowed packages."
echo -e "  ${GREEN}[STATUS] allowed-apps.conf synced successfully.${NC}\n"

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
        if [ "$mode" = "dnf" ]; then
          echo -e "  -> ${YELLOW}[DNF GROUP MATCH]${NC} Hostname matches lab pattern: ${BOLD}${pattern}${NC}"
        else
          echo -e "  -> ${YELLOW}[FLATPAK GROUP MATCH]${NC} Hostname matches lab pattern: ${BOLD}${pattern}${NC}"
        fi

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
