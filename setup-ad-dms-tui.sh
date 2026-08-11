#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/setup-ad-dms"

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This installer must be run as root (use sudo)."
  exit 1
fi

# Build binary on the fly if missing
if [ ! -f "$BINARY_PATH" ]; then
  echo "Compiling Native Go TUI Engine..."
  if ! command -v go &> /dev/null; then
    dnf install -y golang > /dev/null
  fi
  (cd "${SCRIPT_DIR}/installer" && go build -o "${BINARY_PATH}" main.go)
fi

# Run compiled TUI installer
exec "$BINARY_PATH" "$@"