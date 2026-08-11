#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/JDKamalakar/fedora-ad-dms.git"

# If setup-ad-dms.sh is missing in current directory (e.g. running via curl pipe), clone repo
if [ ! -f "setup-ad-dms-tui.sh" ]; then
  TMP_DIR=$(mktemp -d)
  echo "⏬ Downloading fedora-ad-dms repository..."
  git clone --depth 1 "$REPO_URL" "$TMP_DIR"
  cd "$TMP_DIR"
fi

chmod +x setup-ad-dms.sh
exec ./setup-ad-dms.sh "$@"
