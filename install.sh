#!/usr/bin/env bash
set -euo pipefail

TARBALL_URL="https://github.com/jayrajkamalakar-gsfcu/fedora-ad-dms/archive/refs/heads/main.tar.gz"

if [ ! -f "fedora-ad-dms-tui.sh" ]; then
  TMP_DIR=$(mktemp -d)
  echo "⏬ Downloading fedora-ad-dms repository..."
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
  cd "$TMP_DIR"
fi

chmod +x fedora-ad-dms-tui.sh

if [ ! -t 0 ] && [ -e /dev/tty ]; then
  exec ./fedora-ad-dms-tui.sh "$@" < /dev/tty
else
  exec ./fedora-ad-dms-tui.sh "$@"
fi