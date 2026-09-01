#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Automated Remote Task Engine (config/remote-tasks.sh)
# ==============================================================================
# This script is executed during policy refresh (via 'refresh' or background timer).
#
# QUICK SYNTAX:
#   target_exec "UNIQUE_TASK_ID" "HOSTNAME_PATTERN_OR_ALL" 'COMMAND_OR_HELPER'
#
# AVAILABLE BUILT-IN SIMPLE HELPERS:
#   1. delete_folder ".config/DankMaterialShell/plugins/protonVPN"
#      -> Deletes the specified path from ALL user home directories & root.
#
#   2. remove_software "protonvpn-gui" "com.protonvpn.www" "steam"
#      -> Uninstalls DNF RPMs, system flatpaks, and per-user flatpaks in 1 call.
#
#   3. delete_non_admin_users
#      -> Safely removes all cached lab users and wipes their home data,
#         preserving 'root', 'admin', 'wheel', and 'Domain Admins' accounts.
#
#   4. clean_user_homes "lab"
#      -> Wipes files in /home/<user> for users whose names contain "lab"
#
#   5. restart_services "sssd" "greetd"
#      -> Restarts specified systemd services cleanly.
# ==============================================================================


# ==============================================================================
# EXAMPLES & TEMPLATES (Uncomment any task below to activate it)
# ==============================================================================

# --- Example 1: Remove DMS protonVPN plugin & uninstall ProtonVPN on ALL computers
# target_exec "task_2026_09_01_purge_pvpn" "ALL" '
#   delete_folder ".config/DankMaterialShell/plugins/protonVPN"
#   remove_software "proton-vpn-gnome-desktop" "protonvpn-cli" "com.protonvpn.www"
# '

# --- Example 2: Wipe all non-admin user accounts across ALL LAB computers
# target_exec "task_2026_09_01_wipe_all_lab_users" "LAB" '
#   delete_non_admin_users
# '

# --- Example 3: Wipe all non-admin user accounts on a SPECIFIC LAB (OS Lab only)
# target_exec "task_2026_09_01_wipe_oslab_users" "GSFCUOSLAB" '
#   delete_non_admin_users
# '

# --- Example 4: Wipe temporary files across ALL machines
# target_exec "task_2026_09_01_clean_temp" "ALL" '
#   rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
# '

# --- Example 5: Restart SSSD and reload auth on AI Lab computers
# target_exec "task_2026_09_01_reload_sssd_ailab" "GSFCUAILAB" '
#   restart_services sssd
# '

# --- Example 6: Clean files for a specific student account on PL Lab
# target_exec "task_2026_09_01_clean_student_23" "GSFCUPLLAB" '
#   rm -rf /home/23bca032/* /home/23bca032/.[!.]* 2>/dev/null || true
# '
