<div align="center">

# 🛡️ Fedora Active Directory & DMS Automated Deployment System

**An enterprise-grade, automated provisioning engine that binds Fedora Linux workstations into Microsoft Active Directory, deploys Dank Material Shell (DMS) with custom desktop presets, and enforces real-time dynamic application governance.**

[![Platform](https://img.shields.io/badge/Platform-Fedora%20Linux%2040%2B-blue.svg?logo=fedora)](https://fedoraproject.org)
[![Active Directory](https://img.shields.io/badge/Domain-Active%20Directory%20SSSD-green.svg?logo=windows)](https://ubuntu.com)
[![Desktop](https://img.shields.io/badge/Shell-Dank%20Material%20Shell%20(Niri)-purple.svg)](https://github.com/Avenge-Media/dms)
[![Design](https://img.shields.io/badge/Design-Material%203%20Expressive-blueviolet.svg)](https://m3.material.io)
[![License](https://img.shields.io/badge/License-MIT-orange.svg)](#)

---

### ⚡ Quick Deployment (One-Liner)

To deploy or provision any Fedora workstation, run the bootstrapper script:

```bash
curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/install.sh?$(date +%s)" | sudo bash
```

</div>

---

## 📑 Table of Contents
- [📖 Overview & Architecture](#-overview--architecture)
- [✨ Key Features](#-key-features)
- [📟 Interactive Remote & Monitoring TUI (`remote`)](#-interactive-remote--monitoring-tui-remote)
- [💓 Heartbeat Telemetry & Client Verification (`heartbeat`)](#-heartbeat-telemetry--client-verification-heartbeat)
- [🧩 Configuration & Governance Structure](#-configuration--governance-structure)
- [🚀 User Installation Engine (`install`)](#-user-installation-engine-install)
- [🔄 Automated Policy Synchronization (`refresh`)](#-automated-policy-synchronization-refresh)
- [💡 Hardware & Device Governance (100% Brightness & Volume)](#-hardware--device-governance-100-brightness--volume)
- [🚨 Infraction Tracker & Siren Alarm](#-infraction-tracker--siren-alarm)
- [🛡️ Security, Polkit & Domain Admin Access](#-security-polkit--domain-admin-access)
- [🛠️ Workflow Breakdown](#️-workflow-breakdown)
- [🎨 DMS Desktop Integration & Power Menu](#-dms-desktop-integration--power-menu)

---

## 📖 Overview & Architecture

**AD-DMS** transforms standard Fedora desktop installations into centrally managed, academic-grade lab environments:
* **Directory Integration**: Automated realm enrollment, Kerberos configuration, SSSD caching, and PAM auto-homedir provisioning (`pam_mkhomedir`).
* **Desktop Environment**: Deploys **Dank Material Shell (DMS)** with Wayland tile compositing (Niri), Greetd login manager, and preconfigured institutional desktop presets.
* **Granular Application Policy Engine**: Enforces three-tier application rules (Compulsory, Allowed, Blocked) across both native DNF packages and user-level Flatpaks.
* **Active Guard Daemons**: Continuously scans for blacklisted software, uninstalls unauthorized applications in real-time, logs user violations, and triggers audible siren alerts on repeated infractions.
* **Terminal Control Center (TUI)**: Fast, keyboard-driven management interface inspired by pVPN for real-time monitoring, instant screenshots, remote commands, and configuration editing.

---

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| **🌐 Intranet Primary Server** | Headless API & Telemetry Daemon (`ad-dms-server.service`) on host (`GSFCUPLLAB203` / `10.205.18.253`) for instant updates and client tracking. |
| **📟 Interactive 'remote' TUI** | Go-powered terminal interface with collapsible lab groups, live telemetry, instant screen capture, and safe file edits. |
| **💓 Workstation Heartbeat CLI** | `heartbeat` command & background timer sending real-time workstation status, IP, logged user, and DMS session info. |
| **📸 Instant Screen Capture** | Grabs client screenshot over intranet via DMS/Wayland or Plasma (`dms screenshot full ...` / `spectacle`). |
| **💾 20-Backup Retention Engine** | Automatically creates backups on edit (max 20 over 7 days, retains last 3 if older than 15 days). |
| **🚀 Automated Bootstrapper** | One-line installer automatically detects if device is intranet host and provisions domain/host daemons accordingly. |
| **🏢 Zero-Touch AD Join** | Configures NetworkManager DNS, Kerberos (`krb5.conf`), and SSSD for institutional domains (`gsfcu.local`). |
| **🎨 DMS Presets & Custom Themes** | Auto-unpacks and configures Dank Material Shell, Niri, Kitty terminal, and custom desktop sessions. |
| **⚡ Universal User `install` CLI** | Replaces raw package managers with a policy-aware CLI (`install <pkg>` & `install flatpak <id>`). |
| **🚫 Dynamic Game & Blacklist Blocker** | Automatically resolves and blacklists the entire DNF `games` group and Flatpak AppStream gaming categories. |
| **🛡️ GUI App Store Guard** | Systemd background daemon actively terminates and uninstalls blocked apps installed via GNOME Software or KDE Discover. |
| **🔊 Siren Alarm & Volume Lock** | Plays `Siren.mp3` at **100% Volume** when user policy violations exceed 3 infractions. |
| **💡 Hardware Governance** | Background timer forces **100% Brightness** and **100% Sound** every 5 minutes (`device-rules.conf`). |
| **📊 User Infraction Tracker** | Secure per-user tracking via `violation <user> --get` and `violation <user> --set <n>`. |
| **🔄 Self-Updating Policy Engine** | Running `refresh` updates rules, timer intervals, and remote tasks directly from host/GitHub. |
| **🔑 Domain Admin Polkit Auth** | Allows AD `Domain Admins` to authenticate against GUI elevation dialogs alongside local `wheel` admins. |

---

## 📟 Interactive Remote & Monitoring TUI (`remote`)

The repository includes a dedicated Go terminal utility inspired by modern TUI designs:

```bash
# Launch the Interactive Monitoring & Governance TUI
remote
# or directly run from repo:
./remote
```

### Key Capabilities & Keyboard Controls:
* **📊 Workstation Telemetry & Lab Matrix**:
  * **Filter Toolbar**: Switch filters using `Tab`, `Shift+Tab`, `F`, or `←`/`→` when focused on the filter bar (`All Devices`, `Online Only`, `Offline Only`).
  * **Active Selection Highlighting**: When navigating down to table entries, the active row is highlighted with a prominent full-row green accent bar. The filter bar retains clean indicator arrows (`► All Devices ◄`) without distracting background colors.
  * **Collapsible Lab Groups**: Lab headers display state toggles (`▼` Expanded, `▶` Collapsed). Press `Enter` or `Space` on any lab header row to fold/unfold that lab's devices.
  * **1-Based Indexing & Quick-Select**: Device entries are numbered sequentially starting from `1`. Press keys `1-9` on your keyboard to instantly select a device and trigger remote actions.
  * **Live Refresh**: Press `r` at any time to instantly poll active workstation states.
* **📸 Instant Screen Capture**:
  * Select any target workstation to take a screenshot of the user's active session (`dms screenshot full --no-notify --no-clipboard --no-file` on Wayland/Niri or `spectacle` on Plasma) and preview/save it on the administrator terminal.
* **📝 Safe Configuration Editor with Automated Backups**:
  * Safely edit `domain.conf`, `blocked-apps.conf`, `allowed-apps.conf`, `compulsory-apps.conf`, `group-apps.conf`, `device-rules.conf`, and `remote-tasks.sh`.
  * **Backup Retention Rule**: Automatically preserves up to 20 backups over 7 days in `~/.ad-dms-backups/` and prunes older versions (retaining 3 backups if $>15$ days).
  * Validates script syntax on save.
* **⚡ Targeted Remote Command Execution**:
  * Dispatch commands to single machines, entire lab groups, or all workstations.
* **📜 Real-Time Audit & History Viewer**:
  * Switch to History View (`Tab` or menu) to inspect client enrollment records and user session logins with 1-based indexed tables.

---

## 💓 Heartbeat Telemetry & Client Verification (`heartbeat`)

Each workstation runs an automated background heartbeat service (`ad-dms-heartbeat.timer`) that checks in with the intranet host every 2 minutes.

### Checking Heartbeat Status:
Administrators and users can inspect heartbeat configuration, timer countdown, and connectivity at any time:

```bash
heartbeat
```

*Sample Output:*
```text
======================================================================
                  AD-DMS WORKSTATION HEARTBEAT STATUS
======================================================================
  [DAEMON SERVICE]      Active: active (running) since Thu 2026-09-03 08:30:00 IST
  [HEARTBEAT TIMER]     Active: active (waiting)
  [LAST HEARTBEAT TIME] Thu 2026-09-03 10:45:12 IST (12s ago)
  [NEXT HEARTBEAT TIME] Thu 2026-09-03 10:47:00 IST (in 1min 48s)
  [HEARTBEAT INTERVAL]  Every 2 minutes
----------------------------------------------------------------------
  [CENTRAL HOST URL]    http://GSFCUPLLAB203:8080/api/heartbeat
  [HOST REACHABILITY]   ● CONNECTED (HTTP 200 OK - Heartbeat registered)
  [WORKSTATION INFO]    Host: GSFCUOSLAB101 | IP: 10.205.18.101 | User: student01
======================================================================
```

To send an immediate one-shot heartbeat ping:
```bash
heartbeat --now
# or
heartbeat --send
```

---

## 🌐 Intranet Primary Server Daemon (`ad-dms-server.service`)

The primary host machine (e.g. `GSFCUPLLAB203`) runs a lightweight, headless Python daemon (`web_server.py`) serving as the central REST API and configuration mirror:
* **Endpoints**:
  * `/api/heartbeat`: Ingestion endpoint for client telemetry, IP address, logged-in user, and active sessions.
  * `/api/clients`: Real-time JSON data consumed by the Go TUI (`remote`).
  * `/api/command/*`: Command queue for remote execution and screenshot capture.
  * `/config/*` & `/presets/*`: Local distribution mirror for configs, shell scripts, and DMS presets.
* **Service Management**:
  ```bash
  sudo systemctl status ad-dms-server.service
  sudo systemctl restart ad-dms-server.service
  ```

---

## 🧩 Configuration & Governance Structure

All policy engine rules are managed under `/etc/ad-dms/` (synced from the repository's `config/` directory):

```text
/etc/ad-dms/
├── domain.conf                 # Master domain, pVPN, timezone & notification settings
├── lab.conf                    # Lab profile definitions & hostname prefixes
├── compulsory-apps.conf        # Mandatory applications enforced on all nodes
├── allowed-apps.conf           # Pre-approved whitelist (passwordless install)
├── blocked-apps.conf           # Explicitly blacklisted packages & AppStream IDs
├── group-apps.conf             # Hostname / Lab-specific software packages
├── device-rules.conf           # Hardware governance rules (brightness & volume)
├── refresh-app-policies.sh     # Core policy enforcement and daemon manager
├── remote-tasks.sh             # Administrator remote maintenance task scripts
└── assets/Siren.mp3            # High-volume security siren audio asset
```

### 1. `domain.conf`
Master parameters for Active Directory domain, automated VPN setup, timezones, and alert messages:
```ini
ENABLE_PVPN="yes"
DOMAIN_NAME="gsfcu.local"
REALM_NAME="GSFCU.LOCAL"
AD_DNS_IP="10.205.4.177"
ALLOW_SHORT_USERNAMES="yes"
REFRESH_INTERVAL="1h"
SYSTEM_TIMEZONE="Asia/Kolkata"

BLOCK_NOTIFICATION_TITLE="Unauthorized Application Blocked"
BLOCK_NOTIFICATION_MSG="Access Denied: This application is blacklisted under University IT Policy."
ACADEMIC_WARNING_MSG="WARNING: This software is not pre-approved. If found non-academic, strict action will be initiated."
```

### 2. `blocked-apps.conf`
Lists packages and Flatpaks to exclude and immediately remove:
```ini
# Native DNF / RPM Packages (Supports globs)
*steam*
*game*
lutris
playonlinux
minetest

# --- FLATPAK PACKAGES ---
com.valvesoftware.Steam
net.lutris.Lutris
com.heroicgameslauncher.hgl
org.DolphinEmu.dolphin-emu
org.PPSSPP.PPSSPP
```

### 3. `device-rules.conf`
Enforces hardware settings across workstations:
```ini
# Lock system display brightness to 100% (yes / no)
LOCK_BRIGHTNESS_100="yes"

# Lock system audio / master volume to 100% (yes / no)
LOCK_VOLUME_100="yes"

# Re-enforcement check interval
DEVICE_CHECK_INTERVAL="5m"
```

---

## 🚀 User Installation Engine (`install`)

Standard users install software through the managed **`install`** utility:

```bash
# Install a native DNF/RPM package
install <package_name>

# Install a user-level Flatpak
install flatpak <appstream_id>
```

```text
╔══════════════════════════════════════════════════════════════════════════╗
║   AD-DMS APPLICATION INSTALLER                                           ║
╚══════════════════════════════════════════════════════════════════════════╝
```

### Decision & Security Matrix:
* **Blocked Packages (`blocked-apps.conf` + Auto-discovered games)**:
  * ❌ Immediately denied and terminated.
  * 🔔 Critical desktop notification with human-readable application name (e.g. *Heroic Games Launcher*).
  * 📝 Increments security violation count (`/var/log/ad-dms-violations/<user>.count`).
  * 🔊 Triggers high-volume `Siren.mp3` if infractions $>3$.
* **Allowed / Compulsory Packages (`allowed-apps.conf` & `compulsory-apps.conf`)**:
  * ✅ Installed passwordlessly without requiring administrative credentials.
* **Unapproved Packages**:
  * ⚠️ Displays institutional academic warning.
  * ❓ Prompts user to confirm academic necessity (`[y/N]`).
  * 🔑 Demands administrative authentication.
* **Administrative Accounts (`root`, `wheel`, `Domain Admins`)**:
  * ⚡ Automatically bypasses restriction checks and installs directly.

---

## 🔄 Automated Policy Synchronization (`refresh`)

Workstations stay updated with GitHub repository configuration changes automatically.

### Running Manual Policy Refresh
Users and administrators can run:
```bash
refresh
```
* Automatically self-elevates to root without password prompts.
* Downloads the latest rules and scripts from GitHub (`refresh-app-policies.sh`, `domain.conf`, `device-rules.conf`, `Siren.mp3`, etc.).
* Synchronizes DNF exclusions, Flatpak allowances, lab group apps, timer intervals, and runs pending `remote-tasks.sh`.

### Checking Timer Countdown
To inspect when the next automated sync is scheduled:
```bash
refresh -t
# or
refresh --time
```
*Output:*
```text
[AD-DMS TIMER] Next policy refresh scheduled in: 28min (Next run: Thu 2026-08-27 15:00:00)
```

### Inspecting Previous Sync Source & Live Host Ping Status
To check which upstream source (`Intranet Host`, `Intranet IP`, or `GitHub Cloud CDN`) was previously used and test live ICMP ping & HTTP reachability against the main host device configured in `domain.conf`:
```bash
refresh -s
# or
refresh --source
# or
refresh -p
# or
refresh --ping
```
*Output:*
```text
╔══════════════════════════════════════════════════════════════════════════╗
║                  AD-DMS POLICY SOURCE & HOST PROBE STATUS                ║
╚══════════════════════════════════════════════════════════════════════════╝
  [PREVIOUS SYNC SOURCE] Intranet Host (GSFCUPLLAB203:8080) - Synced at Thu Sep 3 08:50:12 IST 2026

  [MAIN HOST DEVICE TARGET] GSFCUPLLAB203 (Fallback IP: 10.205.18.253, Port: 8080)

  [ICMP PING PROBE] Pinging main host device...
    -> ● ICMP PING SUCCESSFUL (Host 'GSFCUPLLAB203' replied to ping)

  [HTTP SERVICE PROBE] Testing reachable upstream service...
    -> ● INTRANET HOST ONLINE (Connected via GSFCUPLLAB203:8080)
```

---

## 💡 Hardware & Device Governance (100% Brightness & Volume)

The `ad-dms-device-guard.timer` runs every 5 minutes to ensure:
* **Brightness is locked at 100%**: Automatically adjusts sysfs backlight, `brightnessctl`, and `ddcutil`.
* **Sound Volume is locked at 100% & Unmuted**: Restores master volume through PipeWire (`wpctl`), PulseAudio (`pactl`), and ALSA (`amixer`).

---

## 🚨 Infraction Tracker & Siren Alarm

Policy infractions are tracked per user under `/var/log/ad-dms-violations/`:

```bash
# Query a user's infraction count
violation oslab --get

# Reset or modify a user's count (Admin only)
violation oslab --set 0
```

When a user triggers **more than 3 violations**, any subsequent infraction automatically turns the volume to 100% and blares `Siren.mp3`.

---

## 🛡️ Security, Polkit & Domain Admin Access

### 1. Polkit Domain Admin Elevation (`10-ad-admin-auth.rules`)
Polkit is configured to allow Active Directory administrators to authenticate GUI elevation dialogs:
```javascript
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:wheel", "unix-group:Domain Admins", "unix-group:domain admins", "unix-user:root"];
});
```

### 2. User-Level Flatpak Sandboxing (`45-ad-dms-flatpak-allowlist.rules`)
Users can manage user-scope Flatpaks without root credentials, while the systemd background daemon (`ad-dms-gui-scan.timer`) actively guards against unauthorized or game Flatpaks every 2 minutes across all user homes.

---

## 🛠️ Workflow Breakdown

```text
  [Phase 0]  Set System Timezone (Asia/Kolkata) & Optional ProtonVPN (pVPN) Setup
     ↓
  [Step 1]   Software Swapping (Removes LibreOffice -> Installs ONLYOFFICE)
     ↓
  [Step 2]   Hostname & Lab Identity Configuration (Interactive or Auto)
     ↓
  [Step 3]   AD Dependencies, Policy Engine Deployment & Background Timers
     ↓
  [Step 4]   Dank Material Shell (DMS), Niri & Desktop Presets Deployment
     ↓
  [Step 5]   Active Directory Realm Join, Kerberos & SSSD Integration
     ↓
  [Step 6]   DMS Greetd Display Manager Configuration & Session Caches
     ↓
  [Step 7]   Passwordless Management Rules & Authentication Services Restart
```

---

## 🎨 DMS Desktop Integration & Power Menu

This system pairs seamlessly with custom DMS widgets and extensions, including the fullscreen power overlay:
* **[DMS Fullscreen Power Menu](https://github.com/JDKamalakar/DMS-Fullscreen_Power_Menu)**: An aesthetic Wayland fullscreen power and session control interface for Dank Material Shell.

---

<div align="center">
  <sub>Maintained for university lab management and automated workstation governance.</sub>
</div>
