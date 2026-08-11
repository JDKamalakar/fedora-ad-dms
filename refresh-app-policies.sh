#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/jayrajkamalakar-gsfcu/fedora-ad-dms/main"
SECURE_DIR="/etc/app-policies"
STATE_DIR="/var/lib/app-policies"
COMPLETED_TASKS_FILE="${STATE_DIR}/completed_tasks.log"
TIMESTAMP_DIR="/var/lib/dms-policy"
LAST_SYNC_FILE="${TIMESTAMP_DIR}/last_sync"

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

mkdir -p "$SECURE_DIR" "$STATE_DIR"
chmod 700 "$SECURE_DIR" "$STATE_DIR"
touch "$COMPLETED_TASKS_FILE"

CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || echo "$HOSTNAME")"
HOST_UPPER="$(echo "$CURRENT_HOSTNAME" | tr '[:lower:]' '[:upper:]')"

echo "[POLICY SYNC] Fetching latest software policies..."

# Pull all remote configs
curl -fsSL "${REPO_RAW_URL}/allowed-apps.conf" -o "${SECURE_DIR}/allowed-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/blocked-apps.conf" -o "${SECURE_DIR}/blocked-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/compulsory-apps.conf" -o "${SECURE_DIR}/compulsory-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/group-apps.conf" -o "${SECURE_DIR}/group-apps.conf" || true
curl -fsSL "${REPO_RAW_URL}/remote-tasks.sh" -o "${SECURE_DIR}/remote-tasks.sh" || true

chmod 600 ${SECURE_DIR}/* 2>/dev/null || true

# --- 1. Apply Passwordless DNF Allowlist ---
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

# --- 2. Apply Blocked Packages & Flatpaks ---
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

# --- 3. Install Global Compulsory Apps ---
if [ -f "${SECURE_DIR}/compulsory-apps.conf" ]; then
  mapfile -t COMPULSORY_PKGS < <(grep -v '^[[:space:]]*#' "${SECURE_DIR}/compulsory-apps.conf" | grep -v '^[[:space:]]*$')
  if [ "${#COMPULSORY_PKGS[@]}" -gt 0 ]; then
    dnf install -y --setopt=lock_timeout=10 "${COMPULSORY_PKGS[@]}" || true
  fi
fi

# --- 4. Install Lab-Targeted Group Apps (group-apps.conf) ---
if [ -f "${SECURE_DIR}/group-apps.conf" ]; then
  while IFS=':' read -r pattern pkgs || [ -n "$pattern" ]; do
    [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pattern" ]] && continue
    
    pattern_upper="$(echo "$pattern" | xargs | tr '[:lower:]' '[:upper:]')"
    pkgs_clean="$(echo "$pkgs" | xargs)"

    if [[ "$HOST_UPPER" == *"$pattern_upper"* ]] && [ -n "$pkgs_clean" ]; then
      echo "[POLICY SYNC] Hostname '${CURRENT_HOSTNAME}' matches target group '${pattern_upper}'. Installing: ${pkgs_clean}"
      # shellcheck disable=SC2086
      dnf install -y --setopt=lock_timeout=10 $pkgs_clean || true
    fi
  done < "${SECURE_DIR}/group-apps.conf"
fi

# --- 5. Execute Remote Commands (remote-tasks.sh) ---
target_exec() {
  local task_id="$1"
  local target_pattern="$2"
  local cmd="$3"
  
  target_upper="$(echo "$target_pattern" | tr '[:lower:]' '[:upper:]')"

  # Skip if already executed on this machine
  if grep -q "^${task_id}$" "$COMPLETED_TASKS_FILE"; then
    return 0
  fi

  # Execute if targeted or ALL
  if [ "$target_upper" = "ALL" ] || [[ "$HOST_UPPER" == *"$target_upper"* ]]; then
    echo "[REMOTE TASK] Running Task '${task_id}' on ${CURRENT_HOSTNAME}..."
    if eval "$cmd"; then
      echo "$task_id" >> "$COMPLETED_TASKS_FILE"
      echo "[REMOTE TASK] Task '${task_id}' completed successfully."
    else
      echo "[REMOTE TASK] Task '${task_id}' failed during execution."
    fi
  fi
}

export -f target_exec
export HOST_UPPER CURRENT_HOSTNAME COMPLETED_TASKS_FILE

if [ -f "${SECURE_DIR}/remote-tasks.sh" ]; then
  bash "${SECURE_DIR}/remote-tasks.sh" || true
fi

# --- 6. Record Tamper-Proof Last Sync Timestamp ---
mkdir -p "$TIMESTAMP_DIR"
chmod 755 "$TIMESTAMP_DIR"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_SYNC_FILE"
chmod 644 "$LAST_SYNC_FILE"

echo "[POLICY SYNC] Timestamp logged to ${LAST_SYNC_FILE}."
echo "[POLICY SYNC] Sync completed successfully."