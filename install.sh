#!/usr/bin/env bash
set -euo pipefail

TARBALL_URL="https://github.com/jayrajkamalakar-gsfcu/fedora-ad-dms/archive/refs/heads/main.tar.gz"

# Find local script if it exists
SCRIPT_NAME=""
for name in setup-ad-dms-tui.sh fedora-ad-dms-tui.sh setup-ad-dms.sh; do
  if [ -f "$name" ]; then
    SCRIPT_NAME="$name"
    break
  fi
done

# If not found locally, download repo archive
if [ -z "$SCRIPT_NAME" ]; then
  TMP_DIR=$(mktemp -d)
  echo "⏬ Downloading fedora-ad-dms repository..."
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
  cd "$TMP_DIR"
  
  for name in setup-ad-dms-tui.sh fedora-ad-dms-tui.sh setup-ad-dms.sh; do
    if [ -f "$name" ]; then
      SCRIPT_NAME="$name"
      break
    fi
  done
fi

if [ -z "$SCRIPT_NAME" ]; then
  echo "❌ Error: Could not locate setup script in repository."
  exit 1
fi

chmod +x "$SCRIPT_NAME"

if [ ! -t 0 ] && [ -e /dev/tty ]; then
  exec ./"$SCRIPT_NAME" "$@" < /dev/tty
else
  exec ./"$SCRIPT_NAME" "$@"
fi