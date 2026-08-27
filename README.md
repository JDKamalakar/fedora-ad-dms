<div align="center">

# 🛡️ Fedora Active Directory & DMS Automated Deployment System

**An enterprise-grade, automated provisioning engine that binds Fedora Linux workstations into Microsoft Active Directory, deploys Dank Material Shell (DMS) with custom desktop presets, and enforces real-time dynamic application governance.**

[![Platform](https://img.shields.io/badge/Platform-Fedora%20Linux%2040%2B-blue.svg?logo=fedora)](https://fedoraproject.org)
[![Active Directory](https://img.shields.io/badge/Domain-Active%20Directory%20SSSD-green.svg?logo=windows)](https://ubuntu.com)
[![Desktop](https://img.shields.io/badge/Shell-Dank%20Material%20Shell%20(Niri)-purple.svg)](https://github.com/Avenge-Media/dms)
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
- [🧩 Configuration & Governance Structure](#-configuration--governance-structure)
- [🚀 User Installation Engine (`install`)](#-user-installation-engine-install)
- [🔄 Automated Policy Synchronization (`refresh`)](#-automated-policy-synchronization-refresh)
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

---

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| **🚀 Automated Bootstrapper** | Downloads and provisions domain configs, scripts, presets, and dependencies via a single command. |
| **🏢 Zero-Touch AD Join** | Configures NetworkManager DNS, Kerberos (`krb5.conf`), and SSSD for institutional domains (`gsfcu.local`). |
| **🎨 DMS Presets & Custom Themes** | Auto-unpacks and configures Dank Material Shell, Niri, Kitty terminal, and custom desktop sessions. |
| **⚡ Universal User `install` CLI** | Replaces raw package managers with a policy-aware CLI (`install <pkg>` & `install flatpak <id>`). |
| **🚫 Dynamic Game & Blacklist Blocker** | Automatically resolves and blacklists the entire DNF `games` group and Flatpak AppStream gaming categories. |
| **🛡️ GUI App Store Guard** | Systemd background daemon actively terminates and uninstalls blocked apps installed via GNOME Software or KDE Discover. |
| **🚨 Violation Tracker & Siren Alarm** | Tracks policy infractions per user in `/var/log/ad-dms-violations/` and sounds an audible alarm if $>3$ violations occur. |
| **🔄 Self-Updating Policy Engine** | Running `refresh` or periodic systemd timers synchronizes rules and remote tasks directly from GitHub. |
| **🔑 Domain Admin Polkit Auth** | Allows AD `Domain Admins` to authenticate against GUI elevation dialogs alongside local `wheel` admins. |

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
├── refresh-app-policies.sh     # Core policy enforcement and daemon manager
└── remote-tasks.sh             # Administrator remote maintenance task scripts
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

---

## 🚀 User Installation Engine (`install`)

Standard users install software through the managed **`install`** utility:

```bash
# Install a native DNF/RPM package
install <package_name>

# Install a user-level Flatpak
install flatpak <appstream_id>
```

```
╔══════════════════════════════════════════════════════════════════════════╗
║   AD-DMS APPLICATION INSTALLER                                           ║
╚══════════════════════════════════════════════════════════════════════════╝
```

### Decision & Security Matrix:
* **Blocked Packages (`blocked-apps.conf` + Auto-discovered games)**:
  * ❌ Immediately denied.
  * 🔔 Critical desktop notification with human-readable application name (e.g. *Heroic Games Launcher*).
  * 📝 Increments security violation count (`/var/log/ad-dms-violations/<user>.count`).
  * 🔊 Triggers audible siren alarm if user has $>3$ violations.
* **Allowed / Compulsory Packages (`allowed-apps.conf` & `compulsory-apps.conf`)**:
  * ✅ Installed passwordlessly without requiring administrative credentials.
* **Unapproved Packages**:
  * ⚠️ Displays institutional academic warning.
  * ❓ Prompts user to confirm academic necessity (`[y/N]`).
  * 🔑 Demands administrative authentication.

---

## 🔄 Automated Policy Synchronization (`refresh`)

Workstations stay updated with GitHub repository configuration changes automatically.

### Running Manual Policy Refresh
Users and administrators can run:
```bash
refresh
```
* Automatically self-elevates to root without password prompts.
* Downloads the latest rules and scripts from GitHub.
* Synchronizes DNF exclusions, Flatpak allowances, lab group apps, and runs pending `remote-tasks.sh`.

### Checking Timer Countdown
To inspect when the next automated sync is scheduled:
```bash
refresh --t
# or
refresh -t
```
*Output:*
```text
[AD-DMS TIMER] Next policy refresh scheduled in: 28min (Next run: Thu 2026-08-27 15:00:00)
```

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
Users can manage user-scope Flatpaks without root credentials, while the systemd background daemon (`ad-dms-gui-scan.timer`) actively guards against unauthorized or game Flatpaks every 2 minutes.

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
