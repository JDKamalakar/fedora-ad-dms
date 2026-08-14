#!/usr/bin/env bash
# ==============================================================================
# Active Directory & Niri DMS Interactive TUI (setup-ad-dms-tui.sh)
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# Locate current script directory and local files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONFIG="${SCRIPT_DIR}/lab.conf"
LOCAL_TAR="${SCRIPT_DIR}/niri-dms-config.tar.gz"

# Fallbacks if run standalone
if [ ! -f "$LOCAL_CONFIG" ] && [ -f "/etc/lab.conf" ]; then
    LOCAL_CONFIG="/etc/lab.conf"
fi

# Terminal ANSI Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

draw_header() {
    clear
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${BOLD}          🖥️  GSFCU LAB SSSD & NIRI DMS MANAGEMENT TUI          ${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo
}

ensure_files() {
    if [ ! -f "$LOCAL_CONFIG" ]; then
        echo -e "${RED}❌ Error: 'lab.conf' missing in ${SCRIPT_DIR}${NC}" >&2
        exit 1
    fi
    # Also copy lab.conf to /etc/ for system reference
    cp "$LOCAL_CONFIG" /etc/lab.conf
}

deploy_niri_config() {
    if [ ! -f "$LOCAL_TAR" ]; then
        echo -e "${RED}❌ Error: 'niri-dms-config.tar.gz' missing in ${SCRIPT_DIR}${NC}"
        return 1
    fi

    echo -e "${YELLOW}📦 Extracting 'niri-dms-config.tar.gz'...${NC}"
    TMP_DIR="/tmp/niri-dms-config-extracted"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    tar -xzf "$LOCAL_TAR" -C "$TMP_DIR"

    echo -e "${YELLOW}📂 Deploying to /etc/skel (for future logins)...${NC}"
    cp -r "$TMP_DIR"/. /etc/skel/ 2>/dev/null || cp -r "$TMP_DIR"/* /etc/skel/ 2>/dev/null || true

    echo -e "${YELLOW}📂 Syncing config to existing user homes in /home/...${NC}"
    for user_dir in /home/*; do
        if [ -d "$user_dir" ]; then
            u_name=$(basename "$user_dir")
            u_group=$(id -gn "$u_name" 2>/dev/null || echo "$u_name")
            cp -r "$TMP_DIR"/. "$user_dir/" 2>/dev/null || cp -r "$TMP_DIR"/* "$user_dir/" 2>/dev/null || true
            chown -R "$u_name:$u_group" "$user_dir" 2>/dev/null || true
            echo -e "   • Applied to ${CYAN}$user_dir${NC}"
        fi
    done
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ Niri DMS configuration applied system-wide!${NC}"
}

apply_sssd_deny_rules() {
    local target_ad_group="$1"
    ensure_files

    ALL_GROUPS=()
    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        ad_group=$(echo "${ad_group:-}" | xargs)
        [[ -z "$ad_group" || "$lab_name" =~ ^# ]] && continue
        ALL_GROUPS+=("$ad_group")
    done < "$LOCAL_CONFIG"

    DENY_GROUPS=()
    if [ -n "$target_ad_group" ]; then
        for g in "${ALL_GROUPS[@]}"; do
            if [ "$g" != "$target_ad_group" ]; then
                DENY_GROUPS+=("$g")
            fi
        done
        DENY_GROUPS_STR=$(IFS=,; echo "${DENY_GROUPS[*]}")
        ACCESS_BLOCK="access_provider = simple
simple_deny_groups = ${DENY_GROUPS_STR}"
    else
        ACCESS_BLOCK="access_provider = permit"
    fi

    echo -e "${YELLOW}⏹️ Stopping SSSD service...${NC}"
    systemctl stop sssd || true
    systemctl reset-failed sssd || true

    echo -e "${YELLOW}📝 Writing /etc/sssd/sssd.conf...${NC}"
    cat <<EOF > /etc/sssd/sssd.conf
[sssd]
services = nss, pam
domains = gsfcu.local

[domain/gsfcu.local]
id_provider = ad
${ACCESS_BLOCK}
ad_domain = gsfcu.local
krb5_realm = GSFCU.LOCAL
ldap_id_mapping = True
use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash
cache_credentials = True
EOF

    sed -i 's/\r$//' /etc/sssd/sssd.conf
    chown root:root /etc/sssd/sssd.conf
    chmod 600 /etc/sssd/sssd.conf
    restorecon -v /etc/sssd/sssd.conf 2>/dev/null || true

    echo -e "${YELLOW}🧹 Flushing SSSD database cache...${NC}"
    rm -rf /var/lib/sss/db/*
    systemctl start sssd

    echo -e "${GREEN}✅ SSSD configured and running!${NC}"
}

# --- Menu Actions ---

auto_setup() {
    draw_header
    ensure_files
    RAW_HOSTNAME=$(hostname -s | tr '[:lower:]' '[:upper:]')
    MATCHED_LAB=""
    MATCHED_GROUP=""

    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        pattern=$(echo "${pattern:-}" | xargs | tr '[:lower:]' '[:upper:]')
        [[ -z "$pattern" || "$lab_name" =~ ^# ]] && continue

        if [[ "$RAW_HOSTNAME" == "$pattern"* ]]; then
            MATCHED_LAB="$lab_name"
            MATCHED_GROUP="$ad_group"
            break
        fi
    done < "$LOCAL_CONFIG"

    echo -e "📌 ${BOLD}Hostname:${NC} $RAW_HOSTNAME"
    if [ -n "$MATCHED_GROUP" ]; then
        echo -e "📌 ${BOLD}Detected Lab:${NC} $MATCHED_LAB"
        echo -e "📌 ${BOLD}Allowed Group:${NC} $MATCHED_GROUP"
    else
        echo -e "${YELLOW}⚠️ No match found for this hostname pattern in lab.conf.${NC}"
    fi
    echo

    read -rp "Run full deployment (SSSD Access + Niri Config)? [Y/n]: " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_sssd_deny_rules "$MATCHED_GROUP"
        deploy_niri_config
    fi
    read -rp "Press [Enter] to return to menu..."
}

manual_lab_select() {
    draw_header
    ensure_files

    echo -e "${BOLD}Select a Lab to ALLOW on this machine:${NC}\n"
    LAB_NAMES=()
    AD_GROUPS=()

    while IFS=':' read -r lab_name ad_group pattern || [ -n "$lab_name" ]; do
        lab_name=$(echo "${lab_name:-}" | xargs)
        ad_group=$(echo "${ad_group:-}" | xargs)
        [[ -z "$ad_group" || "$lab_name" =~ ^# ]] && continue
        LAB_NAMES+=("$lab_name")
        AD_GROUPS+=("$ad_group")
    done < "$LOCAL_CONFIG"

    for i in "${!LAB_NAMES[@]}"; do
        printf "  ${CYAN}[%2d]${NC} %-30s (Group: %s)\n" $((i+1)) "${LAB_NAMES[$i]}" "${AD_GROUPS[$i]}"
    done
    echo -e "  ${CYAN}[ 0]${NC} Cancel"
    echo

    read -rp "Enter choice [0-${#LAB_NAMES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#LAB_NAMES[@]}" ]; then
        idx=$((choice-1))
        echo -e "\nApplying rules for ${GREEN}${LAB_NAMES[$idx]}${NC} (${AD_GROUPS[$idx]})..."
        apply_sssd_deny_rules "${AD_GROUPS[$idx]}"
        deploy_niri_config
    fi
    read -rp "Press [Enter] to return to menu..."
}

diagnostics() {
    draw_header
    echo -e "${BOLD}🔍 Running Diagnostics...${NC}\n"
    
    echo -n "• SSSD Service: "
    if systemctl is-active --quiet sssd; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED/FAILED${NC}"
    fi

    echo -n "• AD User Lookup (oslab): "
    if id oslab &>/dev/null; then
        echo -e "${GREEN}SUCCESSFUL${NC}"
        id oslab
    else
        echo -e "${RED}FAILED${NC}"
    fi

    echo -e "\n• Current SSSD Rules:"
    grep -E "access_provider|simple_deny_groups" /etc/sssd/sssd.conf || echo "None set"

    echo
    read -rp "Press [Enter] to return to menu..."
}

# --- Main Loop ---
while true; do
    draw_header
    echo -e "Please select an option:\n"
    echo -e "  ${CYAN}[1]${NC} 🚀 Auto Setup (SSSD Rules + Niri Config via Host Match)"
    echo -e "  ${CYAN}[2]${NC} ⚙️  Manual Lab Selection Override"
    echo -e "  ${CYAN}[3]${NC} 📦 Sync Niri DMS Config Only (/etc/skel & /home/*)"
    echo -e "  ${CYAN}[4]${NC} 🧪 Test AD User Lookup & SSSD Status"
    echo -e "  ${CYAN}[5]${NC} 🚪 Exit"
    echo
    read -rp "Select an option [1-5]: " opt

    case "$opt" in
        1) auto_setup ;;
        2) manual_lab_select ;;
        3) draw_header; deploy_niri_config; read -rp "Press [Enter] to return..." ;;
        4) diagnostics ;;
        5) clear; echo "👋 Exiting."; exit 0 ;;
        *) echo -e "${RED}Invalid selection!${NC}"; sleep 1 ;;
    esac
done
