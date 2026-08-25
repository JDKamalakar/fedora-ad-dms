#!/usr/bin/env bash
# ==============================================================================
# Application Policy Enforcement Engine
# Script: refresh-app-policies.sh
# ==============================================================================
set -euo pipefail

CONF_DIR="/etc/ad-dms"
mkdir -p "$CONF_DIR"

# 1. Install compulsory applications
if [ -f "$CONF_DIR/compulsory-apps.conf" ]; then
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | xargs)
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    if ! rpm -q "$app" &>/dev/null; then
      echo "[POLICY] Installing compulsory package: $app"
      dnf install -y "$app" || true
    fi
  done < "$CONF_DIR/compulsory-apps.conf"
fi

# 2. Terminate blocked processes
if [ -f "$CONF_DIR/blocked-apps.conf" ]; then
  while IFS= read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | xargs)
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    if pgrep -x "$app" &>/dev/null; then
      echo "[POLICY] Terminating restricted application process: $app"
      pkill -9 -x "$app" || true
    fi
  done < "$CONF_DIR/blocked-apps.conf"
fi
