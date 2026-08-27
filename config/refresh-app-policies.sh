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

  # 2. Fast Bulk Removal of installed blacklisted RPMs (Query all at once instead of pkg-by-pkg)
  INSTALLED_RPMS=()
  for pkg in "${dnf_apps[@]:-}"; do
    [ -z "$pkg" ] && continue
    if rpm -qa "$pkg" 2>/dev/null | grep -q .; then
      INSTALLED_RPMS+=("$pkg")
    fi
  done

  if [ ${#INSTALLED_RPMS[@]} -gt 0 ]; then
    echo -e "  -> ${RED}[DNF REMOVE]${NC} Purging blacklisted packages: ${INSTALLED_RPMS[*]}"
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
  CURRENT_FPS=$(flatpak list --app --columns=application 2>/dev/null || true)
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

CURRENT_INSTALLED=$(flatpak list --app --columns=application 2>/dev/null || true)
for b_app in "${BLOCKED_FLATPAKS[@]}"; do
  [ -z "$b_app" ] && continue
  if echo "$CURRENT_INSTALLED" | grep -q -i -E "^${b_app}$"; then
    flatpak kill "$b_app" 2>/dev/null || true
    flatpak uninstall -y --system "$b_app" 2>/dev/null || true
    flatpak uninstall -y --user "$b_app" 2>/dev/null || true
    
    # Resolve human readable name
    HUMAN_TITLE=$(python3 -c "
import glob, xml.etree.ElementTree as ET
target = '$b_app'.lower().removesuffix('.desktop')
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
print(title or '$b_app')
" 2>/dev/null || echo "$b_app")

    # Record and notify
    ACTIVE_USER=$(who 2>/dev/null | awk '{print $1; exit}' || echo "user")
    if [ -x /usr/local/bin/ad-dms-record-violation ]; then
      /usr/local/bin/ad-dms-record-violation "$ACTIVE_USER" "$b_app" "gui_store_install" 2>/dev/null || true
    fi

    if command -v notify-send &>/dev/null; then
      notify-send -u critical -i dialog-error "Unauthorized Application Blocked" "Access Denied: ${HUMAN_TITLE} was removed per University IT Policy." 2>/dev/null || true
    fi
  fi
done
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
OnBootSec=1min
OnUnitActiveSec=2min
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

  # Try brightnessctl if available
  if command -v brightnessctl &>/dev/null; then
    brightnessctl set 100% &>/dev/null || true
  fi

  # Try ddcutil for external monitors
  if command -v ddcutil &>/dev/null; then
    ddcutil setvcp 10 100 &>/dev/null || true
  fi
fi

# 2. Enforce 100% Volume
if [ "$(echo "$LOCK_VOLUME" | tr '[:upper:]' '[:lower:]')" = "yes" ]; then
  if command -v wpctl &>/dev/null; then
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 &>/dev/null || true
    wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 &>/dev/null || true
  fi
  if command -v pactl &>/dev/null; then
    pactl set-sink-mute @DEFAULT_SINK@ 0 &>/dev/null || true
    pactl set-sink-volume @DEFAULT_SINK@ 100% &>/dev/null || true
  fi
  if command -v amixer &>/dev/null; then
    amixer set Master 100% unmute &>/dev/null || true
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
/usr/local/bin/ad-dms-device-enforce 2>/dev/null || true
echo -e "  -> ${GREEN}[DEVICE GUARD]${NC} Hardware policy guard active (Brightness 100% & Sound 100% locked every 5min)."

# F. Deploy Interactive Shell Interceptors & Aliases (/etc/profile.d/99-ad-dms-aliases.sh)
cat <<'EOF' > /etc/profile.d/99-ad-dms-aliases.sh
# AD-DMS Command Redirections & User Helpers
alias refresh='sudo /usr/local/bin/refresh'

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
if [ -f "${CONF_DIR}/remote-tasks.sh" ]; then
  # shellcheck source=/dev/null
  source "${CONF_DIR}/remote-tasks.sh" 2>/dev/null || true
  echo -e "  ${GREEN}[STATUS] remote-tasks.sh executed successfully.${NC}\n"
else
  echo -e "  ${YELLOW}[SKIP] remote-tasks.sh not found.${NC}\n"
fi

echo -e "${BOLD}${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN}         ALL SYSTEM & APP POLICIES SYNCHRONIZED SUCCESSFULLY          ${NC}"
echo -e "${BOLD}${GREEN}======================================================================${NC}\n"
