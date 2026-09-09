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

# Deploy /usr/local/bin/refresh utility launcher (Go UI for interactive, Shell for flags)
# Compile or copy Go refresh TUI binary
REFRESH_GO_SRC="${SCRIPT_DIR:-/etc/ad-dms}/tui/refresh"
[ ! -d "$REFRESH_GO_SRC" ] && REFRESH_GO_SRC="/home/jk/Projects/fedora-ad-dms/tui/refresh"
if command -v go &>/dev/null && [ -d "$REFRESH_GO_SRC" ]; then
  (cd "$REFRESH_GO_SRC" && go build -o /usr/local/bin/refresh-ui main.go 2>/dev/null || true)
fi

# Fallback / Direct update: check if pre-compiled refresh-tui or /usr/local/bin/refresh-ui exists
for cand_ui in "${SCRIPT_DIR:-}/refresh-tui" "${SCRIPT_DIR:-}/config/refresh-tui" "/etc/ad-dms/refresh-tui" "/home/jk/Projects/fedora-ad-dms/config/refresh-tui"; do
  if [ -f "$cand_ui" ]; then
    cp -f "$cand_ui" /usr/local/bin/refresh-ui 2>/dev/null || true
    chmod +x /usr/local/bin/refresh-ui 2>/dev/null || true
    break
  fi
done

cat <<'REFRESH_UTIL_EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
set -euo pipefail

# If refresh-ui binary is installed, forward flags directly to it
if [ -x "/usr/local/bin/refresh-ui" ]; then
  exec /usr/local/bin/refresh-ui "$@"
fi

# Fallback shell diagnostic flag handlers if refresh-ui is missing
if [ $# -gt 0 ]; then
  if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--v" ] || [ "${1:-}" = "-version" ] || [ "${1:-}" = "--version" ]; then
    echo -e "\033[1;36m[AD-DMS REFRESH ENGINE]\033[0m Version: \033[1;32m2.1.0-fast-ss-responsive\033[0m"
    exit 0
  fi

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

  # Support checking Heartbeat Telemetry status
  if [ "${1:-}" = "-hb" ] || [ "${1:-}" = "--hb" ] || [ "${1:-}" = "-heartbeat" ] || [ "${1:-}" = "--heartbeat" ]; then
    if [ -x /usr/local/bin/heartbeat ]; then
      exec /usr/local/bin/heartbeat
    fi
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

    # Load intranet and main host configuration from domain.conf
    INTRANET_HOST="GSFCUPLLAB203"
    INTRANET_IP="10.205.18.253"
    INTRANET_PORT="8080"
    if [ -f "${CONF_DIR}/domain.conf" ]; then
      # shellcheck source=/dev/null
      source "${CONF_DIR}/domain.conf" 2>/dev/null || true
      INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
      INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
      INTRANET_PORT="${INTRANET_PORT:-8080}"
    elif [ -f "/home/jk/Projects/fedora-ad-dms/domain.conf" ]; then
      source "/home/jk/Projects/fedora-ad-dms/domain.conf" 2>/dev/null || true
      INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
      INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
      INTRANET_PORT="${INTRANET_PORT:-8080}"
    fi

    MY_CURR_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
    echo -e "\n  \033[1;36m[MAIN HOST DEVICE TARGET]\033[0m \033[1;37m${INTRANET_HOST}\033[0m (Fallback IP: ${INTRANET_IP}, Port: ${INTRANET_PORT})"

    echo -e "\n  \033[1;36m[ICMP PING PROBE]\033[0m Pinging main host device..."
    ping_ok=false
    for ping_target in "127.0.0.1" "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
      if [ "$ping_target" = "127.0.0.1" ]; then
        if [ "${MY_CURR_HOST,,}" != "${INTRANET_HOST,,}" ]; then
          continue
        fi
      fi
      if ping -c 1 -W 1 "$ping_target" >/dev/null 2>&1; then
        if [ "$ping_target" = "127.0.0.1" ]; then
          echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Current machine is Central Host '${MY_CURR_HOST}')"
        else
          echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Host '${ping_target}' replied to ping)"
        fi
        ping_ok=true
        break
      fi
    done
    if [ "$ping_ok" = false ] && [ -n "$INTRANET_IP" ]; then
      if ping -c 1 -W 1 "$INTRANET_IP" >/dev/null 2>&1; then
        echo -e "    -> \033[1;32m● ICMP PING SUCCESSFUL\033[0m (Fallback IP '${INTRANET_IP}' replied to ping)"
        ping_ok=true
      fi
    fi
    if [ "$ping_ok" = false ]; then
      echo -e "    -> \033[1;33m○ ICMP PING UNREACHABLE\033[0m (Host '${INTRANET_HOST}' did not answer ping request)"
    fi

    echo -e "\n  \033[1;36m[HTTP SERVICE PROBE]\033[0m Testing reachable upstream service..."
    live_found=false

    # Check localhost first if running on the host machine
    if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/"; then
      if curl -fsSL -m 2 "http://127.0.0.1:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> \033[1;32m● INTRANET HOST ONLINE\033[0m (Local host server active on port ${INTRANET_PORT})"
        live_found=true
      fi
    fi

    if [ "$live_found" = false ]; then
      for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
        if curl -fsSL -m 2 "http://${host_target}:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
          echo -e "    -> \033[1;32m● INTRANET HOST ONLINE\033[0m (Connected via ${host_target}:${INTRANET_PORT})"
          live_found=true
          break
        fi
      done
    fi

    if [ "$live_found" = false ] && [ -n "$INTRANET_IP" ]; then
      if curl -fsSL -m 2 "http://${INTRANET_IP}:${INTRANET_PORT}/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> \033[1;32m● INTRANET IP ONLINE\033[0m (Connected via ${INTRANET_IP}:${INTRANET_PORT})"
        live_found=true
      fi
    fi

    if [ "$live_found" = false ]; then
      if curl -fsSL -m 3 "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> \033[1;34m☁ GITHUB CLOUD FALLBACK\033[0m (Intranet offline, GitHub reachable)."
      else
        echo -e "    -> \033[1;31m✖ ALL UPSTREAM SOURCES OFFLINE\033[0m (No network connectivity)."
      fi
    fi
    echo ""
    exit 0
  fi
fi

# Auto-sync latest Go refresh-ui binary before launching if on intranet or GitHub
if [ -t 1 ]; then
  _REFRESH_BIN="/usr/local/bin/refresh-ui"
  _NEED_SYNC=false
  if [ ! -x "$_REFRESH_BIN" ]; then
    _NEED_SYNC=true
  fi

  # Fast probe for intranet server binary update
  _I_HOST="${INTRANET_HOST_NAME:-GSFCUPLLAB203}"
  _I_IP="${INTRANET_FALLBACK_IP:-10.205.18.253}"
  _I_PORT="${INTRANET_PORT:-8080}"
  
  if [ -f "/etc/ad-dms/domain.conf" ]; then
    _I_HOST=$(grep -E "^INTRANET_HOST_NAME=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_HOST")
    _I_IP=$(grep -E "^INTRANET_FALLBACK_IP=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_IP")
    _I_PORT=$(grep -E "^INTRANET_PORT=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_PORT")
  fi

  for _target_candidate in "${_I_HOST}:${_I_PORT}" "${_I_HOST}.local:${_I_PORT}" "${_I_IP}:${_I_PORT}"; do
    if [ -z "${_target_candidate%%:*}" ]; then continue; fi
    if curl -fsSL -m 1 "http://${_target_candidate}/api/health" &>/dev/null; then
      # Fetch latest binary silently with header timestamp comparison (-z)
      curl -fsSL -m 5 -z "$_REFRESH_BIN" "http://${_target_candidate}/config/refresh-tui" -o "${_REFRESH_BIN}.tmp" 2>/dev/null || true
      if [ -s "${_REFRESH_BIN}.tmp" ]; then
        mv -f "${_REFRESH_BIN}.tmp" "$_REFRESH_BIN" 2>/dev/null || true
        chmod +x "$_REFRESH_BIN" 2>/dev/null || true
      fi
      rm -f "${_REFRESH_BIN}.tmp"
      break
    fi
  done

  if [ -x "$_REFRESH_BIN" ]; then
    exec "$_REFRESH_BIN" "$@"
  fi
fi

# Fallback or headless execution: execute sync engine directly
REPO_RAW_URL="https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/config"
CONF_DIR="/etc/ad-dms"

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
  if [ "$USE_INTRANET" = "yes" ]; then
    MY_CURR_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
    if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/"; then
      if curl -fsSL -m 3 "http://127.0.0.1:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://127.0.0.1:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
        [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet Localhost: 127.0.0.1)\033[0m"
        echo "Intranet Host (127.0.0.1:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
        chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
        fetched=true
      fi
    fi
  fi

  # 1b. Try Intranet Host via Hostname (Plain, .local, and FQDN)
  if [ "$fetched" = false ] && [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_HOST" ]; then
    for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_HOST}.gsfcu.local"; do
      if curl -fsSL -m 3 "http://${host_target}:${INTRANET_PORT}/config/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null || curl -fsSL -m 3 "http://${host_target}:${INTRANET_PORT}/${file}" -o "${CONF_DIR}/${file}" 2>/dev/null; then
        [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet Host: ${host_target})\033[0m"
        echo "Intranet Host (${host_target}:${INTRANET_PORT}) - Synced at $(date)" > "${CONF_DIR}/.last_source" 2>/dev/null || true
        chmod 644 "${CONF_DIR}/.last_source" 2>/dev/null || true
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

# Sync all Desktop & Shell preset archives from Intranet server / GitHub into ${CONF_DIR}/presets
mkdir -p "${CONF_DIR}/presets"
PRESET_LIST_JSON=$(curl -fsSL -m 3 "http://${INTRANET_HOST}:${INTRANET_PORT}/api/presets/list" 2>/dev/null || curl -fsSL -m 3 "http://${INTRANET_IP}:${INTRANET_PORT}/api/presets/list" 2>/dev/null || true)
REMOTE_PRESETS=()
if [ -n "$PRESET_LIST_JSON" ]; then
  while read -r p_name; do
    [ -n "$p_name" ] && REMOTE_PRESETS+=("$p_name")
  done < <(echo "$PRESET_LIST_JSON" | python3 -c "import sys, json; [print(x['name']) for x in json.load(sys.stdin).get('presets', [])]" 2>/dev/null || true)
fi

# Fallback to standard package names if API list offline
if [ "${#REMOTE_PRESETS[@]}" -eq 0 ]; then
  REMOTE_PRESETS=("DankMaterialShell.tar.gz" "niri-dms-config.tar.gz")
fi

for pf in "${REMOTE_PRESETS[@]}"; do
  [ -t 1 ] && echo -n -e "  -> Fetching Desktop Preset: ${pf}... "
  pf_fetched=false
  # 1. Try intranet host
  if [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_HOST" ]; then
    for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_IP}"; do
      [ -z "$host_target" ] && continue
      if curl -fsSL -m 8 -z "${CONF_DIR}/presets/${pf}" "http://${host_target}:${INTRANET_PORT}/presets/${pf}" -o "${CONF_DIR}/presets/${pf}" 2>/dev/null; then
        if [ -s "${CONF_DIR}/presets/${pf}" ]; then
          [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet: ${host_target})\033[0m"
          pf_fetched=true
          break
        fi
      fi
    done
  fi
  # 2. Try GitHub fallback
  if [ "$pf_fetched" = false ]; then
    if curl -fsSL -m 12 -z "${CONF_DIR}/presets/${pf}" "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/presets/${pf}" -o "${CONF_DIR}/presets/${pf}" 2>/dev/null; then
      if [ -s "${CONF_DIR}/presets/${pf}" ]; then
        [ -t 1 ] && echo -e "\033[1;32m[OK] (GitHub Cloud)\033[0m"
        pf_fetched=true
      fi
    fi
  fi
  if [ "$pf_fetched" = false ]; then
    if [ -f "${CONF_DIR}/presets/${pf}" ]; then
      [ -t 1 ] && echo -e "\033[1;32m[CURRENT]\033[0m"
    else
      [ -t 1 ] && echo -e "\033[1;33m[OFFLINE]\033[0m"
    fi
  fi
done

# Sync refresh UI binary (refresh-tui) so clients get the latest TUI interface
[ -t 1 ] && echo -n -e "  -> Syncing Refresh TUI UI binary (refresh-ui)... "
tui_fetched=false
if [ "$USE_INTRANET" = "yes" ] && [ -n "$INTRANET_HOST" ]; then
  for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_IP}"; do
    [ -z "$host_target" ] && continue
    if curl -fsSL -m 8 "http://${host_target}:${INTRANET_PORT}/config/refresh-tui" -o /usr/local/bin/refresh-ui 2>/dev/null; then
      if [ -s /usr/local/bin/refresh-ui ]; then
        chmod +x /usr/local/bin/refresh-ui
        [ -t 1 ] && echo -e "\033[1;32m[OK] (Intranet: ${host_target})\033[0m"
        tui_fetched=true
        break
      fi
    fi
  done
fi
if [ "$tui_fetched" = false ]; then
  if curl -fsSL -m 12 "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/config/refresh-tui?$(date +%s)" -o /usr/local/bin/refresh-ui 2>/dev/null; then
    if [ -s /usr/local/bin/refresh-ui ]; then
      chmod +x /usr/local/bin/refresh-ui
      [ -t 1 ] && echo -e "\033[1;32m[OK] (GitHub Cloud)\033[0m"
      tui_fetched=true
    fi
  fi
fi
if [ "$tui_fetched" = false ]; then
  [ -t 1 ] && echo -e "\033[1;32m[CURRENT]\033[0m"
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
# Ensure /usr/local/bin/refresh launcher script has the latest version flag handler & updater
if [ -d "/etc/ad-dms" ]; then
  cat <<'REFRESH_UTIL_EOF' > /usr/local/bin/refresh
#!/usr/bin/env bash
set -euo pipefail

# If any flags are passed, execute the shell diagnostics/flag handlers
if [ $# -gt 0 ]; then
  # Support version check
  if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--v" ] || [ "${1:-}" = "-version" ] || [ "${1:-}" = "--version" ]; then
    echo -e "\033[1;36m[AD-DMS REFRESH ENGINE]\033[0m Version: \033[1;32m2.1.0-fast-ss-responsive\033[0m"
    exit 0
  fi

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

  # Support checking Heartbeat Telemetry status
  if [ "${1:-}" = "-hb" ] || [ "${1:-}" = "--hb" ] || [ "${1:-}" = "-heartbeat" ] || [ "${1:-}" = "--heartbeat" ]; then
    if [ -x /usr/local/bin/heartbeat ]; then
      exec /usr/local/bin/heartbeat
    fi
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

    # Load intranet and main host configuration from domain.conf
    INTRANET_HOST="GSFCUPLLAB203"
    INTRANET_IP="10.205.18.253"
    INTRANET_PORT="8080"
    if [ -f "${CONF_DIR}/domain.conf" ]; then
      source "${CONF_DIR}/domain.conf" 2>/dev/null || true
      INTRANET_HOST="${INTRANET_HOST_NAME:-$INTRANET_HOST}"
      INTRANET_IP="${INTRANET_FALLBACK_IP:-$INTRANET_IP}"
      INTRANET_PORT="${INTRANET_PORT:-8080}"
    fi

    echo -e "\033[1;36m  [LIVE UPSTREAM PROBE RESULTS]\033[0m"
    live_found=false

    for host_target in "${INTRANET_HOST}" "${INTRANET_HOST}.local" "${INTRANET_IP}"; do
      [ -z "$host_target" ] && continue
      if curl -fsSL -m 2 "http://${host_target}:${INTRANET_PORT}/api/health" &>/dev/null; then
        echo -e "    -> \033[1;32m● INTRANET SERVER ONLINE\033[0m (Connected via http://${host_target}:${INTRANET_PORT})"
        live_found=true
        break
      fi
    done

    if [ "$live_found" = false ]; then
      if curl -fsSL -m 3 "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/domain.conf" >/dev/null 2>&1; then
        echo -e "    -> \033[1;34m☁ GITHUB CLOUD FALLBACK\033[0m (Intranet offline, GitHub reachable)."
      else
        echo -e "    -> \033[1;31m✖ ALL UPSTREAM SOURCES OFFLINE\033[0m (No network connectivity)."
      fi
    fi
    echo ""
    exit 0
  fi
fi

# Auto-sync latest Go refresh-ui binary before launching if on intranet or GitHub
if [ -t 1 ]; then
  _REFRESH_BIN="/usr/local/bin/refresh-ui"
  _NEED_SYNC=false
  if [ ! -x "$_REFRESH_BIN" ]; then
    _NEED_SYNC=true
  fi

  # Fast probe for intranet server binary update
  _I_HOST="${INTRANET_HOST_NAME:-GSFCUPLLAB203}"
  _I_IP="${INTRANET_FALLBACK_IP:-10.205.18.253}"
  _I_PORT="${INTRANET_PORT:-8080}"
  
  if [ -f "/etc/ad-dms/domain.conf" ]; then
    _I_HOST=$(grep -E "^INTRANET_HOST_NAME=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_HOST")
    _I_IP=$(grep -E "^INTRANET_FALLBACK_IP=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_IP")
    _I_PORT=$(grep -E "^INTRANET_PORT=" /etc/ad-dms/domain.conf 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "$_I_PORT")
  fi

  for _target_candidate in "${_I_HOST}:${_I_PORT}" "${_I_HOST}.local:${_I_PORT}" "${_I_IP}:${_I_PORT}"; do
    if [ -z "${_target_candidate%%:*}" ]; then continue; fi
    if curl -fsSL -m 1 "http://${_target_candidate}/api/health" &>/dev/null; then
      # Fetch latest binary silently with header timestamp comparison (-z)
      curl -fsSL -m 5 -z "$_REFRESH_BIN" "http://${_target_candidate}/config/refresh-tui" -o "${_REFRESH_BIN}.tmp" 2>/dev/null || true
      if [ -s "${_REFRESH_BIN}.tmp" ]; then
        mv -f "${_REFRESH_BIN}.tmp" "$_REFRESH_BIN" 2>/dev/null || true
        chmod +x "$_REFRESH_BIN" 2>/dev/null || true
      fi
      rm -f "${_REFRESH_BIN}.tmp"
      break
    fi
  done

  if [ -x "$_REFRESH_BIN" ]; then
    exec "$_REFRESH_BIN" "$@"
  fi
fi
REFRESH_UTIL_EOF
  chmod +x /usr/local/bin/refresh
fi

chmod +x /usr/local/bin/refresh
echo -e "  -> ${GREEN}[REFRESH CLI INSTALLED]${NC} Universal policy refresh utility active at /usr/local/bin/refresh"

# E. Deploy Background GUI Flatpak Scanner Daemon (/usr/local/bin/ad-dms-gui-scan)
cat <<'EOF' > /usr/local/bin/ad-dms-gui-scan
#!/usr/bin/env bash
# Automated background guard against rogue Flatpak installs via GNOME Software / KDE Discover
set -euo pipefail

CONF_DIR="/etc/ad-dms"
[ -f "${CONF_DIR}/refresh-app-policies.sh" ] || exit 0

# Helper to find currently active graphical login users
get_active_sessions() {
  loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1, $3}' || true
}

# ------------------------------------------------------------------------------
# 1. Immediate Remote Command / Screenshot & Telemetry Check (RUNS FIRST!)
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

MY_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
ACTIVE_USR="none"
ACTIVE_SESSION="none"
UPTIME_STR=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "up")
DMS_VER="2.0.0"

# Inspect active and graphical user sessions from loginctl
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

if [ "$ACTIVE_USR" = "none" ]; then
  ACTIVE_USR=$(who | awk '$1 !~ /root|greeter|gdm|sddm|lightdm/ {print $1; exit}' 2>/dev/null || true)
fi
if [ -z "$ACTIVE_USR" ] || [ "$ACTIVE_USR" = "none" ]; then
  ACTIVE_USR=$(ps -eo user,comm 2>/dev/null | grep -E "gnome-shell|sway|niri|hyprland|kwin|plasma|xfce4-session|wayfire|labwc|Xorg" | awk '$1 !~ /root|greeter|gdm|sddm|lightdm/ {print $1; exit}' 2>/dev/null || true)
fi

[ -z "$ACTIVE_USR" ] && ACTIVE_USR="none"
[ "$ACTIVE_SESSION" = "none" ] && ACTIVE_SESSION="desktop"

# Resolve Intranet Server Target URL
TARGET_URL=""
if [ "$USE_INTRANET" = "yes" ]; then
  if [ "${MY_HOST,,}" = "${INTRANET_HOST,,}" ] || ( [ -n "$INTRANET_IP" ] && ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/" ); then
    TARGET_URL="http://127.0.0.1:${INTRANET_PORT}"
  else
    for hb_target in "${INTRANET_HOST}:${INTRANET_PORT}" "${INTRANET_HOST}.local:${INTRANET_PORT}" "${INTRANET_IP}:${INTRANET_PORT}"; do
      if curl -fsSL -m 1 "http://${hb_target}/api/health" &>/dev/null; then
        TARGET_URL="http://${hb_target}"
        break
      fi
    done
  fi
fi

# Poll & execute any pending commands immediately
execute_pending_command() {
  local cmd_json="$1"
  local action
  action=$(python3 -c "import json; print(json.loads('''$cmd_json''').get('command', {}).get('action', ''))" 2>/dev/null || true)

  if [ "$action" = "screenshot" ] && [ -n "$ACTIVE_USR" ] && [ "$ACTIVE_USR" != "none" ]; then
    local target_uid dbus_path tmp_shot wayland_name
    target_uid=$(id -u "$ACTIVE_USR" 2>/dev/null || echo "")
    if [ -z "$target_uid" ] || [ ! -d "/run/user/${target_uid}" ]; then
      for udir in /run/user/[0-9]*; do
        if [ -d "$udir" ] && ls "$udir"/wayland-* &>/dev/null; then
          target_uid=$(basename "$udir")
          break
        fi
      done
    fi
    [ -z "$target_uid" ] && target_uid=1000
    dbus_path="/run/user/${target_uid}/bus"
    tmp_shot="/tmp/screen_${MY_HOST}.png"
    rm -f "$tmp_shot"

    wayland_name=""
    for wsock in $(ls -t "/run/user/${target_uid}/wayland-"[0-9]* 2>/dev/null); do
      if [ -S "$wsock" ]; then
        wayland_name=$(basename "$wsock")
        break
      fi
    done
    [ -z "$wayland_name" ] && wayland_name="wayland-0"

    # Screen capture hierarchy: 1) dms screenshot (direct & su), 2) grim, 3) spectacle, 4) hyprshot
    if command -v dms &>/dev/null; then
      WAYLAND_DISPLAY="${wayland_name}" XDG_RUNTIME_DIR="/run/user/${target_uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 5 dms screenshot full --no-notify --no-clipboard -d /tmp --filename "screen_${MY_HOST}.png" 2>/dev/null || \
      timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY='${wayland_name}' XDG_RUNTIME_DIR='/run/user/${target_uid}' DBUS_SESSION_BUS_ADDRESS='unix:path=${dbus_path}'; dms screenshot full --no-notify --no-clipboard -d /tmp --filename 'screen_${MY_HOST}.png'" < /dev/null 2>/dev/null || true
    fi
    if [ ! -s "$tmp_shot" ] && command -v grim &>/dev/null; then
      WAYLAND_DISPLAY="${wayland_name}" XDG_RUNTIME_DIR="/run/user/${target_uid}" timeout 5 grim "$tmp_shot" 2>/dev/null || \
      timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY='${wayland_name}' XDG_RUNTIME_DIR='/run/user/${target_uid}'; grim '$tmp_shot'" < /dev/null 2>/dev/null || true
    fi
    if [ ! -s "$tmp_shot" ] && command -v spectacle &>/dev/null; then
      timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY='${wayland_name}' XDG_RUNTIME_DIR='/run/user/${target_uid}' DBUS_SESSION_BUS_ADDRESS='unix:path=${dbus_path}'; spectacle -b -n -o '$tmp_shot'" < /dev/null 2>/dev/null || true
    fi
    if [ ! -s "$tmp_shot" ] && command -v hyprshot &>/dev/null; then
      timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY='${wayland_name}' XDG_RUNTIME_DIR='/run/user/${target_uid}'; hyprshot -m output -o /tmp -f 'screen_${MY_HOST}.png'" < /dev/null 2>/dev/null || true
    fi

    if [ -s "$tmp_shot" ]; then
      chmod 644 "$tmp_shot" 2>/dev/null || true
      local img_b64
      img_b64=$(base64 -w 0 "$tmp_shot" 2>/dev/null || true)
      if [ -n "$img_b64" ] && [ -n "$TARGET_URL" ]; then
        curl -s -m 8 -X POST "${TARGET_URL}/api/screenshot/upload" \
          -H "Content-Type: application/json" \
          -d "{\"hostname\": \"${MY_HOST}\", \"image_base64\": \"${img_b64}\"}" &>/dev/null || true
      fi
      rm -f "$tmp_shot"
    fi
  elif [ "$action" = "logs" ]; then
    local log_out
    log_out=$(journalctl -u ad-dms-wake-listener.service -u ad-dms-fast-poll.service -u ad-dms-refresh.service -n 50 --no-pager 2>/dev/null || true)
    log_out="${log_out}\n--- UPTIME & STATUS ---\n$(uptime 2>/dev/null || true)\n$(systemctl status ad-dms-fast-poll ad-dms-wake-listener --no-pager 2>/dev/null || true)"
    if [ -n "$log_out" ] && [ -n "$TARGET_URL" ]; then
      python3 -c "import urllib.request, json; data=json.dumps({'hostname': '''$MY_HOST''', 'log_text': '''$log_out'''}).encode(); req=urllib.request.Request('''$TARGET_URL/api/logs/upload''', data=data, headers={'Content-Type': 'application/json'}); urllib.request.urlopen(req, timeout=8)" 2>/dev/null || true
    fi
  elif [ "$action" = "exec" ]; then
    local raw_cmd
    raw_cmd=$(python3 -c "import json; print(json.loads('''$cmd_json''').get('command', {}).get('cmd', ''))" 2>/dev/null || true)
    if [ -n "$raw_cmd" ]; then
      if [ -n "$ACTIVE_USR" ] && [ "$ACTIVE_USR" != "none" ]; then
        local target_uid dbus_path
        target_uid=$(id -u "$ACTIVE_USR" 2>/dev/null || echo 1000)
        dbus_path="/run/user/${target_uid}/bus"
        if [ -S "$dbus_path" ] && command -v notify-send &>/dev/null; then
          if echo "$raw_cmd" | grep -qi "poweroff"; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 4 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-shutdown '⚡ System Shutdown Scheduled' 'An administrator has scheduled a workstation shutdown. Please save your work.'" < /dev/null 2>/dev/null || true
          elif echo "$raw_cmd" | grep -qiE "reboot|soft-reboot"; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 4 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-reboot '⚡ System Restart Scheduled' 'An administrator has scheduled a workstation restart. Please save your work.'" < /dev/null 2>/dev/null || true
          elif echo "$raw_cmd" | grep -qiE "terminate-user|quit"; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 4 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-log-out '🚪 Session Termination' 'Your user session is being logged out by an administrator.'" < /dev/null 2>/dev/null || true
          elif echo "$raw_cmd" | grep -qi "dms restart"; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 4 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u normal -i view-refresh '🎨 DMS Shell Restart' 'DMS desktop environment is restarting...'" < /dev/null 2>/dev/null || true
          elif echo "$raw_cmd" | grep -qi "refresh"; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=${dbus_path}" timeout 4 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u normal -i system-software-update '🔄 Policy Refresh Initiated' 'Workstation configurations and software policies are synchronizing...'" < /dev/null 2>/dev/null || true
          fi
        fi
      fi
      eval "$raw_cmd" &>/dev/null || true
    fi
  fi
}

if [ -n "$TARGET_URL" ]; then
  CMD_RESP=$(curl -fsSL -m 2 "${TARGET_URL}/api/command/poll?host=${MY_HOST}" 2>/dev/null || true)
  if echo "$CMD_RESP" | grep -q '"has_command": true' 2>/dev/null || echo "$CMD_RESP" | grep -q '"has_command":true'; then
    execute_pending_command "$CMD_RESP"
  fi
fi

# ------------------------------------------------------------------------------
# 2. Rogue Flatpak Scanner & Auto-Removal Guard
# ------------------------------------------------------------------------------
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
declare -A DETECTED_APPS

# 1. System Flatpaks
SYS_APPS=$(flatpak list --system --app --columns=application 2>/dev/null || true)
for sa in $SYS_APPS; do
  DETECTED_APPS["$sa"]="system"
done

# 2. Per-user flatpaks: inspect disk directly in /home to prevent PAM su stalls
while read -r sess_id sess_user; do
  [ -z "$sess_user" ] || [ "$sess_user" = "root" ] || [ "$sess_user" = "greeter" ] && continue
  if [ -d "/home/${sess_user}/.local/share/flatpak/app" ]; then
    for u_app_dir in "/home/${sess_user}/.local/share/flatpak/app/"*; do
      if [ -d "$u_app_dir" ]; then
        ua=$(basename "$u_app_dir")
        DETECTED_APPS["$ua"]="$sess_user"
      fi
    done
  fi
done < <(get_active_sessions)

for b_app in "${BLOCKED_FLATPAKS[@]}"; do
  [ -z "$b_app" ] && continue
  for installed_id in "${!DETECTED_APPS[@]}"; do
    if [[ "$installed_id" == "$b_app" || "$installed_id" == *"$b_app"* || "$b_app" == *"$installed_id"* ]]; then
      owner_user="${DETECTED_APPS[$installed_id]}"
      [ "$owner_user" = "system" ] && owner_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 !~ /root|greeter/ {print $3; exit}' || echo "user")

      flatpak kill "$installed_id" 2>/dev/null || true
      flatpak uninstall -y --system "$installed_id" 2>/dev/null || true
      if [ -n "$owner_user" ] && [ "$owner_user" != "system" ]; then
        timeout 4 su - "$owner_user" -c "flatpak uninstall -y --user $installed_id" < /dev/null 2>/dev/null || true
      fi
      flatpak uninstall -y --user "$installed_id" 2>/dev/null || true

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

      if [ -x /usr/local/bin/ad-dms-record-violation ]; then
        /usr/local/bin/ad-dms-record-violation "$owner_user" "$installed_id" "gui_store_install" 2>/dev/null || true
      fi

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
# 3. Telemetry Heartbeat & Inventory Collection
# ------------------------------------------------------------------------------
if [ -n "$TARGET_URL" ]; then
  INSTALLED_APPS=()
  for sa in $(flatpak list --app --columns=application 2>/dev/null || true); do
    INSTALLED_APPS+=("flatpak:${sa}")
  done
  if [ -n "$ACTIVE_USR" ] && [ "$ACTIVE_USR" != "none" ] && [ -d "/home/${ACTIVE_USR}/.local/share/flatpak/app" ]; then
    for u_dir in "/home/${ACTIVE_USR}/.local/share/flatpak/app/"*; do
      [ -d "$u_dir" ] && INSTALLED_APPS+=("flatpak:$(basename "$u_dir")")
    done
  fi

  for rpm_name in $(rpm -qa --qf '%{INSTALLTIME} %{NAME}\n' 2>/dev/null | sort -nr | head -n 15 | awk '{print $2}' || true); do
    INSTALLED_APPS+=("dnf:${rpm_name}")
  done

  APPS_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1:]))" "${INSTALLED_APPS[@]}" 2>/dev/null || echo "[]")

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

  HB_RESP=$(curl -fsSL -m 2 -X POST "${TARGET_URL}/api/heartbeat" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null || true)
  echo "Host '${TARGET_URL}' - Sent at $(date)" > "${CONF_DIR}/.last_heartbeat" 2>/dev/null || true

  # Check if Heartbeat response piggybacked a remote command
  if echo "$HB_RESP" | grep -q '"has_command": true' 2>/dev/null || echo "$HB_RESP" | grep -q '"has_command":true'; then
    execute_pending_command "$HB_RESP"
  fi
fi
EOF
chmod +x /usr/local/bin/ad-dms-gui-scan

# Deploy Fast Command Worker Daemon (Polls server every 3 seconds for instant response)
cat <<'EOF' > /usr/local/bin/ad-dms-fast-poll
#!/usr/bin/env python3
import json, os, socket, subprocess, sys, time, urllib.request

CONF_DIR = "/etc/ad-dms"
DOMAIN_CONF = os.path.join(CONF_DIR, "domain.conf")

def get_server_info():
    host = "GSFCUPLLAB203"
    ip = "10.205.18.253"
    port = "8080"
    if os.path.exists(DOMAIN_CONF):
        try:
            with open(DOMAIN_CONF, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("INTRANET_HOST_NAME="):
                        host = line.split("=", 1)[1].strip().strip('"\'')
                    elif line.startswith("INTRANET_FALLBACK_IP="):
                        ip = line.split("=", 1)[1].strip().strip('"\'')
                    elif line.startswith("INTRANET_PORT="):
                        port = line.split("=", 1)[1].strip().strip('"\'')
        except Exception:
            pass
    return host, ip, port

def main():
    my_host = socket.gethostname().split(".")[0].upper()
    server_host, server_ip, server_port = get_server_info()
    local_host = os.uname().nodename.split(".")[0].upper()

    urls_to_try = []
    if my_host == server_host.upper() or local_host == server_host.upper():
        urls_to_try = [f"http://127.0.0.1:{server_port}"]
    else:
        urls_to_try = [
            f"http://{server_host}:{server_port}",
            f"http://{server_host}.local:{server_port}",
            f"http://{server_ip}:{server_port}"
        ]

    while True:
        success = False
        for target_url in urls_to_try:
            try:
                req = urllib.request.Request(f"{target_url}/api/command/poll?host={my_host}", headers={"User-Agent": "AD-DMS-FastPoll"})
                with urllib.request.urlopen(req, timeout=2) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    if data.get("has_command"):
                        # Command waiting! Execute ONLY the fast command executor, NOT the heavy full scan
                        subprocess.Popen(["/usr/local/bin/ad-dms-cmd-exec"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    success = True
                    break
            except Exception:
                pass
        time.sleep(2)

if __name__ == "__main__":
    main()
EOF
chmod +x /usr/local/bin/ad-dms-fast-poll

cat <<'EOF' > /etc/systemd/system/ad-dms-fast-poll.service
[Unit]
Description=AD-DMS Fast Remote Command Poller
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ad-dms-fast-poll
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

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

# Deploy Fast Dedicated Command Executor (no scanning overhead — pure command dispatch only)
cat <<'CMDEXEC_EOF' > /usr/local/bin/ad-dms-cmd-exec
#!/usr/bin/env bash
# AD-DMS Fast Command Executor — runs pending remote commands instantly with zero scan overhead
# This is intentionally minimal: no Flatpak scan, no RPM audit, no disk traversal.
set -euo pipefail

CONF_DIR="/etc/ad-dms"
[ -f "${CONF_DIR}/domain.conf" ] || exit 0
source "${CONF_DIR}/domain.conf" 2>/dev/null || true

MY_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")
ACTIVE_USR="none"
ACTIVE_SESSION="desktop"

# Detect active graphical user (fast)
while read -r s_id _uid s_user rest; do
  [ -z "$s_user" ] || [ "$s_user" = "USER" ] && continue
  if [[ "$s_user" != greeter && "$s_user" != gdm && "$s_user" != sddm && "$s_user" != lightdm && "$s_user" != root ]]; then
    s_state=$(loginctl show-session -p State "$s_id" 2>/dev/null | cut -d= -f2)
    s_type=$(loginctl show-session -p Type "$s_id" 2>/dev/null | cut -d= -f2)
    s_class_v=$(loginctl show-session -p Class "$s_id" 2>/dev/null | cut -d= -f2)
    if [[ "$s_state" = "active" || "$s_class_v" = "user" ]]; then
      ACTIVE_USR="$s_user"
      ACTIVE_SESSION="${s_type:-desktop}"
      [[ "$s_state" = "active" ]] && break
    fi
  fi
done < <(loginctl list-sessions --no-legend 2>/dev/null || true)

[ "$ACTIVE_USR" = "none" ] && ACTIVE_USR=$(who | awk '$1 !~ /root|greeter|gdm|sddm|lightdm/ {print $1; exit}' 2>/dev/null || true)
[ -z "$ACTIVE_USR" ] && ACTIVE_USR="none"

# Resolve server URL
INTRANET_HOST="${INTRANET_HOST_NAME:-}"
INTRANET_PORT_N="${INTRANET_PORT:-8080}"
TARGET_URL=""
if hostname -s 2>/dev/null | grep -qi "^${INTRANET_HOST}$" 2>/dev/null || ip -o a 2>/dev/null | grep -q "${INTRANET_IP:-NONE}/"; then
  TARGET_URL="http://127.0.0.1:${INTRANET_PORT_N}"
else
  for hb_t in "${INTRANET_HOST}:${INTRANET_PORT_N}" "${INTRANET_HOST}.local:${INTRANET_PORT_N}" "${INTRANET_IP:-}:${INTRANET_PORT_N}"; do
    [ -z "${hb_t%%:*}" ] && continue
    if curl -fsSL -m 1 "http://${hb_t}/api/health" &>/dev/null; then
      TARGET_URL="http://${hb_t}"
      break
    fi
  done
fi
[ -z "$TARGET_URL" ] && exit 0

# Poll for pending command
CMD_RESP=$(curl -fsSL -m 3 "${TARGET_URL}/api/command/poll?host=${MY_HOST}" 2>/dev/null || true)
echo "$CMD_RESP" | grep -qE '"has_command":\s*true' || exit 0

# Parse action and command
ACTION=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('command',{}).get('action',''))" 2>/dev/null <<< "$CMD_RESP" || true)

if [ "$ACTION" = "screenshot" ] && [ "$ACTIVE_USR" != "none" ]; then
  TARGET_UID=$(id -u "$ACTIVE_USR" 2>/dev/null || echo "")
  if [ -z "$TARGET_UID" ] || [ ! -d "/run/user/${TARGET_UID}" ]; then
    for udir in /run/user/[0-9]*; do
      if [ -d "$udir" ] && ls "$udir"/wayland-* &>/dev/null; then
        TARGET_UID=$(basename "$udir")
        break
      fi
    done
  fi
  [ -z "$TARGET_UID" ] && TARGET_UID=1000
  DBUS_PATH="/run/user/${TARGET_UID}/bus"
  TMP_SHOT="/tmp/screen_${MY_HOST}.png"
  rm -f "$TMP_SHOT"

  # Find wayland socket
  WL_DISP="wayland-0"
  for ws in $(ls -t "/run/user/${TARGET_UID}/wayland-"[0-9]* 2>/dev/null); do
    [ -S "$ws" ] && WL_DISP=$(basename "$ws") && break
  done

  WENV="WAYLAND_DISPLAY=${WL_DISP} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} DBUS_SESSION_BUS_ADDRESS=unix:path=${DBUS_PATH}"

  if command -v dms &>/dev/null; then
    WAYLAND_DISPLAY="${WL_DISP}" XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 5 dms screenshot full --no-notify --no-clipboard -d /tmp --filename "screen_${MY_HOST}.png" 2>/dev/null || \
    timeout 5 su "$ACTIVE_USR" -c "export ${WENV}; dms screenshot full --no-notify --no-clipboard -d /tmp --filename 'screen_${MY_HOST}.png'" < /dev/null 2>/dev/null || true
  fi
  if [ ! -s "$TMP_SHOT" ] && command -v grim &>/dev/null; then
    WAYLAND_DISPLAY="${WL_DISP}" XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" timeout 5 grim "$TMP_SHOT" 2>/dev/null || \
    timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY=${WL_DISP} XDG_RUNTIME_DIR=/run/user/${TARGET_UID}; grim '${TMP_SHOT}'" < /dev/null 2>/dev/null || true
  fi
  if [ ! -s "$TMP_SHOT" ] && command -v spectacle &>/dev/null; then
    timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY=${WL_DISP} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} DBUS_SESSION_BUS_ADDRESS=unix:path=${DBUS_PATH}; spectacle -b -n -o '${TMP_SHOT}'" < /dev/null 2>/dev/null || true
  fi
  if [ ! -s "$TMP_SHOT" ] && command -v hyprshot &>/dev/null; then
    timeout 5 su "$ACTIVE_USR" -c "export WAYLAND_DISPLAY=${WL_DISP} XDG_RUNTIME_DIR=/run/user/${TARGET_UID}; hyprshot -m output -o /tmp -f 'screen_${MY_HOST}.png'" < /dev/null 2>/dev/null || true
  fi

  if [ -s "$TMP_SHOT" ]; then
    chmod 644 "$TMP_SHOT" 2>/dev/null || true
    IMG_B64=$(base64 -w 0 "$TMP_SHOT" 2>/dev/null || true)
    if [ -n "$IMG_B64" ]; then
      curl -s -m 8 -X POST "${TARGET_URL}/api/screenshot/upload" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\": \"${MY_HOST}\", \"image_base64\": \"${IMG_B64}\"}" &>/dev/null || true
    fi
    rm -f "$TMP_SHOT"
  fi

elif [ "$ACTION" = "logs" ]; then
  LOG_OUT=$(journalctl -u ad-dms-wake-listener.service -u ad-dms-fast-poll.service -u ad-dms-refresh.service -n 50 --no-pager 2>/dev/null || true)
  LOG_OUT="${LOG_OUT}\n--- UPTIME & STATUS ---\n$(uptime 2>/dev/null || true)\n$(systemctl status ad-dms-fast-poll ad-dms-wake-listener --no-pager 2>/dev/null || true)"
  if [ -n "$LOG_OUT" ] && [ -n "$TARGET_URL" ]; then
    python3 -c "import urllib.request, json; data=json.dumps({'hostname': '''$MY_HOST''', 'log_text': '''$LOG_OUT'''}).encode(); req=urllib.request.Request('''$TARGET_URL/api/logs/upload''', data=data, headers={'Content-Type': 'application/json'}); urllib.request.urlopen(req, timeout=8)" 2>/dev/null || true
  fi

elif [ "$ACTION" = "exec" ]; then
  RAW_CMD=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('command',{}).get('cmd',''))" 2>/dev/null <<< "$CMD_RESP" || true)
  [ -z "$RAW_CMD" ] && exit 0

  # Send desktop notification if user is active
  if [ "$ACTIVE_USR" != "none" ]; then
    TARGET_UID=$(id -u "$ACTIVE_USR" 2>/dev/null || echo 1000)
    DBUS_PATH="/run/user/${TARGET_UID}/bus"
    if [ -S "$DBUS_PATH" ] && command -v notify-send &>/dev/null; then
      if echo "$RAW_CMD" | grep -qi "poweroff"; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 3 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-shutdown '⚡ System Shutdown Scheduled' 'An administrator has scheduled a workstation shutdown. Please save your work.'" < /dev/null 2>/dev/null || true
      elif echo "$RAW_CMD" | grep -qiE "reboot|soft-reboot"; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 3 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-reboot '⚡ System Restart Scheduled' 'An administrator has scheduled a workstation restart. Please save your work.'" < /dev/null 2>/dev/null || true
      elif echo "$RAW_CMD" | grep -qiE "terminate-user|quit"; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 3 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u critical -i system-log-out '🚪 Session Termination' 'Your user session is being logged out by an administrator.'" < /dev/null 2>/dev/null || true
      elif echo "$RAW_CMD" | grep -qi "refresh"; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_PATH}" timeout 3 su - "$ACTIVE_USR" -c "notify-send -a 'AD-DMS IT Center' -u normal -i system-software-update '🔄 Policy Refresh Initiated' 'Workstation configurations are synchronizing...'" < /dev/null 2>/dev/null || true
      fi
    fi
  fi

  # Execute the command immediately
  eval "$RAW_CMD" &>/dev/null &
fi
CMDEXEC_EOF
chmod +x /usr/local/bin/ad-dms-cmd-exec

# Deploy Instant Direct Push Listener (Wakes ad-dms-cmd-exec immediately on host command dispatch)
cat <<'EOF' > /usr/local/bin/ad-dms-wake-listener
#!/usr/bin/env python3
import socket, subprocess, sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("0.0.0.0", 8081))
except Exception:
    sys.exit(0)

while True:
    try:
        data, addr = sock.recvfrom(1024)
        if data and b"WAKE_GUI_SCAN" in data:
            # Call the FAST dedicated executor, not the heavy flatpak scanner
            subprocess.Popen(["/usr/local/bin/ad-dms-cmd-exec"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
EOF
chmod +x /usr/local/bin/ad-dms-wake-listener

cat <<'EOF' > /etc/systemd/system/ad-dms-wake-listener.service
[Unit]
Description=AD-DMS Direct Push Remote Wake Trigger Listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ad-dms-wake-listener
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now ad-dms-gui-scan.timer 2>/dev/null || true
systemctl enable --now ad-dms-wake-listener.service 2>/dev/null || true
systemctl enable --now ad-dms-fast-poll.service 2>/dev/null || true
echo -e "  -> ${GREEN}[FAST REMOTE]${NC} Fast Remote Command Poller active (3s interval, fast executor)."
echo -e "  -> ${GREEN}[DIRECT PUSH]${NC} Instant Remote Wake Listener active on UDP:8081 (fast executor)."
echo -e "  -> ${GREEN}[GUI GUARD]${NC} Automated background Flatpak GUI scanner guard active (1min timer)."

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

# Deploy /usr/local/bin/heartbeat CLI Diagnostics Tool
cat <<'HB_EOF' > /usr/local/bin/heartbeat
#!/usr/bin/env bash
# AD-DMS Heartbeat Status & Telemetry Diagnostic Tool
set -euo pipefail

BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}                   ${BOLD}${YELLOW}AD-DMS HEARTBEAT & TELEMETRY MONITOR${NC}                   ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"

CONF_DIR="/etc/ad-dms"
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

MY_CURR_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "UNKNOWN")

# 1. Daemon / Timer Status
echo -e "\n${BOLD}${CYAN}[1/4] Heartbeat Daemon & Timer Engine:${NC}"
if systemctl is-active --quiet ad-dms-gui-scan.timer 2>/dev/null; then
  SCAN_INFO=$(systemctl list-timers ad-dms-gui-scan.timer --no-pager 2>/dev/null | grep -E "ad-dms-gui-scan\.timer" || true)
  SCAN_LEFT=$(echo "$SCAN_INFO" | awk '{print $3}' || echo "unknown")
  SCAN_NEXT=$(echo "$SCAN_INFO" | awk '{print $1, $2}' || echo "unknown")
  echo -e "  ● ${GREEN}ad-dms-gui-scan.timer:${NC} ${BOLD}ACTIVE${NC} (Runs every 1min)"
  echo -e "    -> Next heartbeat scheduled in: ${GREEN}${SCAN_LEFT}${NC} (Next run: ${SCAN_NEXT})"
else
  echo -e "  ○ ${YELLOW}ad-dms-gui-scan.timer:${NC} ${YELLOW}INACTIVE${NC} (Background daemon not running)"
fi

if systemctl is-active --quiet ad-dms-refresh.timer 2>/dev/null; then
  REF_INFO=$(systemctl list-timers ad-dms-refresh.timer --no-pager 2>/dev/null | grep -E "ad-dms-refresh\.timer" || true)
  REF_LEFT=$(echo "$REF_INFO" | awk '{print $3}' || echo "unknown")
  echo -e "  ● ${GREEN}ad-dms-refresh.timer:${NC}  ${BOLD}ACTIVE${NC} (Scheduled refresh in ${REF_LEFT})"
fi

# 2. Upstream Intranet Host Configuration
echo -e "\n${BOLD}${CYAN}[2/4] Configured Intranet Telemetry Host:${NC}"
echo -e "  ■ Target Host:  ${BOLD}${INTRANET_HOST}${NC}"
echo -e "  ■ Fallback IP:  ${BOLD}${INTRANET_IP}${NC}"
echo -e "  ■ Port:         ${BOLD}${INTRANET_PORT}${NC}"

# 3. Last Heartbeat Transmission Record
echo -e "\n${BOLD}${CYAN}[3/4] Last Transmission Log:${NC}"
LAST_HB_FILE="${CONF_DIR}/.last_heartbeat"
if [ -f "$LAST_HB_FILE" ]; then
  LAST_LOG=$(cat "$LAST_HB_FILE" 2>/dev/null || echo "No details recorded")
  echo -e "  -> ${GREEN}[SUCCESS]${NC} ${LAST_LOG}"
else
  echo -e "  -> ${YELLOW}[INFO]${NC} No previous heartbeat record found at '${LAST_HB_FILE}'."
fi

# 4. Live Server Connectivity Probe
echo -e "\n${BOLD}${CYAN}[4/4] Live Telemetry Server Probe:${NC}"
probe_success=false
PROBE_TARGETS=()

if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP}/"; then
  PROBE_TARGETS+=("127.0.0.1:${INTRANET_PORT}")
fi
PROBE_TARGETS+=("${INTRANET_HOST}:${INTRANET_PORT}" "${INTRANET_HOST}.local:${INTRANET_PORT}" "${INTRANET_IP}:${INTRANET_PORT}")

for target in "${PROBE_TARGETS[@]}"; do
  HTTP_CODE=$(curl -fsSL -m 2 -o /dev/null -w "%{http_code}" "http://${target}/api/clients" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo -e "  -> ${GREEN}● ONLINE & CONNECTED:${NC} Successfully reached host at ${BOLD}http://${target}${NC} (HTTP 200 OK)"
    probe_success=true
    break
  fi
done

if [ "$probe_success" = false ]; then
  echo -e "  -> ${RED}○ UNREACHABLE:${NC} Cannot connect to central intranet server at ${INTRANET_HOST}:${INTRANET_PORT}."
  echo -e "     ${YELLOW}(Check if ad-dms-server.service is running on the host machine or check network cables)${NC}"
fi
echo ""
HB_EOF
chmod +x /usr/local/bin/heartbeat
echo -e "  -> ${GREEN}[HEARTBEAT CLI]${NC} Telemetry monitor active at /usr/local/bin/heartbeat"

# F. Deploy Interactive Shell Interceptors & Aliases (/etc/profile.d/99-ad-dms-aliases.sh)
cat <<'EOF' > /etc/profile.d/99-ad-dms-aliases.sh
# AD-DMS Command Redirections & User Helpers
alias refresh='sudo /usr/local/bin/refresh'
alias heartbeat='/usr/local/bin/heartbeat'
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

# Comprehensive DMS & Desktop Preset Sync for ALL Users & /etc/skel Template
# Ensures new and existing Active Directory / local users get full working DMS & Niri desktop
PRESETS_DIR=""
for cand_dir in "${CONF_DIR}/presets" "${SCRIPT_DIR:-}/presets" "/home/jk/Projects/fedora-ad-dms/presets" "/tmp/fedora-ad-dms/presets"; do
  if [ -d "$cand_dir" ] && ls "$cand_dir"/*.tar.gz &>/dev/null; then
    PRESETS_DIR="$cand_dir"
    break
  fi
done

for user_home in /etc/skel /home/*; do
  [ -d "$user_home" ] || continue
  u_name=$(basename "$user_home")
  [ "$u_name" = "*" ] && continue

  mkdir -p "${user_home}/.config" "${user_home}/.local/share" "${user_home}/.config/autostart"

  # Unpack presets: always update /etc/skel template; for existing users, unpack if missing essential components
  if [ -n "$PRESETS_DIR" ] && [ -d "$PRESETS_DIR" ]; then
    should_unpack=false
    if [ "$user_home" = "/etc/skel" ]; then
      should_unpack=true
    elif [ ! -d "${user_home}/.config/niri" ] || [ ! -d "${user_home}/.config/DankMaterialShell" ]; then
      should_unpack=true
    fi

    if [ "$should_unpack" = true ]; then
      for preset_archive in "${PRESETS_DIR}"/*.tar.gz "${PRESETS_DIR}"/*.tgz "${PRESETS_DIR}"/*.tar; do
        [ -f "$preset_archive" ] || continue
        if tar -tzf "$preset_archive" 2>/dev/null | grep -q -E '^\.?/?(\.config|\.local|\.bash|\.zsh|\.profile|etc|usr)'; then
          tar -xzf "$preset_archive" -C "$user_home" 2>/dev/null || true
        else
          tar -xzf "$preset_archive" -C "${user_home}/.config" 2>/dev/null || true
        fi
      done
    fi
  fi

  # CRITICAL: Always remove hardcoded outputs.kdl so niri dynamically handles the current monitor
  rm -f "${user_home}/.config/niri/dms/outputs.kdl"
  rm -f "${user_home}/.config/niri/config.kdl.backup"*

  # Ensure Niri config spawns DMS safely without duplicate lines
  niri_kdl="${user_home}/.config/niri/config.kdl"
  if [ -f "$niri_kdl" ]; then
    if ! grep -E -q '(spawn-at-startup[[:space:]]+("dms"|dms))' "$niri_kdl"; then
      sed -i '1s/^/spawn-at-startup "dms" "run"\n/' "$niri_kdl"
    fi
  fi

  # Autostart fallback desktop entry
  cat <<'DMS_AUTOS_EOF' > "${user_home}/.config/autostart/dms.desktop"
[Desktop Entry]
Type=Application
Name=Dank Material Shell
Exec=dms run
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DMS_AUTOS_EOF

  # Fix permissions and ownership
  if [ "$user_home" = "/etc/skel" ]; then
    chown -R root:root /etc/skel 2>/dev/null || true
    chmod 755 /etc/skel 2>/dev/null || true
    [ -d /etc/skel/.config ] && chmod 755 /etc/skel/.config 2>/dev/null || true
    find /etc/skel -type d -exec chmod 755 {} + 2>/dev/null || true
    find /etc/skel -type f -exec chmod 644 {} + 2>/dev/null || true
  else
    if id "$u_name" &>/dev/null; then
      chown -R "${u_name}:" "${user_home}/.config" "${user_home}/.local" 2>/dev/null || true
    fi
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
MY_CURR_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
INTRANET_HOST_VAL="${INTRANET_HOST_NAME:-${INTRANET_HOST:-GSFCUPLLAB203}}"
INTRANET_IP_VAL="${INTRANET_FALLBACK_IP:-${INTRANET_IP:-10.205.18.253}}"

# Find web_server.py in local repo or /etc/ad-dms or workspace
SERVER_SCRIPT=""
for candidate in "${PWD}/web_server.py" "${SCRIPT_DIR:-}/web_server.py" "/home/jk/Projects/fedora-ad-dms/web_server.py" "/etc/ad-dms/web_server.py"; do
  if [ -f "$candidate" ]; then
    SERVER_SCRIPT="$candidate"
    break
  fi
done

if [ -n "$SERVER_SCRIPT" ]; then
  # If current machine is the Central Host or has the fallback IP
  if [ "${MY_CURR_HOST,,}" = "${INTRANET_HOST_VAL,,}" ] || ip -o a 2>/dev/null | grep -q "${INTRANET_IP_VAL}/"; then
    SERVER_DIR="$(dirname "$SERVER_SCRIPT")"
    cat <<EOF > /etc/systemd/system/ad-dms-server.service
[Unit]
Description=AD-DMS Intranet Host Telemetry & API Daemon (Port 8080)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${SERVER_DIR}
ExecStart=/usr/bin/python3 ${SERVER_SCRIPT}
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
    echo -e "  -> ${GREEN}[SERVER ACTIVE]${NC} ad-dms-server.service started and running on port ${INTRANET_PORT:-8080}."
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
