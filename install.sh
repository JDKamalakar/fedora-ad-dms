#!/usr/bin/env bash
set -euo pipefail

GITHUB_USER="jayrajkamalakar-gsfcu"
REPO_NAME="fedora-ad-dms"
TMP_DIR="/tmp/${REPO_NAME}"

echo "=================================================="
echo " Preparing Fedora AD & DMS Setup Package"
echo "=================================================="

if ! command -v git &> /dev/null; then
  echo "Installing Git..."
  sudo dnf install -y git
fi

rm -rf "$TMP_DIR"
echo "Fetching setup package from GitHub..."
git clone "https://github.${GITHUB_USER}/${REPO_NAME}.git" "$TMP_DIR" 2>/dev/null || \
git clone "https://github.com/${GITHUB_USER}/${REPO_NAME}.git" "$TMP_DIR"

cd "$TMP_DIR"
chmod +x setup-ad-dms-tui.sh
sudo ./setup-ad-dms-tui.sh
