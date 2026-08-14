#!/usr/bin/env bash
set -euo pipefail

#!/usr/bin/env bash
# ==============================================================================
# Pure Shell SSSD Installer & TUI
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# GitHub Configuration (UPDATE THESE VALUES)
# ------------------------------------------------------------------------------
GITHUB_USER="JDKamalakar"
GITHUB_REPO="fedora-ad-dms"
BRANCH="main"
CONFIG_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/lab.config"

# File Locations
LOCAL_CONFIG="/etc/lab.config"

# Terminal Formatting (ANSI Colors)
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Ensure Script Runs as Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Error: This script must be run as root or with sudo.${NC}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
draw_header() {
    clear
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${BOLD}          🖥️  GSFCU LAB SSSD & AD AUTOMATED SETUP          ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo
}

ensure_config_file() {
    if [ ! -f "$LOCAL_CONFIG" ]; then
        echo -e "${YELLOW}📥 'lab.config' not found locally. Fetching from GitHub...${NC}"
        if command -v curl &>/dev/null; then
            curl -sSL "$CONFIG_URL" -o "$LOCAL_CONFIG"
        elif command -v wget &>/dev/null; then
            wget -q "$CONFIG_URL" -O "$LOCAL_CONFIG"
        else
            echo -e "${RED}❌ Error: Neither curl nor wget is installed to download lab.config.${NC}"
            return 1
        fi
        echo -e "${GREEN}✅ Downloaded 'lab.config' to $LOCAL_CONFIG${NC}"
    fi
}

detect_lab_group() {
    RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
    DETECTED_GROUP=""
    DETECTED_NAME=""

    if [ -f "$LOCAL_CONFIG" ]; then
        while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
            lab_name=$(echo "${lab_name:-}" | xargs)
            ad_group=$(echo "${ad_group:-}" | xargs)
            pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')

            [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

            if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
                DETECTED_NAME="$lab_name"
                DETECTED_GROUP="$ad_group"
                break
            fi
        done < "$LOCAL_CONFIG"
    fi
}

apply_sssd_config() {
    local target_group="$1"
    local access_prov="simple"
    local allow_line="simple_allow_groups = ${target_group}"

    if [ -z "$target_group" ]; then
        access_prov="permit"
        allow_line="# simple_allow_groups = (unrestricted domain access)"
    fi

    echo -e "${YELLOW}⏹️  Stopping SSSD service...${NC}"
    systemctl stop sssd || true
    systemctl reset-failed sssd || true

    echo -e "${YELLOW}📝 Writing /etc/sssd/sssd.conf...${NC}"
    cat <<EOF > /etc/sssd/sssd.conf
[sssd]
services = nss, pam
domains = gsfcu.local

[domain/gsfcu.local]
id_provider = ad
access_provider = ${access_prov}
${allow_line}
ad_domain = gsfcu.local
krb5_realm = GSFCU.LOCAL
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
cache_credentials = True
EOF

    echo -e "${YELLOW}🔒 Applying security permissions...${NC}"
    sed -i 's/\r$//' /etc/sssd/sssd.conf
    chown root:root /etc/sssd/sssd.conf
    chmod 600 /etc/sssd/sssd.conf
    restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true

    echo -e "${YELLOW}🧹 Flushing SSSD database cache...${NC}"
    rm -rf /var/lib/sss/db/*

    echo -e "${YELLOW}▶️  Starting SSSD...${NC}"
    systemctl start sssd

    echo
    if systemctl is-active --quiet sssd; then
        echo -e "${GREEN}✅ SSSD configured and running successfully!${NC}"
    else
        echo -e "${RED}❌ SSSD failed to start. Run 'journalctl -u sssd -xe' for logs.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# Menu Options
# ------------------------------------------------------------------------------
auto_configure() {
    draw_header
    ensure_config_file
    detect_lab_group

    echo -e "📌 ${BOLD}Hostname:${NC} $(hostname -s)"
    if [ -n "$DETECTED_GROUP" ]; then
        echo -e "📌 ${BOLD}Detected Lab:${NC} $DETECTED_NAME"
        echo -e "📌 ${BOLD}AD Group ID:${NC}  $DETECTED_GROUP"
        echo
        read -rp "Proceed with auto-configuration? [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            apply_sssd_config "$DETECTED_GROUP"
        fi
    else
        echo -e "${RED}⚠️  No hostname pattern matched in lab.config.${NC}"
        echo
        read -rp "Apply default open domain access (permit all)? [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            apply_sssd_config ""
        fi
    fi
    read -rp "Press [Enter] to return to menu..."
}

manual_select() {
    draw_header
    ensure_config_file

    echo -e "${BOLD}Select a Lab from the list:${NC}\n"
    
    # Store options in arrays
    mapfile -t LAB_NAMES < <(grep -v '^#' "$LOCAL_CONFIG" | grep -v '^$' | cut -d':' -f1 | xargs -L1)
    mapfile -t AD_GROUPS < <(grep -v '^#' "$LOCAL_CONFIG" | grep -v '^$' | cut -d':' -f2 | xargs -L1)

    for i in "${!LAB_NAMES[@]}"; do
        printf "  ${CYAN}[%2d]${NC} %-30s (AD Group: %s)\n" $((i+1)) "${LAB_NAMES[$i]}" "${AD_GROUPS[$i]}"
    done
    echo -e "  ${CYAN}[ 0]${NC} Cancel"
    echo

    read -rp "Enter choice [0-${#LAB_NAMES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#LAB_NAMES[@]}" ]; then
        index=$((choice-1))
        echo -e "\nSelected: ${GREEN}${LAB_NAMES[$index]}${NC} (${AD_GROUPS[$index]})"
        apply_sssd_config "${AD_GROUPS[$index]}"
    fi
    read -rp "Press [Enter] to return to menu..."
}

test_connection() {
    draw_header
    echo -e "${BOLD}🔍 Running Active Directory Diagnostics...${NC}\n"
    
    echo -n "• SSSD Service Status: "
    if systemctl is-active --quiet sssd; then
        echo -e "${GREEN}ACTIVE${NC}"
    else
        echo -e "${RED}INACTIVE / FAILED${NC}"
    fi

    echo -n "• Domain Lookup (oslab): "
    if id oslab &>/dev/null; then
        echo -e "${GREEN}SUCCESS${NC}"
        id oslab
    else
        echo -e "${RED}FAILED (User oslab not found)${NC}"
    fi

    echo
    read -rp "Press [Enter] to return to menu..."
}

# ------------------------------------------------------------------------------
# Main TUI Loop
# ------------------------------------------------------------------------------
while true; do
    draw_header
    echo -e "Please select an option:\n"
    echo -e "  ${CYAN}[1]${NC} 🚀 Automatic Setup (Auto-Detect Hostname via lab.config)"
    echo -e "  ${CYAN}[2]${NC} ⚙️  Manual Lab ID Selection"
    echo -e "  ${CYAN}[3]${NC} 🧪 Test AD User Lookup & SSSD Status"
    echo -e "  ${CYAN}[4]${NC} 🚪 Exit"
    echo
    read -rp "Select an option [1-4]: " opt

    case "$opt" in
        1) auto_configure ;;
        2) manual_select ;;
        3) test_connection ;;
        4) clear; echo "👋 Exiting installer."; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done
