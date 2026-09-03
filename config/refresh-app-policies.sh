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

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

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
echo -e "${BOLD}${CYAN}[2/4] Processing blocked-apps.conf & generating system exclusions...${NC}"
if [ -f "${CONF_DIR}/blocked-apps.conf" ]; then
  parse_config_file "${CONF_DIR}/blocked-apps.conf"

  # Load dynamically cached game packages/flatpaks if generated
  CACHE_FILE="${CONF_DIR}/.blocked-games-cache.conf"
  if [ -f "$CACHE_FILE" ]; then
    parse_config_file "$CACHE_FILE"
  fi

  # 1. Background game group & Flatpak game discovery (runs fast or asynchronous cache update)
  (
    TEMP_DISCOVERED="/tmp/ad-dms-discovered-games.tmp"
    rm -f "$TEMP_DISCOVERED"
    
    # Query DNF games group
    G_PKGS=$(dnf group info games 2>/dev/null | awk -F':' '/(Mandatory|Default|Optional) packages/ {flag=1; next} /^[A-Z][a-zA-Z0-9 ]*:/ {flag=0} flag && NF {print $NF}' | tr -d ' ' | sort -u || true)
    
    # Query Flatpak AppStream Game category & search
    FP_GAMES=""
    if command -v python3 &>/dev/null; then
      FP_GAMES=$(python3 -c '
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
    fi

    if [ -n "$G_PKGS" ] || [ -n "$FP_GAMES" ]; then
      {
        echo "# Auto-generated Games Blocklist Cache"
        for p in $G_PKGS; do echo "$p"; done
        echo ""
        echo "# --- FLATPAK PACKAGES ---"
        for f in $FP_GAMES; do echo "$f"; done
      } > "$TEMP_DISCOVERED"
      mv -f "$TEMP_DISCOVERED" "$CACHE_FILE" 2>/dev/null || true
    fi
  ) &>/dev/null &

  # Remove duplicates across explicit config entries and cached discoveries
  dnf_apps=($(echo "${dnf_apps[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
  flatpak_apps=($(echo "${flatpak_apps[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

  # 2. Fast Bulk Removal of installed blacklisted RPMs with visual progress indicator
  echo -ne "  -> ${CYAN}[SCANNING RPMs]${NC} Checking ${#dnf_apps[@]} package rules against local RPM database... "
  ALL_INSTALLED_QUERY=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)
  INSTALLED_RPMS=()
  for pkg in "${dnf_apps[@]:-}"; do
    [ -z "$pkg" ] && continue
    # Handle wildcards or exact package match cleanly against cached list
    if [[ "$pkg" == *"*"* ]]; then
      matched=$(echo "$ALL_INSTALLED_QUERY" | grep -E "^${pkg//\*/.*}$" || true)
      for m in $matched; do [ -n "$m" ] && INSTALLED_RPMS+=("$m"); done
    else
      if echo "$ALL_INSTALLED_QUERY" | grep -q -x "$pkg"; then
        INSTALLED_RPMS+=("$pkg")
      fi
    fi
  done
  echo -e "${GREEN}[DONE]${NC}"

  if [ ${#INSTALLED_RPMS[@]} -gt 0 ]; then
    # Deduplicate matches
    INSTALLED_RPMS=($(echo "${INSTALLED_RPMS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    echo -e "  -> ${RED}[DNF REMOVE]${NC} Purging ${#INSTALLED_RPMS[@]} blacklisted package(s): ${INSTALLED_RPMS[*]}"
    dnf remove -y "${INSTALLED_RPMS[@]}" 2>/dev/null || true
  fi

  # 3. Synchronize DNF exclude rules in /etc/dnf/dnf.conf
  EXCLUDE_LIST="${dnf_apps[*]:-}"
  if [ -n "$EXCLUDE_LIST" ]; then
    sed -i '/^excludepkgs=/d' /etc/dnf/dnf.conf 2>/dev/null || true
    echo "excludepkgs=${EXCLUDE_LIST}" >> /etc/dnf/dnf.conf
    echo -e "  -> ${GREEN}[DNF POLICY]${NC} Exclude list written to /etc/dnf/dnf.conf (${#dnf_apps[@]} blocked DNF items)."
  fi

  # 4. Fast Flatpak Blacklist Removal & Process Termination
  echo -ne "  -> ${CYAN}[SCANNING FLATPAKS]${NC} Checking installed Flatpaks across system & user scopes... "
  CURRENT_FPS=$(flatpak list --app --columns=application 2>/dev/null || true)
  echo -e "${GREEN}[DONE]${NC}"
  for app in "${flatpak_apps[@]:-}"; do
    [ -z "$app" ] && continue
    if echo "$CURRENT_FPS" | grep -q -i -E "^${app}$"; then
      echo -e "  -> ${RED}[FLATPAK TERMINATE & UNINSTALL]${NC} Killing & removing blacklisted Flatpak: ${BOLD}${app}${NC}"
      flatpak kill "$app" 2>/dev/null || true
      flatpak uninstall -y --system "$app" 2>/dev/null || true
      flatpak uninstall -y --user "$app" 2>/dev/null || true
    fi
  done

  echo -e "  ${GREEN}[STATUS] blocked-apps.conf synced successfully (${#dnf_apps[@]} DNF, ${#flatpak_apps[@]} Flatpak blocked).${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] blocked-apps.conf not found.${NC}\n"
fi

# ------------------------------------------------------------------------------
# 3. Process Allowed Apps & Deploy Custom 'install' CLI and User-Level Policies
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}[3/4] Processing allowed-apps.conf & deploying permission policies...${NC}"

collect_allowed_apps "${CONF_DIR}/compulsory-apps.conf"
collect_allowed_apps "${CONF_DIR}/allowed-apps.conf"

# Remove duplicate entries
ALLOWED_DNF_UNIQUE=($(echo "${ALL_ALLOWED_DNF[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
ALLOWED_FLATPAK_UNIQUE=($(echo "${ALL_ALLOWED_FLATPAK[@]:-}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# A. Allow user-level Flatpak installation without admin password via Polkit
POLKIT_FLATPAK_RULE="/etc/polkit-1/rules.d/45-ad-dms-flatpak-allowlist.rules"
mkdir -p /etc/polkit-1/rules.d

cat <<'EOF' > /etc/polkit-1/rules.d/10-ad-admin-auth.rules
/* Allow wheel group, root, and Domain Admins to authenticate for administrative actions in GUI & Polkit */
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:wheel", "unix-group:Domain Admins", "unix-group:domain admins", "unix-user:root"];
});
EOF

cat <<'EOF' > "$POLKIT_FLATPAK_RULE"
/* Allow active users to install/manage user-level Flatpaks without root password */
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.Flatpak.app-install" ||
         action.id == "org.freedesktop.Flatpak.runtime-install" ||
         action.id == "org.freedesktop.Flatpak.app-uninstall" ||
         action.id == "org.freedesktop.Flatpak.modify-repo") && subject.active) {
        return polkit.Result.YES;
    }
});
EOF
echo -e "  -> ${GREEN}[POLKIT DYNAMIC]${NC} User-level Flatpak & Domain Admin authorization rules active."

# B. Generate Dynamic DNF Sudoers Rule for System Updates, 'install' and background scanner
SUDOERS_FILE="/etc/sudoers.d/99-ad-dms-dnf-updates"
cat <<'EOF' > "$SUDOERS_FILE"
# Dynamically generated by AD-DMS Policy Engine
ALL ALL=(ALL) NOPASSWD: /usr/local/bin/refresh, /usr/bin/dnf update, /usr/bin/dnf update -y, /usr/bin/dnf upgrade, /usr/bin/dnf upgrade -y, /usr/bin/dnf5 update, /usr/bin/dnf5 update -y, /usr/bin/dnf5 upgrade, /usr/bin/dnf5 upgrade --refresh -y, /usr/bin/dnf5 upgrade -y, /usr/local/bin/ad-dms-backend-install *, /usr/local/bin/ad-dms-record-violation *
EOF
chmod 0440 "$SUDOERS_FILE"
echo -e "  -> ${GREEN}[SUDOERS DYNAMIC]${NC} Secure DNF management privileges configured."

# C. Deploy Backend Privileged Installer (/usr/local/bin/ad-dms-backend-install)
cat <<'EOF' > /usr/local/bin/ad-dms-backend-install
#!/usr/bin/env bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi
exec dnf install -y "$@"
EOF
chmod +x /usr/local/bin/ad-dms-backend-install

# C2. Deploy Secure Violation Counter & Audio Siren Engine (/usr/local/bin/ad-dms-record-violation)
mkdir -p /var/log/ad-dms-violations
chmod 0755 /var/log/ad-dms-violations

cat <<'EOF' > /usr/local/bin/ad-dms-record-violation
#!/usr/bin/env bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

TARGET_USER="${1:-nobody}"
ACTION_OR_ITEM="${2:-unknown}"
REASON="${3:-policy_violation}"

TRACK_FILE="/var/log/ad-dms-violations/${TARGET_USER}.count"
LOG_FILE="/var/log/ad-dms-violations/audit.log"

# Administrative manual adjustment of violation counter (e.g., ad-dms-record-violation user --set 0)
if [ "${2:-}" = "--set" ] || [ "${2:-}" = "set" ]; then
  new_val="${3:-0}"
  echo "$new_val" > "$TRACK_FILE"
  chmod 0644 "$TRACK_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ADMIN RESET | User: ${TARGET_USER} | Reset to: ${new_val}" >> "$LOG_FILE"
  echo "Violation count for '${TARGET_USER}' updated to: ${new_val}"
  exit 0
fi

if [ "${2:-}" = "--get" ] || [ "${2:-}" = "get" ]; then
  count=0
  [ -f "$TRACK_FILE" ] && count=$(cat "$TRACK_FILE" 2>/dev/null || echo 0)
  echo "$count"
  exit 0
fi

count=0
[ -f "$TRACK_FILE" ] && count=$(cat "$TRACK_FILE" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$TRACK_FILE"
chmod 0644 "$TRACK_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] User: ${TARGET_USER} | Count: ${count} | Item: ${ACTION_OR_ITEM} | Reason: ${REASON}" >> "$LOG_FILE"

# Sound alert: if user has violated policy > 3 times, play Siren.mp3 at 100% volume
if [ "$count" -gt 3 ]; then
  (
    # Set volume to 100% (PipeWire / ALSA)
    if command -v wpctl &>/dev/null; then
      wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 2>/dev/null || true
      wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true
    fi
    if command -v pactl &>/dev/null; then
      pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true
      pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null || true
    fi
    if command -v amixer &>/dev/null; then
      amixer set Master 100% unmute 2>/dev/null || true
    fi

    SIREN_FILE="/etc/ad-dms/assets/Siren.mp3"
    [ ! -f "$SIREN_FILE" ] && SIREN_FILE="/home/jk/Projects/fedora-ad-dms/assets/Siren.mp3"
    
    if [ -f "$SIREN_FILE" ]; then
      if command -v mpv &>/dev/null; then
        timeout 8 mpv --no-video --volume=100 "$SIREN_FILE" &>/dev/null || true
      elif command -v ffplay &>/dev/null; then
        timeout 8 ffplay -nodisp -autoexit -volume 100 "$SIREN_FILE" &>/dev/null || true
      elif command -v cvlc &>/dev/null; then
        timeout 8 cvlc --play-and-exit --gain 1.0 "$SIREN_FILE" &>/dev/null || true
      elif command -v gst-play-1.0 &>/dev/null; then
        timeout 8 gst-play-1.0 --volume 1.0 "$SIREN_FILE" &>/dev/null || true
      elif command -v paplay &>/dev/null; then
        paplay "$SIREN_FILE" 2>/dev/null || true
      fi
    fi

    # Fallback to loud sine tone beeper if no media player was available
    if command -v speaker-test &>/dev/null; then
      timeout 2 speaker-test -t sine -f 1200 -l 3 &>/dev/null || true
    fi
  ) &>/dev/null &
fi

echo "$count"
EOF
chmod +x /usr/local/bin/ad-dms-record-violation

# D. Deploy Universal User CLI Command: 'install' (/usr/local/bin/install)
cat <<'EOF' > /usr/local/bin/install
#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Universal Application Installation Engine
# Usage:
#   install <package_name>           (Installs native DNF/RPM package)
#   install flatpak <app_id>         (Installs User-Level Flatpak application)
# ==============================================================================
set -euo pipefail

CONF_DIR="/etc/ad-dms"
DOMAIN_CONF="${CONF_DIR}/domain.conf"
[ -f "$DOMAIN_CONF" ] || DOMAIN_CONF="/tmp/fedora-ad-dms/domain.conf"

BLOCK_NOTIF_TITLE="Unauthorized Application Blocked"
BLOCK_NOTIF_MSG="Access Denied: This application is blacklisted under University IT Policy and has been terminated and removed."
ACADEMIC_WARNING_MSG="WARNING: This software is not pre-approved. If this package is found to be non-academic or violates institution policy, strict disciplinary action will be initiated."

if [ -f "$DOMAIN_CONF" ]; then
  # shellcheck source=/dev/null
  source "$DOMAIN_CONF" 2>/dev/null || true
  BLOCK_NOTIF_TITLE="${BLOCK_NOTIFICATION_TITLE:-$BLOCK_NOTIF_TITLE}"
  BLOCK_NOTIF_MSG="${BLOCK_NOTIFICATION_MSG:-$BLOCK_NOTIF_MSG}"
  ACADEMIC_WARNING_MSG="${ACADEMIC_WARNING_MSG:-$ACADEMIC_WARNING_MSG}"
fi

# ANSI Colors
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
MAGENTA="\033[1;35m"
NC="\033[0m"

CURRENT_ACT_USER="${USER:-$(id -un 2>/dev/null || echo 'user')}"

# Pretty Box Banner Helper
draw_box_header() {
  local title="$1"
  local color="${2:-$CYAN}"
  echo -e "\n${color}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  printf "${color}║${NC} ${BOLD}%-72s${NC} ${color}║${NC}\n" "  $title"
  echo -e "${color}╚══════════════════════════════════════════════════════════════════════════╝${NC}\n"
}

if [ $# -lt 1 ]; then
  draw_box_header "AD-DMS APPLICATION INSTALLER" "$CYAN"
  echo -e "  ${BOLD}Usage:${NC}"
  echo -e "    install ${GREEN}<package_name>${NC}           (Install native DNF package)"
  echo -e "    install flatpak ${GREEN}<appstream_id>${NC}  (Install user-level Flatpak app)\n"
  exit 1
fi

MODE="dnf"
PACKAGES=()

if [ "$1" = "flatpak" ]; then
  MODE="flatpak"
  shift
  PACKAGES=("$@")
else
  PACKAGES=("$@")
fi

if [ ${#PACKAGES[@]} -eq 0 ]; then
  echo -e "  ${RED}[ERROR] No package or application name specified.${NC}\n" >&2
  exit 1
fi

# Helper: Resolve human-readable application title from AppStream or RPM
resolve_display_name() {
  local raw_id="$1"
  local mode="$2"
  local found_title=""

  if [ "$mode" = "flatpak" ]; then
    found_title=$(python3 -c "
import glob, xml.etree.ElementTree as ET
target = '$raw_id'.lower().removesuffix('.desktop')
title = ''
for path in glob.glob('/var/lib/flatpak/appstream/**/appstream.xml', recursive=True):
    try:
        tree = ET.parse(path)
        for comp in tree.getroot().findall('component'):
            aid = comp.find('id')
            if aid is not None and aid.text and aid.text.lower().removesuffix('.desktop') == target:
                name_elem = comp.find('name')
                if name_elem is not None and name_elem.text:
                    title = name_elem.text
                    break
        if title: break
    except Exception: pass
print(title)
" 2>/dev/null || true)
  fi

  if [ -z "$found_title" ] && [ "$mode" = "dnf" ]; then
    found_title=$(rpm -q --qf '%{SUMMARY}' "$raw_id" 2>/dev/null || true)
  fi

  if [ -z "$found_title" ] || [[ "$found_title" == *"not installed"* ]]; then
    found_title="$raw_id"
  fi
  echo "$found_title"
}

# Load Policy Lists
parse_list() {
  local file="$1"
  local target_mode="$2"
  local current_mode="dnf"
  local items=()
  [ ! -f "$file" ] && return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      current_mode="flatpak"
      continue
    fi
    [[ -z "$line" || "$line" =~ ^# || "$line" =~ = ]] && continue
    if [ "$current_mode" = "$target_mode" ]; then
      items+=("$line")
    fi
  done < "$file"
  echo "${items[@]:-}"
}

BLOCKED_ITEMS=($(parse_list "${CONF_DIR}/blocked-apps.conf" "$MODE") $(parse_list "${CONF_DIR}/.blocked-games-cache.conf" "$MODE"))
ALLOWED_ITEMS=($(parse_list "${CONF_DIR}/allowed-apps.conf" "$MODE"))
COMPULSORY_ITEMS=($(parse_list "${CONF_DIR}/compulsory-apps.conf" "$MODE"))

send_violation_notification() {
  local raw_id="$1"
  local pretty_name
  pretty_name=$(resolve_display_name "$raw_id" "$MODE")
  
  # Record violation in secure counter
  local vcount=1
  if [ -x /usr/local/bin/ad-dms-record-violation ]; then
    vcount=$(sudo /usr/local/bin/ad-dms-record-violation "$CURRENT_ACT_USER" "$raw_id" "blacklisted_install_attempt" 2>/dev/null || echo 1)
  fi

  draw_box_header "SECURITY VIOLATION DETECTED" "$RED"
  echo -e "  ${RED}■ Action Blocked:${NC}   ${BLOCK_NOTIF_TITLE}"
  echo -e "  ${RED}■ Application:${NC}      ${BOLD}${pretty_name}${NC} (${raw_id})"
  echo -e "  ${RED}■ Notice:${NC}           ${BLOCK_NOTIF_MSG}"
  echo -e "  ${RED}■ Infraction Count:${NC} ${BOLD}Violation #${vcount} recorded for user '${CURRENT_ACT_USER}'${NC}"
  
  if [ "$vcount" -gt 3 ]; then
    echo -e "  ${YELLOW}■ Security Alert:${NC}   ${BOLD}${RED}MULTIPLE POLICY VIOLATIONS DETECTED (Audible Siren Triggered)${NC}"
  fi
  echo -e "${RED}══════════════════════════════════════════════════════════════════════════${NC}\n"
  
  if command -v notify-send &>/dev/null; then
    notify-send -u critical -i dialog-error "$BLOCK_NOTIF_TITLE" "Access Denied: ${pretty_name} is blacklisted under University IT Policy." 2>/dev/null || true
  fi
}

post_flatpak_scan_and_enforce() {
  local app_name="$1"
  for blocked in "${BLOCKED_ITEMS[@]}"; do
    [ -z "$blocked" ] && continue
    if [[ "$app_name" == *"$blocked"* ]] || [[ "$blocked" == *"$app_name"* ]]; then
      flatpak kill "$app_name" 2>/dev/null || true
      flatpak uninstall -y --user "$app_name" 2>/dev/null || true
      flatpak uninstall -y --system "$app_name" 2>/dev/null || true
      send_violation_notification "$app_name"
      exit 1
    fi
  done
}

# Check if current user is an administrator (root, wheel member, or Domain Admin)
IS_ADMIN=false
if [ "$EUID" -eq 0 ] || groups "$CURRENT_ACT_USER" 2>/dev/null | grep -q -E '(wheel|Domain Admins|domain admins)' || [ "$CURRENT_ACT_USER" = "root" ]; then
  IS_ADMIN=true
fi

for pkg in "${PACKAGES[@]}"; do
  # Administrators are exempted from academic restriction prompts & blocks
  if [ "$IS_ADMIN" = true ]; then
    draw_box_header "ADMINISTRATIVE INSTALLATION: ${pkg}" "$MAGENTA"
    echo -e "  -> ${MAGENTA}[ADMIN BYPASS]${NC} Administrator privileges verified for '${CURRENT_ACT_USER}'."
    if [ "$MODE" = "dnf" ]; then
      sudo dnf install -y "$pkg"
    else
      flatpak install -y flathub "$pkg"
    fi
    echo -e "\n  ${GREEN}[SUCCESS]${NC} ${pkg} installed successfully.\n"
    continue
  fi

  is_blocked=false
  is_allowed=false
  is_compulsory=false

  for b in "${BLOCKED_ITEMS[@]}"; do
    if [ -n "$b" ] && [[ "$pkg" == "$b" || "$pkg" == *"$b"* ]]; then
      is_blocked=true
      break
    fi
  done

  for a in "${ALLOWED_ITEMS[@]}"; do
    if [ -n "$a" ] && [ "$pkg" = "$a" ]; then
      is_allowed=true
      break
    fi
  done

  for c in "${COMPULSORY_ITEMS[@]}"; do
    if [ -n "$c" ] && [ "$pkg" = "$c" ]; then
      is_compulsory=true
      break
    fi
  done

  # Case 1: Blocked (yes / no / no) -> Block & Warn
  if [ "$is_blocked" = true ]; then
    send_violation_notification "$pkg"
    exit 1
  fi

  # Case 2: Allowed (no / yes / no) OR Compulsory (no / no / yes) -> Passwordless Install
  if [ "$is_allowed" = true ] || [ "$is_compulsory" = true ]; then
    draw_box_header "INSTALLING APPROVED PACKAGE: ${pkg}" "$GREEN"
    echo -e "  -> ${GREEN}[STATUS]${NC} Whitelist match verified. Installing passwordlessly..."
    if [ "$MODE" = "dnf" ]; then
      sudo /usr/local/bin/ad-dms-backend-install "$pkg"
    else
      flatpak install --user -y flathub "$pkg"
      post_flatpak_scan_and_enforce "$pkg"
    fi
    echo -e "\n  ${GREEN}[SUCCESS]${NC} ${pkg} installed successfully.\n"
    continue
  fi

  # Case 3: Unapproved Software (no / no / no) -> Warn & Request Authentication
  disp_name=$(resolve_display_name "$pkg" "$MODE")
  draw_box_header "UNAPPROVED APPLICATION DETECTED" "$YELLOW"
  echo -e "  ${YELLOW}■ Requested Package:${NC} ${BOLD}${disp_name}${NC} (${pkg})"
  echo -e "  ${YELLOW}■ Institutional Note:${NC} ${ACADEMIC_WARNING_MSG}\n"

  echo -en "  ${BOLD}${YELLOW}[?] Confirm this application is strictly for academic coursework? [y/N]: ${NC}"
  read -r user_confirm
  case "$user_confirm" in
    [Yy]*) ;;
    *) echo -e "\n  ${RED}[ABORTED] Installation cancelled by user.${NC}\n"; exit 1 ;;
  esac

  echo -e "\n  -> ${CYAN}[AUTHENTICATION REQUIRED]${NC} Please enter administrative password:"
  if [ "$MODE" = "dnf" ]; then
    sudo -k
    sudo dnf install "$pkg"
  else
    flatpak install --user flathub "$pkg"
    post_flatpak_scan_and_enforce "$pkg"
  fi
  echo -e "\n  ${GREEN}[SUCCESS]${NC} ${pkg} installation completed.\n"
done
EOF
chmod +x /usr/local/bin/install
echo -e "  -> ${GREEN}[CLI INSTALLED]${NC} Universal user installation utility active at /usr/local/bin/install"

# Deploy /usr/local/bin/refresh utility command
cat <<'REFRESH_UTIL_EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
set -euo pipefail

# Support checking remaining timer interval without root privileges
if [ "${1:-}" = "-t" ] || [ "${1:-}" = "--t" ] || [ "${1:-}" = "--time" ] || [ "${1:-}" = "-time" ]; then
  if systemctl is-active --quiet ad-dms-refresh.timer 2>/dev/null; then
    TIMER_INFO=$(systemctl list-timers ad-dms-refresh.timer --no-pager 2>/dev/null | grep -E "ad-dms-refresh\.timer" || true)
    LEFT_TIME=$(echo "$TIMER_INFO" | awk '{print $3}' || echo "unknown")
    NEXT_DATE=$(echo "$TIMER_INFO" | awk '{print $1, $2}' || echo "unknown")
    echo -e "\033[1;36m[AD-DMS TIMER]\033[0m Next policy refresh scheduled in: \033[1;32m${LEFT_TIME}\033[0m (Next run: ${NEXT_DATE})"
  else
    echo -e "\033[1;33m[AD-DMS TIMER]\033[0m ad-dms-refresh.timer is currently inactive or not installed."
  fi
  exit 0
fi

# Support checking which service/source was used previously & live ping/probe status
if [ "${1:-}" = "-s" ] || [ "${1:-}" = "--s" ] || [ "${1:-}" = "-status" ] || [ "${1:-}" = "--status" ] || [ "${1:-}" = "-source" ] || [ "${1:-}" = "--source" ] || [ "${1:-}" = "-p" ] || [ "${1:-}" = "--p" ] || [ "${1:-}" = "-ping" ] || [ "${1:-}" = "--ping" ]; then
  echo -e "\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[1;36m║\033[0m                  \033[1;33mAD-DMS POLICY SOURCE & HOST PROBE STATUS\033[0m                \033[1;36m║\033[0m"
  echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m"

  CONF_DIR="/etc/ad-dms"
  SOURCE_LOG="${CONF_DIR}/.last_source"
  
  if [ -f "$SOURCE_LOG" ]; then
    echo -e "  \033[1;36m[PREVIOUS SYNC SOURCE]\033[0m \033[1;32m$(cat "$SOURCE_LOG")\033[0m"
  else
    echo -e "  \033[1;36m[PREVIOUS SYNC SOURCE]\033[0m \033[1;33mNo sync record yet\033[0m"
  fi

  # Load intranet and main host configuration from domain.conf (or local workspace)
  INTRANET_HOST="GSFCUPLLAB203"
  INTRANET_IP="10.205.18.253"
  INTRANET_PORT="8080"
  if [ -f "/domain.conf" ]; then
    # shellcheck source=/dev/null
    source "/domain.conf" 2>/dev/null || true
    INTRANET_HOST=""
    INTRANET_IP=""
    INTRANET_PORT="8080"
  elif [ -f "/home/jk/Projects/fedora-ad-dms/domain.conf" ]; then
    source "/home/jk/Projects/fedora-ad-dms/domain.conf" 2>/dev/null || true
    INTRANET_HOST=""
    INTRANET_IP=""
    INTRANET_PORT="8080"
  fi

  MY_CURR_HOST="GSFCUPLLAB203"
  echo -e "
  [1;36m[MAIN HOST DEVICE TARGET][0m [1;37m[0m (Fallback IP: None, Port: )"

  echo -e "
  [1;36m[ICMP PING PROBE][0m Pinging main host device..."
  ping_ok=false
  for ping_target in "127.0.0.1" "" ".local" ".gsfcu.local"; do
    # Only test 127.0.0.1 if current machine is the intranet host
    if [ "" = "127.0.0.1" ]; then
      if [ "" != "" ]; then
        continue
      fi
    fi
    if ping -c 1 -W 1 "" >/dev/null 2>&1; then
      if [ "" = "127.0.0.1" ]; then
        echo -e "    -> [1;32m● ICMP PING SUCCESSFUL[0m (Current machine is Central Host '')"
      else
        echo -e "    -> [1;32m● ICMP PING SUCCESSFUL[0m (Host '' replied to ping)"
      fi
      ping_ok=true
      break
    fi
  done
  if [ "" = false ] && [ -n "" ]; then
    if ping -c 1 -W 1 "" >/dev/null 2>&1; then
      echo -e "    -> [1;32m● ICMP PING SUCCESSFUL[0m (Fallback IP '' replied to ping)"
      ping_ok=true
    fi
  fi
  if [ "" = false ]; then
    echo -e "    -> [1;33m○ ICMP PING UNREACHABLE[0m (Host '' did not answer ping request)"
  fi

  echo -e "
  [1;36m[HTTP SERVICE PROBE][0m Testing reachable upstream service..."
  live_found=false

  # Check localhost first if running on the host machine
  if [ "" = "" ] || ip -o a 2>/dev/null | grep -q "/"; then
    if curl -fsSL -m 2 "http://127.0.0.1:/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> [1;32m● INTRANET HOST ONLINE[0m (Local host server active on port )"
      live_found=true
    fi
  fi

  if [ "" = false ]; then
    for host_target in "" ".local" ".gsfcu.local"; do
      if curl -fsSL -m 2 "http://:/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> [1;32m● INTRANET HOST ONLINE[0m (Connected via :)"
        live_found=true
        break
      fi
    done
  fi

  if [ "" = false ] && [ -n "" ]; then
    if curl -fsSL -m 2 "http://:/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> [1;32m● INTRANET IP ONLINE[0m (Connected via :)"
      live_found=true
    fi
  fi

  if [ "" = false ]; then
    if curl -fsSL -m 3 "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/domain.conf" >/dev/null 2>&1; then
      echo -e "    -> [1;33m● GITHUB CLOUD FALLBACK[0m (Intranet offline, GitHub reachable)"
    else
      echo -e "    -> [1;31m● ALL SOURCES OFFLINE[0m (No intranet or internet connectivity)"
    fi
  fi
  echo ""
  exit 0
fi

REPO_RAW_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/config"
CONF_DIR="/etc/ad-dms"

# Load local domain configuration if present to discover intranet host
INTRANET_HOST="GSFCUPLLAB203"
INTRANET_IP="10.205.18.253"
INTRANET_PORT="8080"
USE_INTRANET="yes"

if [ -f "${CONF_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/domain.conf" 2>/dev/null || true
  INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
  INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
  INTRANET_PORT="${INTRANET_PORT:-8080}"
  USE_INTRANET="${USE_INTRANET_FIRST:-yes}"
fi

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# Detect if running in headless background mode (no TTY)
if [ ! -t 1 ]; then
  exec >> /var/log/ad-dms-refresh.log 2>&1
  echo "=== Policy Sync Started: $(date) ==="
else
  echo -e "\033[1;36m[REFETCH] Updating policy engine configuration files (Intranet First & GitHub Fallback)...\033[0m"
fi

mkdir -p "$CONF_DIR"

FILES=(
  "refresh-app-policies.sh"
  "remote-tasks.sh"
  "allowed-apps.conf"
  "blocked-apps.conf"
  "compulsory-apps.conf"
  "group-apps.conf"
  "device-rules.conf"
  "domain.conf"
  "lab.conf"
)

for file in "${FILES[@]}"; do
  [ -t 1 ] && echo -n -e "  -> Fetching: ${file}... "
  fetched=false

  # 1. Try Local Host loopback first if on the intranet host itself
  if [ "" = "yes" ]; then
    MY_CURR_HOST="GSFCUPLLAB203"
    if [ "" = "" ] || ip -o a 2>/dev/null | grep -q "/"; then
      if curl -fsSL -m 3 "http://127.0.0.1:/config/" -o "/" 2>/dev/null || curl -fsSL -m 3 "http://127.0.0.1:/" -o "/" 2>/dev/null; then
        [ -t 1 ] && echo -e "[1;32m[OK] (Intranet Localhost: 127.0.0.1)[0m"
        echo "Intranet Host (127.0.0.1:) - Synced at Thu Sep  3 10:00:30 AM IST 2026" > "/.last_source" 2>/dev/null || true
        chmod 644 "/.last_source" 2>/dev/null || true
        fetched=true
      fi
    fi
  fi

  # 1b. Try Intranet Host via Hostname (Plain, .local, and FQDN)
  if [ "" = false ] && [ "" = "yes" ]; then
    for host_target in "" ".local" ".gsfcu.local"; do
      if curl -fsSL -m 3 "http://:/config/" -o "/" 2>/dev/null || curl -fsSL -m 3 "http://:/" -o "/" 2>/dev/null; then
        [ -t 1 ] && echo -e "[1;32m[OK] (Intranet Host: )[0m"
        echo "Intranet Host (:) - Synced at Thu Sep  3 10:00:30 AM IST 2026" > "/.last_source" 2>/dev/null || true
        chmod 644 "/.last_source" 2>/dev/null || true
        fetched=true
        break
      fi
    done
  fi

  # 2. Try Intranet Host via Fallback IP
  if [ "$fetched" = false ] && [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_IP" ]; then
    if curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
      [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet IP: ${INTRANET_IP})\033[0m"
      echo "Intranet IP (${INTRANET_IP}:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
      chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
      fetched=true
    fi
  fi

  # 3. Fallback to GitHub Cloud CDN
  if [ "$fetched" = false ]; then
    if curl -fsSL "${REPO_RAW_URL}/${file}?$(date +%s)" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/${file}?$(date +%s)" -o "${CONF_DIR}/${file}" 2>/dev/null; then
      [ -t 1 ] && echo -e "\033[1;32m[OK] (GitHub Cloud)\033[0m"
      echo "GitHub Cloud (github.com/JDKamalakar/fedora-ad-dms) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
      chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
      fetched=true
    fi
  fi

  if [ "$fetched" = false ]; then
    [ -t 1 ] && echo -e "\033[1;33m[UNCHANGED / OFFLINE]\033[0m"
  fi
done

# Sync Siren alarm asset if missing or outdated
mkdir -p "${CONF_DIR}/assets"
if [ ! -f "${CONF_DIR}/assets/Siren.mp3" ]; then
  [ -t 1 ] && echo -n -e "  -> Downloading security asset: Siren.mp3... "
  if curl -fsSL -m 3 "http://${INTRANET_HOST}:${INTRANET_PORT}/assets/Siren.mp3" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null || curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/assets/Siren.mp3" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null || curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/assets/Siren.mp3?$(date +%s)" -o "${CONF_DIR}/assets/Siren.mp3" 2>/dev/null; then
    [ -t 1 ] && echo -e "\033[1;32m[OK]\033[0m"
  else
    [ -t 1 ] && echo -e "\033[1;33m[SKIP]\033[0m"
  fi
fi

# Dynamically synchronize ad-dms-refresh.timer interval if domain.conf was updated
if [ -f "${CONF_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/domain.conf" 2>/dev/null || true
  RAW_INT="${REFRESH_INTERVAL:-1h}"
  # Normalize human intervals (e.g. 1hrs -> 1h, 1hr -> 1h, 30mins -> 30m)
  NORM_INT=$(echo "$RAW_INT" | sed -E -e 's/([0-9]+)[[:space:]]*(hrs|hr|hours|hour)/\1h/g' -e 's/([0-9]+)[[:space:]]*(mins|min|minutes|minute)/\1m/g' -e 's/([0-9]+)[[:space:]]*(secs|sec|seconds|second)/\1s/g')
  
  CURRENT_TIMER_INT=$(systemctl show ad-dms-refresh.timer --property=Unit -p AccuracySec 2>/dev/null | grep -i "OnUnitActiveSec" || true)
  if [ -f /etc/systemd/system/ad-dms-refresh.timer ]; then
    cat <<TIMER_EOF > /etc/systemd/system/ad-dms-refresh.timer
[Unit]
Description=Run AD-DMS Policy Refresh Periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${NORM_INT}
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart ad-dms-refresh.timer 2>/dev/null || true
  fi
fi

chmod +x "${CONF_DIR}/"*sh 2>/dev/null || true

if [ -x "${CONF_DIR}/refresh-app-policies.sh" ]; then
  "${CONF_DIR}/refresh-app-policies.sh"
else
  echo "[ERROR] Missing executable engine script at '${CONF_DIR}/refresh-app-policies.sh'"
  exit 1
fi
REFRESH_UTIL_EOF
chmod +x /usr/local/bin/refresh
echo -e "  -> ${GREEN}[REFRESH CLI INSTALLED]${NC} Universal policy refresh utility active at /usr/local/bin/refresh"

# E. Deploy Background GUI Flatpak Scanner Daemon (/usr/local/bin/ad-dms-gui-scan)
cat <<'EOF' > /usr/local/bin/ad-dms-gui-scan
#!/usr/bin/env bash
# Automated background guard against rogue Flatpak installs via GNOME Software / KDE Discover
set -euo pipefail

CONF_DIR="/etc/ad-dms"
[ -f "${CONF_DIR}/refresh-app-policies.sh" ] || exit 0

parse_list() {
  local file="$1"
  local current_mode="dnf"
  local items=()
  [ ! -f "$file" ] && return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ "$line" =~ ^#[[:space:]]*---[[:space:]]*FLATPAK || "$line" =~ ^#[[:space:]]*FLATPAK ]]; then
      current_mode="flatpak"
      continue
    fi
    [[ -z "$line" || "$line" =~ ^# || "$line" =~ = ]] && continue
    [ "$current_mode" = "flatpak" ] && items+=("$line")
  done < "$file"
  echo "${items[@]:-}"
}

BLOCKED_FLATPAKS=($(parse_list "${CONF_DIR}/blocked-apps.conf") $(parse_list "${CONF_DIR}/.blocked-games-cache.conf"))

# Helper to find currently active graphical login users
get_active_sessions() {
  loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1, $3}' || true
}

# Collect all installed Flatpaks across system and all user homes
declare -A DETECTED_APPS

# 1. Check system-wide Flatpaks
SYS_APPS=$(flatpak list --system --app --columns=application 2>/dev/null || true)
for sa in $SYS_APPS; do
  DETECTED_APPS["$sa"]="system"
done

# 2. Check per-user flatpak installations for all active sessions / users in /home
while read -r sess_id sess_user; do
  [ -z "$sess_user" ] || [ "$sess_user" = "root" ] || [ "$sess_user" = "greeter" ] && continue
  U_UID=$(id -u "$sess_user" 2>/dev/null || true)
  [ -z "$U_UID" ] && continue
  
  # Check user flatpak exports directly on disk without PAM/su lock
  if [ -d "/home/${sess_user}/.local/share/flatpak/app" ]; then
    for u_app_dir in "/home/${sess_user}/.local/share/flatpak/app/"*; do
      if [ -d "$u_app_dir" ]; then
        ua=$(basename "$u_app_dir")
        DETECTED_APPS["$ua"]="$sess_user"
      fi
    done
  fi
  # Fast timeout-protected fallback
  USER_FLATPAKS=$(timeout 2 su - "$sess_user" -c "flatpak list --user --app --columns=application" < /dev/null 2>/dev/null || true)
  for ua in $USER_FLATPAKS; do
    DETECTED_APPS["$ua"]="$sess_user"
  done
done < <(get_active_sessions)

for b_app in "${BLOCKED_FLATPAKS[@]}"; do
  [ -z "$b_app" ] && continue
  
  # Check if blocked app is in DETECTED_APPS (or matching substring)
  for installed_id in "${!DETECTED_APPS[@]}"; do
    if [[ "$installed_id" == "$b_app" || "$installed_id" == *"$b_app"* || "$b_app" == *"$installed_id"* ]]; then
      owner_user="${DETECTED_APPS[$installed_id]}"
      [ "$owner_user" = "system" ] && owner_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 !~ /root|greeter/ {print $3; exit}' || echo "user")

      # 1. Kill running instances
      flatpak kill "$installed_id" 2>/dev/null || true
      
      # 2. Uninstall across all scopes
      flatpak uninstall -y --system "$installed_id" 2>/dev/null || true
      if [ -n "$owner_user" ] && [ "$owner_user" != "system" ]; then
        timeout 5 su - "$owner_user" -c "flatpak uninstall -y --user $installed_id" < /dev/null 2>/dev/null || true
      fi
      flatpak uninstall -y --user "$installed_id" 2>/dev/null || true

      # 3. Resolve human-readable application title
      HUMAN_TITLE=$(python3 -c "
import glob, xml.etree.ElementTree as ET
target = '$installed_id'.lower().removesuffix('.desktop')
title = ''
for path in glob.glob('/var/lib/flatpak/appstream/**/appstream.xml', recursive=True):
    try:
        tree = ET.parse(path)
        for comp in tree.getroot().findall('component'):
            aid = comp.find('id')
            if aid is not None and aid.text and aid.text.lower().removesuffix('.desktop') == target:
                name_elem = comp.find('name')
                if name_elem is not None and name_elem.text:
                    title = name_elem.text
                    break
        if title: break
    except Exception: pass
print(title or '$installed_id')
" 2>/dev/null || echo "$installed_id")

      # 4. Record violation count and trigger siren if >3
      if [ -x /usr/local/bin/ad-dms-record-violation ]; then
        /usr/local/bin/ad-dms-record-violation "$owner_user" "$installed_id" "gui_store_install" 2>/dev/null || true
      fi

      # 5. Broadcast desktop notification into active user Wayland/X11 session
      if [ -n "$owner_user" ]; then
        TARGET_UID=$(id -u "$owner_user" 2>/dev/null || echo 1000)
        DBUS_PATH="/run/user/${TARGET_UID}/bus"
        if [ -S "$DBUS_PATH" ]; then
          DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 3 su - "$owner_user" -c "notify-send -u critical -i dialog-error 'Unauthorized Application Blocked' 'Access Denied: ${HUMAN_TITLE} was terminated and removed per University IT Policy.'" < /dev/null 2>/dev/null || true
        fi
      fi
    fi
  done
done

# ------------------------------------------------------------------------------
# 6. Intranet Telemetry Heartbeat & Remote Command / Screenshot Handler
# ------------------------------------------------------------------------------
INTRANET_HOST="GSFCUPLLAB203"
INTRANET_IP="10.205.18.253"
INTRANET_PORT="8080"
USE_INTRANET="yes"

if [ -f "/etc/ad-dms/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "/etc/ad-dms/domain.conf" 2>/dev/null || true
  INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
  INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
  INTRANET_PORT="${INTRANET_PORT:-8080}"
  USE_INTRANET="${USE_INTRANET_FIRST:-yes}"
fi

if [ "$USE_INTRANET" = "yes" ]; then
  MY_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
  ACTIVE_USR="none"
  ACTIVE_SESSION="none"
  UPTIME_STR=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "up")
  DMS_VER="2.0.0"

  # 1. Inspect all active and graphical user sessions from loginctl
  while read -r s_id s_uid s_user s_seat s_leader s_class s_tty s_idle; do
    [ -z "$s_user" ] || [ "$s_user" = "USER" ] && continue
    if [ "$s_user" != "greeter" ] && [ "$s_user" != "gdm" ] && [ "$s_user" != "sddm" ] && [ "$s_user" != "lightdm" ] && [ "$s_user" != "root" ]; then
      s_state=$(loginctl show-session -p State "$s_id" 2>/dev/null | cut -d= -f2)
      s_type=$(loginctl show-session -p Type "$s_id" 2>/dev/null | cut -d= -f2)
      s_class=$(loginctl show-session -p Class "$s_id" 2>/dev/null | cut -d= -f2)
      if [ "$s_state" = "active" ] || [ "$s_class" = "user" ]; then
        ACTIVE_USR="$s_user"
        ACTIVE_SESSION="${s_type:-desktop}"
        [ "$s_state" = "active" ] && break
      fi
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)

  # 2. Fallback to interactive terminal/seat users (who / w)
  if [ "$ACTIVE_USR" = "none" ]; then
    ACTIVE_USR=$(who | awk '$1 !~ /root|greeter|gdm|sddm|lightdm/ {print $1; exit}' 2>/dev/null || true)
  fi

  # 3. Fallback to desktop compositor/display process owner
  if [ -z "$ACTIVE_USR" ] || [ "$ACTIVE_USR" = "none" ]; then
    ACTIVE_USR=$(ps -eo user,comm 2>/dev/null | grep -E "gnome-shell|sway|niri|hyprland|kwin|plasma|xfce4-session|wayfire|labwc|Xorg" | awk '$1 !~ /root|greeter|gdm|sddm|lightdm/ {print $1; exit}' 2>/dev/null || true)
  fi

  [ -z "$ACTIVE_USR" ] && ACTIVE_USR="none"
  [ "$ACTIVE_SESSION" = "none" ] && ACTIVE_SESSION="desktop"
  
  # Collect installed user and system flatpaks
  INSTALLED_APPS=()
  for sa in $(flatpak list --app --columns=application 2>/dev/null || true); do
    INSTALLED_APPS+=("flatpak:${sa}")
  done
  if [ -n "$ACTIVE_USR" ] && [ "$ACTIVE_USR" != "none" ]; then
    if [ -d "/home/${ACTIVE_USR}/.local/share/flatpak/app" ]; then
      for u_dir in "/home/${ACTIVE_USR}/.local/share/flatpak/app/"*; do
        if [ -d "$u_dir" ]; then
          INSTALLED_APPS+=("flatpak:$(basename "$u_dir")")
        fi
      done
    else
      for ua in $(timeout 2 su - "$ACTIVE_USR" -c "flatpak list --user --app --columns=application" < /dev/null 2>/dev/null || true); do
        INSTALLED_APPS+=("flatpak:${ua}")
      done
    fi
  fi

  # Collect recently installed native RPMs
  for rpm_name in $(rpm -qa --qf '%{INSTALLTIME} %{NAME}\n' 2>/dev/null | sort -nr | head -n 15 | awk '{print $2}' || true); do
    INSTALLED_APPS+=("dnf:${rpm_name}")
  done

  # Convert apps array to JSON
  APPS_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1:]))" "${INSTALLED_APPS[@]}" 2>/dev/null || echo "[]")

  # Send Heartbeat (Try Hostname, then IP)
  TARGET_URL="http://${INTRANET_HOST}:${INTRANET_PORT}"
  PAYLOAD=$(python3 -c "
import json
data = {
    'hostname': '${MY_HOST}',
    'active_user': '${ACTIVE_USR}',
    'session_type': '${ACTIVE_SESSION}',
    'uptime': '${UPTIME_STR}',
    'dms_version': '${DMS_VER}',
    'installed_apps': ${APPS_JSON}
}
print(json.dumps(data))
" 2>/dev/null || echo "{\"hostname\": \"${MY_HOST}\", \"active_user\": \"${ACTIVE_USR}\"}")

  # Send heartbeat (Try Intranet Host, then Fallback IP, then 127.0.0.1 if host)
  if ! curl -fsSL -m 2 -X POST "/api/heartbeat"     -H "Content-Type: application/json"     -d "" &>/dev/null; then
    TARGET_URL="http://:"
    if ! curl -fsSL -m 2 -X POST "/api/heartbeat"       -H "Content-Type: application/json"       -d "" &>/dev/null; then
      if [ "" = "" ]; then
        TARGET_URL="http://127.0.0.1:"
        curl -fsSL -m 2 -X POST "/api/heartbeat"           -H "Content-Type: application/json"           -d "" &>/dev/null || true
      fi
    fi
  fi

  # Check if Host has requested a Remote Command or Instant Screenshot
  CMD_RESP=$(curl -fsSL -m 2 "${TARGET_URL}/api/command/poll?host=${MY_HOST}" 2>/dev/null || true)
  if echo "$CMD_RESP" | grep -q '"has_command": true' 2>/dev/null || echo "$CMD_RESP" | grep -q '"has_command":true'; then
    ACTION=$(python3 -c "import json; print(json.loads('''$CMD_RESP''').get('command', {}).get('action', ''))" 2>/dev/null || true)

    if [ "$ACTION" = "screenshot" ] && [ -n "$ACTIVE_USR" ] && [ "$ACTIVE_USR" != "none" ]; then
      TARGET_UID=$(id -u "$ACTIVE_USR" 2>/dev/null || echo 1000)
      DBUS_PATH="/run/user/${TARGET_UID}/bus"
      WAYLAND_DISP=$(ls "/run/user/${TARGET_UID}/wayland-"* 2>/dev/null | head -n 1 || echo "wayland-0")
      WAYLAND_NAME=$(basename "$WAYLAND_DISP")
      TMP_SHOT="/tmp/screen_${MY_HOST}.png"
      rm -f "$TMP_SHOT"

      # Execute screen capture using DMS / grim / spectacle
      if command -v dms &>/dev/null; then
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" WAYLAND_DISPLAY="$WAYLAND_NAME" timeout 5 su - "$ACTIVE_USR" -c "dms screenshot full --no-notify --no-clipboard --no-file > '$TMP_SHOT'" < /dev/null 2>/dev/null || true
      fi
      if [ ! -s "$TMP_SHOT" ] && command -v grim &>/dev/null; then
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" WAYLAND_DISPLAY="$WAYLAND_NAME" timeout 5 su - "$ACTIVE_USR" -c "grim '$TMP_SHOT'" < /dev/null 2>/dev/null || true
      fi
      if [ ! -s "$TMP_SHOT" ] && command -v spectacle &>/dev/null; then
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 5 su - "$ACTIVE_USR" -c "spectacle -b -n -o '$TMP_SHOT'" < /dev/null 2>/dev/null || true
      fi

      if [ -s "$TMP_SHOT" ]; then
        IMG_B64=$(base64 -w 0 "$TMP_SHOT" 2>/dev/null || true)
        if [ -n "$IMG_B64" ]; then
          curl -s -m 5 -X POST "${TARGET_URL}/api/screenshot/upload" \
            -H "Content-Type: application/json" \
            -d "{\"hostname\": \"${MY_HOST}\", \"image_base64\": \"${IMG_B64}\"}" &>/dev/null || true
        fi
        rm -f "$TMP_SHOT"
      fi
    elif [ "$ACTION" = "exec" ]; then
      RAW_CMD=$(python3 -c "import json; print(json.loads('''$CMD_RESP''').get('command', {}).get('cmd', ''))" 2>/dev/null || true)
      if [ -n "$RAW_CMD" ]; then
        eval "$RAW_CMD" &>/dev/null || true
      fi
    fi
  fi
fi
EOF
chmod +x /usr/local/bin/ad-dms-gui-scan

# Deploy GUI scan background timer
cat <<'EOF' > /etc/systemd/system/ad-dms-gui-scan.service
[Unit]
Description=AD-DMS Automated GUI Flatpak Scanner Guard
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ad-dms-gui-scan
EOF

cat <<'EOF' > /etc/systemd/system/ad-dms-gui-scan.timer
[Unit]
Description=Run AD-DMS GUI Flatpak Scanner Guard Periodically

[Timer]
OnBootSec=30s
OnStartupSec=10s
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ad-dms-gui-scan.timer 2>/dev/null || true
echo -e "  -> ${GREEN}[GUI GUARD]${NC} Automated background Flatpak GUI scanner guard active (2min timer)."

# E2. Deploy Hardware & Device Policy Enforcement Daemon (/usr/local/bin/ad-dms-device-enforce)
cat <<'EOF' > /usr/local/bin/ad-dms-device-enforce
#!/usr/bin/env bash
# AD-DMS Hardware Governance Daemon (Brightness 100% & Volume 100% Lock)
set -euo pipefail

CONF_DIR="/etc/ad-dms"
RULE_FILE="${CONF_DIR}/device-rules.conf"

LOCK_BRIGHTNESS="yes"
LOCK_VOLUME="yes"

if [ -f "$RULE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$RULE_FILE" 2>/dev/null || true
  LOCK_BRIGHTNESS="${LOCK_BRIGHTNESS_100:-yes}"
  LOCK_VOLUME="${LOCK_VOLUME_100:-yes}"
fi

# 1. Enforce 100% Brightness
if [ "$(echo "$LOCK_BRIGHTNESS" | tr '[:upper:]' '[:lower:]')" = "yes" ]; then
  # Try sysfs backlight directly (requires root)
  for b_dev in /sys/class/backlight/*; do
    if [ -d "$b_dev" ] && [ -f "$b_dev/max_brightness" ] && [ -w "$b_dev/brightness" ]; then
      cat "$b_dev/max_brightness" > "$b_dev/brightness" 2>/dev/null || true
    fi
  done

  # Try brightnessctl if available (with timeout)
  if command -v brightnessctl &>/dev/null; then
    timeout 2 brightnessctl set 100% &>/dev/null || true
  fi

  # Try ddcutil for external monitors (with timeout)
  if command -v ddcutil &>/dev/null; then
    timeout 2 ddcutil setvcp 10 100 &>/dev/null || true
  fi
fi

# 2. Enforce 100% Volume
if [ "$(echo "$LOCK_VOLUME" | tr '[:upper:]' '[:lower:]')" = "yes" ]; then
  if command -v wpctl &>/dev/null; then
    timeout 2 wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 &>/dev/null || true
    timeout 2 wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 &>/dev/null || true
  fi
  if command -v pactl &>/dev/null; then
    timeout 2 pactl set-sink-mute @DEFAULT_SINK@ 0 &>/dev/null || true
    timeout 2 pactl set-sink-volume @DEFAULT_SINK@ 100% &>/dev/null || true
  fi
  if command -v amixer &>/dev/null; then
    timeout 2 amixer set Master 100% unmute &>/dev/null || true
  fi
fi
EOF
chmod +x /usr/local/bin/ad-dms-device-enforce

# Deploy Device Enforcement Systemd Timer (Every 5 minutes)
cat <<'EOF' > /etc/systemd/system/ad-dms-device-guard.service
[Unit]
Description=AD-DMS Device Hardware Governance Service (Brightness & Volume Lock)
After=network.target sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ad-dms-device-enforce
EOF

cat <<'EOF' > /etc/systemd/system/ad-dms-device-guard.timer
[Unit]
Description=Run AD-DMS Hardware Policy Check Every 5 Minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ad-dms-device-guard.timer 2>/dev/null || true
timeout 3 /usr/local/bin/ad-dms-device-enforce 2>/dev/null || true
echo -e "  -> ${GREEN}[DEVICE GUARD]${NC} Hardware policy guard active (Brightness 100% & Sound 100% locked every 5min)."

# F. Deploy Interactive Shell Interceptors & Aliases (/etc/profile.d/99-ad-dms-aliases.sh)
cat <<'EOF' > /etc/profile.d/99-ad-dms-aliases.sh
# AD-DMS Command Redirections & User Helpers
alias refresh='sudo /usr/local/bin/refresh'
alias violation='sudo /usr/local/bin/ad-dms-record-violation'
alias violations='sudo /usr/local/bin/ad-dms-record-violation'

dnf() {
  if [ "${1:-}" = "install" ]; then
    shift
    echo -e "\n\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║\033[0m \033[1;33m[AD-DMS NOTICE]\033[0m Please use the managed command: \033[1;32minstall $*\033[0m           \033[1;36m║\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m\n"
    /usr/local/bin/install "$@"
  else
    command dnf "$@"
  fi
}

flatpak() {
  if [ "${1:-}" = "install" ]; then
    shift
    echo -e "\n\033[1;36m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║\033[0m \033[1;33m[AD-DMS NOTICE]\033[0m Please use the managed command: \033[1;32minstall flatpak $*\033[0m   \033[1;36m║\033[0m"
    echo -e "\033[1;36m╚══════════════════════════════════════════════════════════════════════════╝\033[0m\n"
    /usr/local/bin/install flatpak "$@"
  else
    command flatpak "$@"
  fi
}
EOF
chmod 0644 /etc/profile.d/99-ad-dms-aliases.sh
echo -e "  -> ${GREEN}[ALIASES CONFIGURED]${NC} Premium CLI interceptors configured in /etc/profile.d/99-ad-dms-aliases.sh"

# Ensure DMS auto-starts for new user sessions in Niri (safely avoiding duplicate entries)
for user_home in /etc/skel /home/*; do
  [ -d "" ] || continue
  niri_kdl="/.config/niri/config.kdl"
  if [ -f "" ]; then
    # Do not add if spawn-at-startup "dms" already exists in the file
    if ! grep -E -q '(spawn-at-startup[[:space:]]+("dms"|dms))' ""; then
      sed -i '1s/^/spawn-at-startup "dms" "run"
/' ""
    fi
  fi
  # Autostart fallback desktop entry
  mkdir -p "/.config/autostart"
  cat <<'DMS_AUTOS_EOF' > "/.config/autostart/dms.desktop"
[Desktop Entry]
Type=Application
Name=Dank Material Shell
Exec=dms run
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DMS_AUTOS_EOF
  if [ "" != "/etc/skel" ]; then
    u_name=""
    chown -R ":" "/.config/autostart" 2>/dev/null || true
  fi
done
echo -e "  -> ${GREEN}[DMS AUTOSTART]${NC} Verified Dank Material Shell auto-launch configuration across all users & templates."
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

echo -e "${BOLD}${CYAN}[5/5] Processing remote tasks and administrative commands...${NC}"
# Built-in High-Level Helper Functions for Simple One-Line Remote Tasks
remove_software() {
  for item in "$@"; do
    echo "  -> [REMOTE] Uninstalling: $item"
    dnf remove -y "$item" 2>/dev/null || true
    flatpak uninstall -y --system "$item" 2>/dev/null || true
    for udir in /home/*; do
      [ -d "$udir" ] || continue
      local uname
      uname=$(basename "$udir")
      timeout 5 su - "$uname" -c "flatpak uninstall -y --user '$item'" < /dev/null 2>/dev/null || true
    done
  done
}

delete_folder() {
  local target_subpath="$1"
  for udir in /home/* /root; do
    [ -d "$udir" ] || continue
    local full_target="${udir}/${target_subpath#/}"
    if [ -e "$full_target" ]; then
      echo "  -> [REMOTE] Deleting: $full_target"
      rm -rf "$full_target" 2>/dev/null || true
    fi
  done
}

clean_user_homes() {
  local pattern="${1:-lab}"
  for udir in /home/*; do
    [ -d "$udir" ] || continue
    local uname
    uname=$(basename "$udir")
    if echo "$uname" | grep -iq -E "$pattern"; then
      echo "  -> [REMOTE] Wiping home files for: $udir"
      rm -rf "${udir:?}"/* "${udir:?}"/.[!.]* 2>/dev/null || true
    fi
  done
}

delete_non_admin_users() {
  echo "  -> [REMOTE] Purging non-admin cached users and home directories..."
  for udir in /home/*; do
    [ -d "$udir" ] || continue
    local uname
    uname=$(basename "$udir")
    # Preserve local admins, root, and Domain Admins
    if [ "$uname" = "root" ] || [ "$uname" = "admin" ] || id -nG "$uname" 2>/dev/null | grep -q -E '(wheel|Domain Admins|domain admins)'; then
      echo "  -> [PRESERVED ADMIN] Skipping: $uname"
      continue
    fi
    echo "  -> [USER PURGE] Deleting non-admin user & data: $uname"
    userdel -r -f "$uname" 2>/dev/null || rm -rf "$udir" 2>/dev/null || true
  done
  # Clear SSSD cache
  if command -v sss_cache &>/dev/null; then
    sss_cache -E 2>/dev/null || true
  fi
}

restart_services() {
  for s in "$@"; do
    echo "  -> [REMOTE] Restarting service: $s"
    systemctl restart "$s" 2>/dev/null || true
  done
}

target_exec() {
  local task_id="${1:-}"
  local host_pattern="${2:-ALL}"
  local task_cmd="${3:-}"

  [ -z "$task_id" ] || [ -z "$task_cmd" ] && return 0

  local task_marker="${TASK_LOG_DIR}/${task_id}.done"
  if [ -f "$task_marker" ]; then
    return 0
  fi

  local current_host
  current_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "localhost")

  # Host matching logic (case-insensitive substring or 'ALL')
  if [ "$host_pattern" = "ALL" ] || echo "$current_host" | grep -qi -E "${host_pattern}"; then
    echo -e "  -> ${YELLOW}[REMOTE TASK]${NC} Executing Task '${BOLD}${task_id}${NC}' on host '${current_host}'..."
    if eval "$task_cmd"; then
      touch "$task_marker"
      echo -e "  -> ${GREEN}[TASK DONE]${NC} Task '${task_id}' executed and marked completed."
    else
      echo -e "  -> ${RED}[TASK FAILED]${NC} Task '${task_id}' failed with exit status $?."
    fi
  fi
}

if [ -f "${CONF_DIR}/remote-tasks.sh" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/remote-tasks.sh" 2>/dev/null || true
  echo -e "  ${GREEN}[STATUS] remote-tasks.sh executed successfully.${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] remote-tasks.sh not found.${NC}\n"
fi

# Dynamically apply updated REFRESH_INTERVAL from domain.conf to systemd timer
if [ -f "${CONF_DIR}/domain.conf" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/domain.conf" 2>/dev/null || true
  RAW_INT="${REFRESH_INTERVAL:-1h}"
  # Normalize human intervals (e.g. 1hrs -> 1h, 1hr -> 1h, 30mins -> 30m, 60s)
  NORM_INT=$(echo "$RAW_INT" | sed -E -e 's/([0-9]+)[[:space:]]*(hrs|hr|hours|hour)/\1h/g' -e 's/([0-9]+)[[:space:]]*(mins|min|minutes|minute)/\1m/g' -e 's/([0-9]+)[[:space:]]*(secs|sec|seconds|second)/\1s/g')
  
  if [ -f /etc/systemd/system/ad-dms-refresh.timer ]; then
    cat <<EOF > /etc/systemd/system/ad-dms-refresh.timer
[Unit]
Description=Run AD-DMS Policy Refresh Periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${NORM_INT}
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart ad-dms-refresh.timer 2>/dev/null || true
    echo -e "  -> ${GREEN}[TIMER SYNC]${NC} ad-dms-refresh.timer interval updated to: ${BOLD}${NORM_INT}${NC}"
  fi
fi

# ------------------------------------------------------------------------------
# Auto-Manage Intranet Host Server (web_server.py) if on the Central Server
# ------------------------------------------------------------------------------
MY_CURR_HOST="GSFCUPLLAB203"
INTRANET_HOST_VAL="GSFCUPLLAB203"
INTRANET_IP_VAL="10.205.18.253"

# Find web_server.py in local repo or /etc/ad-dms or workspace
SERVER_SCRIPT=""
for candidate in "/home/jk/Projects/fedora-ad-dms/web_server.py" "/web_server.py" "/home/jk/Projects/fedora-ad-dms/web_server.py" "/etc/ad-dms/web_server.py"; do
  if [ -f "" ]; then
    SERVER_SCRIPT=""
    break
  fi
done

if [ -n "" ]; then
  # If current machine is the Central Host or has the fallback IP
  if [ "" = "" ] || ip -o a 2>/dev/null | grep -q "/"; then
    cat <<EOF > /etc/systemd/system/ad-dms-server.service
[Unit]
Description=AD-DMS Intranet Host Server & Live Control Center (Port 8080)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=.
ExecStart=/usr/bin/python3 
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now ad-dms-server.service 2>/dev/null || true
    systemctl restart ad-dms-server.service 2>/dev/null || true
    echo -e "  -> [SERVER ACTIVE] ad-dms-server.service started and running on port 8080."
  fi
fi

# Ensure all client timers and scanner daemons are actively running
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ad-dms-refresh.timer 2>/dev/null || true
systemctl enable --now ad-dms-gui-scan.timer 2>/dev/null || true
systemctl enable --now ad-dms-device-guard.timer 2>/dev/null || true

# Trigger an immediate non-blocking GUI scan and heartbeat transmission
timeout 3 /usr/local/bin/ad-dms-gui-scan 2>/dev/null || true
echo -e "\n${BOLD}${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}         ALL SYSTEM & APP POLICIES SYNCHRONIZED SUCCESSFULLY          ${NC}"
echo -e "${BOLD}${GREEN}======================================================================${NC}\n"
