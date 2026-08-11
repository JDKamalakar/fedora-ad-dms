#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/jayrajkamalakar-gsfcu/fedora-ad-dms/main"
SECURE_DIR="/etc/app-policies"

# Ensure root execution
if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

mkdir -p "$SECURE_DIR"
chmod 700 "$SECURE_DIR"

echo "[POLICY SYNC] Fetching latest software policies..."

# Securely pull policy files
curl -fsSL "${REPO_RAW_URL}/allowed-apps.conf" -o "${SECURE_DIR}/allowed-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/blocked-apps.conf" -o "${SECURE_DIR}/blocked-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/compulsory-apps.conf" -o "${SECURE_DIR}/compulsory-apps.conf" || true

chmod 600 ${SECURE_DIR}/*.conf

# 1. Apply Passwordless DNF Allowlist
if [ -f "${SECURE_DIR}/allowed-apps.conf" ]; then
  cat <<'PK' > /etc/polkit-1/rules.d/10-passwordless-apps.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.packagekit.package-install" ||
         action.id == "org.baseurl.DnfSystem.install") &&
        subject.isInGroup("domain users")) {
        return polkit.Result.YES;
    }
});
PK
fi

# 2. Apply Blocked DNF Packages & Flatpaks
if [ -f "${SECURE_DIR}/blocked-apps.conf" ]; then
  # shellcheck disable=SC1090
  source "${SECURE_DIR}/blocked-apps.conf"
  
  if [ -n "${DNF_EXCLUDE:-}" ]; then
    sed -i '/^exclude=/d' /etc/dnf/dnf.conf
    echo "exclude=${DNF_EXCLUDE}" >> /etc/dnf/dnf.conf
  fi

  cat <<'PK' > /etc/polkit-1/rules.d/20-block-flatpaks.rules
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.Flatpak") === 0 && !subject.isInGroup("wheel")) {
        return polkit.Result.NO;
    }
});
PK
fi

# 3. Auto-Install Compulsory Apps
if [ -f "${SECURE_DIR}/compulsory-apps.conf" ]; then
  echo "[POLICY SYNC] Checking for missing compulsory applications..."
  mapfile -t COMPULSORY_PKGS < <(grep -v '^[[:space:]]*#' "${SECURE_DIR}/compulsory-apps.conf" | grep -v '^[[:space:]]*$')
  
  if [ "${#COMPULSORY_PKGS[@]}" -gt 0 ]; then
    dnf install -y "${COMPULSORY_PKGS[@]}" || echo "[POLICY SYNC] Warning: Some compulsory packages failed to install."
  fi
fi

echo "[POLICY SYNC] Software policies and compulsory apps updated successfully."
