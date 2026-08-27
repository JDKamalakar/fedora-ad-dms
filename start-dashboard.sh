#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Control Center Launcher
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/web_server.py"
