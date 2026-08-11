#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/setup-ad-dms"
SRC_PATH="${SCRIPT_DIR}/installer/main.go"

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This installer must be run as root (use sudo)."
  exit 1
fi

# Build binary if missing or updated
if [ ! -f "$BINARY_PATH" ] || [ "$SRC_PATH" -nt "$BINARY_PATH" ]; then
  echo "Compiling Native Go Engine..."
  if ! command -v go &> /dev/null; then
    dnf install -y golang > /dev/null
  fi
  (cd "${SCRIPT_DIR}/installer" && go build -o "${BINARY_PATH}" main.go)
fi

# Run compiled installer
exec "$BINARY_PATH" "$@"