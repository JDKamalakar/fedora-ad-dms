#!/usr/bin/env bash
# ==============================================================================
# Script Name : setup-ad-dms-tui.sh
# Description : Fedora AD Domain Join + DankLinux DMS Installer + pVPN Setup
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & DEFAULT VALUES
# ------------------------------------------------------------------------------
CONFIG_FILE="domain.conf"

# Step 0: pVPN Configuration
# Options for PVPN_ENABLE: "yes" (auto-run), "no" (skip), "ask" (prompt user)
PVPN_ENABLE="ask"
PVPN_ID="gsfcu@proton.me"
PVPN_PASS="Test@1199"

# AD & User Configuration Defaults
DOMAIN_NAME="lab.local"
DOMAIN_REALM="LAB.LOCAL"
DOMAIN_ADMIN="Administrator"
DOMAIN_PASS="Admin123!"
TARGET_USER="sysadmin"

# Load external config file if available
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Parse CLI flags
SKIP_STEP0=0
AUTO_ACCEPT=0

for arg in "$@"; do
    case "$arg" in
        --skip-step0) SKIP_STEP0=1 ;;
        -y|--yes) AUTO_ACCEPT=1 ;;
    esac
done

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------
log_info()  { echo -e "\e[34m[INFO]\e[0m $1"; }
log_ok()    { echo -e "\e[32m[OK]\e[0m $1"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
log_err()   { echo -e "\e[31m[ERROR]\e[0m $1"; }

is_live_env() {
    if grep -q "boot=live" /proc/cmdline || [[ -d /run/initramfs/live ]] || [[ "$USER" == "liveuser" ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# STEP 0: PROTON VPN (pVPN) SETUP
# ------------------------------------------------------------------------------
run_step_0_pvpn() {
    echo "============================================================"
    log_info "STEP 0: ProtonVPN (pVPN) Setup"
    echo "============================================================"

    if [[ "$SKIP_STEP0" -eq 1 ]]; then
        log_warn "Skipping Step 0 (--skip-step0 flag provided)."
        return 0
    fi

    local should_run=0

    case "$PVPN_ENABLE" in
        "yes")
            should_run=1
            ;;
        "no")
            log_info "pVPN installation is disabled in config (PVPN_ENABLE=no)."
            return 0
            ;;
        "ask")
            if [[ "$AUTO_ACCEPT" -eq 1 ]]; then
                should_run=1
            else
                read -rp "Do you want to install and connect pVPN? [y/N]: " choice
                case "$choice" in
                    [yY][eE][sS]|[yY]) should_run=1 ;;
                    *) log_info "Skipping pVPN setup."; return 0 ;;
                esac
            fi
            ;;
        *)
            log_warn "Invalid PVPN_ENABLE value '$PVPN_ENABLE'. Defaulting to skip."
            return 0
            ;;
    esac

    if [[ "$should_run" -eq 1 ]]; then
        log_info "Installing pVPN daemon and CLI..."
        curl -fsSL https://raw.githubusercontent.com/YourDoritos/pVPN/main/install.sh | sudo bash

        log_info "Ensuring pVPN service daemon is active..."
        sudo systemctl enable --now pvpnd || true

        log_info "Logging into Proton VPN with configured credentials..."
        # Attempt CLI login via arguments or pipe if interactive input is expected
        pvpnctl login -u "$PVPN_ID" -p "$PVPN_PASS" 2>/dev/null || \
            printf "%s\n%s\n" "$PVPN_ID" "$PVPN_PASS" | pvpnctl login || true

        log_info "Connecting to VPN..."
        pvpnctl connect fastest || pvpnctl connect || log_warn "Could not connect to VPN automatically. Please run 'pvpn' manually."
        
        log_ok "Step 0 Complete: pVPN initialized."
    fi
}

# ------------------------------------------------------------------------------
# STEP 1-3: ACTIVE DIRECTORY JOIN & SYSTEM PREP
# ------------------------------------------------------------------------------
run_ad_join() {
    echo "============================================================"
    log_info "STEP 1-3: Joining Active Directory Domain ($DOMAIN_NAME)"
    echo "============================================================"

    log_info "Installing required packages (realmd, sssd, adcli, samba-common-tools)..."
    sudo dnf install -y realmd sssd adcli samba-common-tools krb5-workstation

    log_info "Discovering realm $DOMAIN_NAME..."
    realm discover "$DOMAIN_NAME"

    log_info "Joining domain..."
    echo "$DOMAIN_PASS" | sudo realm join -U "$DOMAIN_ADMIN" "$DOMAIN_NAME"

    log_info "Enabling home directory auto-creation..."
    sudo authselect enable-feature with-mkhomedir
    sudo systemctl restart sssd

    log_ok "Domain join successful."
}

# ------------------------------------------------------------------------------
# STEP 4: DMS INSTALLATION FOR INITIATED USER
# ------------------------------------------------------------------------------
run_dms_install() {
    echo "============================================================"
    log_info "STEP 4: DankLinux DMS Installation for Initiated User ($TARGET_USER)"
    echo "============================================================"

    # Determine real user home directory
    local target_home="/home/$TARGET_USER"

    if is_live_env; then
        log_warn "Live environment detected!"
        log_info "Configuring 1-time First-Login auto-installer for '$TARGET_USER' post-boot..."

        # Create target autostart directory
        local autostart_dir="$target_home/.config/autostart"
        local script_dir="$target_home/.local/bin"
        mkdir -p "$autostart_dir" "$script_dir"

        # Drop the first-boot installer script
        cat << 'EOF' > "$script_dir/install-dms-firstboot.sh"
#!/usr/bin/env bash
# One-time DMS post-install trigger
sleep 5
notify-send "DMS Installer" "Installing DankLinux DMS environment..." || true
curl -fsSL https://install.danklinux.com | sh
rm -f ~/.config/autostart/dms-installer.desktop
rm -f ~/.local/bin/install-dms-firstboot.sh
EOF

        chmod +x "$script_dir/install-dms-firstboot.sh"

        # Drop the .desktop autostart launcher
        cat << EOF > "$autostart_dir/dms-installer.desktop"
[Desktop Entry]
Type=Application
Name=Install DMS
Exec=$script_dir/install-dms-firstboot.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

        # Ensure correct ownership of user home files
        if id "$TARGET_USER" &>/dev/null; then
            chown -R "$TARGET_USER:$TARGET_USER" "$target_home/.config" "$target_home/.local"
        fi

        log_ok "First-boot installer deployed. DMS will install automatically when $TARGET_USER logs in post-reboot."

    else
        log_info "Running system directly. Launching DMS installer under user '$TARGET_USER'..."

        if ! id "$TARGET_USER" &>/dev/null; then
            log_err "Target user '$TARGET_USER' does not exist yet. Please create the user first."
            return 1
        fi

        # Spoof/Clean environment variables so DMS script runs cleanly as non-root user
        sudo -u "$TARGET_USER" env \
            HOME="$target_home" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            bash -c "curl -fsSL https://install.danklinux.com | sh" || log_warn "DMS script finished with notice."

        log_ok "DMS installation process finished."
    fi
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION FLOW
# ------------------------------------------------------------------------------
main() {
    log_info "Starting Automated Fedora Setup & Configuration..."

    # Step 0: VPN
    run_step_0_pvpn

    # Steps 1-3: AD Domain Join (Skip if running pure live setup without AD)
    if [[ "$AUTO_ACCEPT" -eq 1 ]]; then
        run_ad_join
    else
        read -rp "Proceed with Active Directory Join? [Y/n]: " join_choice
        if [[ "$join_choice" =~ ^[Yy]$ || -z "$join_choice" ]]; then
            run_ad_join
        fi
    fi

    # Step 4: DMS Setup
    run_dms_install

    log_ok "All setup tasks completed successfully!"
}

main "$@"
