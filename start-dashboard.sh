#!/usr/bin/env bash
# ==============================================================================
# AD-DMS Web Control Center Local Server Launcher
# ==============================================================================
set -euo pipefail

PORT="${1:-8080}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="${SCRIPT_DIR}/web"

echo -e "\033[1;36m======================================================================\033[0m"
echo -e "\033[1;36m       AD-DMS CONTROL CENTER | MATERIAL 3 EXPRESSIVE WEB DASHBOARD    \033[0m"
echo -e "\033[1;36m======================================================================\033[0m\n"
echo -e "  -> Serving UI locally from: \033[1;32m${WEB_DIR}\033[0m"
echo -e "  -> Open in your browser:    \033[1;32mhttp://localhost:${PORT}\033[0m"
echo -e "  -> Press \033[1;33mCtrl+C\033[0m to stop the server.\n"

if command -v python3 &>/dev/null; then
  exec python3 -m http.server "$PORT" --directory "$WEB_DIR"
else
  echo "[ERROR] Python 3 is required to serve the local dashboard."
  exit 1
fi
