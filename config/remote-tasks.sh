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

# Example 3: Clean data for a specific user on OS Lab machines
# target_exec "task_2026_08_01_clean_user" "GSFCUOSLAB" "rm -rf /home/23bca032/*"

# Example 4: Remove a bad user account entirely across ALL labs
# target_exec "task_2026_08_02_del_baduser" "ALL" "userdel -r baduser1 || true"

# Example 5: Enable or disable a system service on Hardware Lab
# target_exec "task_2026_08_03_hw_service" "GSFCUDSLAB" "systemctl disable --now bluetooth"
