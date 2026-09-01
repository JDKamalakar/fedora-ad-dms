#!/usr/bin/env bash
# Remote Task Engine
# Usage: target_exec "TASK_UNIQUE_ID" "HOSTNAME_PATTERN_OR_ALL" "COMMAND_TO_RUN"

# ==============================================================================
# EXAMPLE 1: Target ALL Lab Hosts (Matches any hostname containing "LAB")
# Cleans temp files & wipes home folders of local/cached users containing "LAB"
# ==============================================================================
# target_exec "task_2026_08_01_clean_all_labs" "LAB" '
#   echo "Running global lab cleanup on $(hostname)..."
  
#   # 1. Clear temp directories
#   rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

#   # 2. Find and clean user home folders containing "lab" (case-insensitive)
#   for user_dir in /home/*; do
#     dir_name=$(basename "$user_dir")
#     if echo "$dir_name" | grep -iq "lab"; then
#       echo "Cleaning lab user directory: $user_dir"
#       rm -rf "${user_dir:?}"/* "${user_dir:?}"/.* 2>/dev/null || true
#     fi
#   done
# '

# ==============================================================================
# EXAMPLE 2: Target a SINGLE Specific Lab (e.g., Operating Systems Lab ONLY)
# Runs maintenance exclusively on machines with "GSFCUOSLAB" in their hostname
# ==============================================================================
# target_exec "task_2026_08_02_clean_oslab_only" "GSFCUOSLAB" '
#   echo "Running OS Lab specific maintenance on $(hostname)..."
  
#   # Example: Clear greeter caches and reboot SSSD on OS Lab machines
#   rm -rf /var/cache/dms-greeter/*
#   systemctl restart sssd
# '

# ==============================================================================
# ACTIVE TASK: Remove protonVPN Plugin & Uninstall ProtonVPN across ALL Hosts
# ==============================================================================
target_exec "task_2026_09_01_purge_pvpn" "ALL" '
  echo "Executing ProtonVPN removal and plugin purge on $(hostname)..."

  # 1. Kill any active protonvpn processes
  pkill -f -9 protonvpn 2>/dev/null || true
  pkill -f -9 proton-vpn 2>/dev/null || true

  # 2. Remove DMS protonVPN plugin directory across ALL user home folders and root
  for user_dir in /home/* /root; do
    if [ -d "$user_dir/.config/DankMaterialShell/plugins/protonVPN" ]; then
      echo "  -> Removing plugin from: $user_dir/.config/DankMaterialShell/plugins/protonVPN"
      rm -rf "$user_dir/.config/DankMaterialShell/plugins/protonVPN"
    fi
  done

  # 3. Uninstall native ProtonVPN RPMs / DNF packages if present
  echo "  -> Purging native ProtonVPN DNF packages..."
  dnf remove -y proton-vpn-gnome-desktop protonvpn-cli protonvpn-gui "protonvpn*" 2>/dev/null || true

  # 4. Uninstall ProtonVPN Flatpaks if installed (system & user scopes)
  echo "  -> Purging ProtonVPN Flatpaks..."
  flatpak uninstall -y --system com.protonvpn.www 2>/dev/null || true
  for user_dir in /home/*; do
    username=$(basename "$user_dir")
    su - "$username" -c "flatpak uninstall -y --user com.protonvpn.www" 2>/dev/null || true
  done

  echo "  -> [SUCCESS] ProtonVPN packages and DMS plugin purged."
'
