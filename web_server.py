#!/usr/bin/env python3
"""
AD-DMS Intranet Host Server & Monitoring Backend
- Serves repository configs, scripts, and preset archives over intranet HTTP.
- Provides Heartbeat Telemetry & Auto-Registration (/api/heartbeat, /api/register-install).
- Manages Remote Commands & Instant Screen Capture queue (/api/command/poll, /api/screenshot/upload).
- Powers the Material 3 Web Control Center & CLI TUI backend.
"""

import http.server
import json
import os
import subprocess
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

PORT = 8080
REPO_DIR = Path(__file__).resolve().parent
CONFIG_DIR = REPO_DIR / "config"
WEB_DIR = REPO_DIR / "web"
LOGS_DIR = REPO_DIR / "data"
LOGS_DIR.mkdir(exist_ok=True)

CLIENTS_FILE = LOGS_DIR / "clients.json"
COMMANDS_FILE = LOGS_DIR / "pending_commands.json"
AUDIT_LOG_FILE = LOGS_DIR / "audit_log.json"
SCREENSHOTS_DIR = LOGS_DIR / "screenshots"
SCREENSHOTS_DIR.mkdir(exist_ok=True)

def load_audit_log():
    if AUDIT_LOG_FILE.exists():
        try:
            return json.loads(AUDIT_LOG_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {"user_sessions": [], "installed_apps": {}}
    return {"user_sessions": [], "installed_apps": {}}

def save_audit_log(data):
    AUDIT_LOG_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")

def load_clients():
    if CLIENTS_FILE.exists():
        try:
            return json.loads(CLIENTS_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}

def save_clients(data):
    CLIENTS_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")

def load_commands():
    if COMMANDS_FILE.exists():
        try:
            return json.loads(COMMANDS_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}

def save_commands(data):
    COMMANDS_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")

def parse_split_conf(file_path):
    dnf_list = []
    flatpak_list = []
    mode = "dnf"
    if not file_path.exists():
        return {"dnf": dnf_list, "flatpak": flatpak_list}
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if "--- FLATPAK PACKAGES ---" in line or "# --- FLATPAK" in line:
                mode = "flatpak"
                continue
            if not line or line.startswith("#") or "=" in line:
                continue
            if mode == "dnf":
                dnf_list.append(line)
            else:
                flatpak_list.append(line)
    return {"dnf": dnf_list, "flatpak": flatpak_list}

def save_split_conf(file_path, dnf_list, flatpak_list, top_header):
    lines = [
        "# ==============================================================================",
        f"# {top_header} (Top Section)",
        "# ==============================================================================",
        ""
    ]
    for d in dnf_list:
        if d.strip():
            lines.append(d.strip())
    lines.extend([
        "",
        "# --- FLATPAK PACKAGES ---",
        "# ==============================================================================",
        "# Flatpak AppStream IDs (Bottom Section)",
        "# ==============================================================================",
        ""
    ])
    for f in flatpak_list:
        if f.strip():
            lines.append(f.strip())
    lines.append("")
    with open(file_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

def parse_domain_conf():
    domain_file = REPO_DIR / "domain.conf"
    data = {}
    if domain_file.exists():
        with open(domain_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or not line or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip().strip('"').strip("'")
    return data

def save_domain_conf(data):
    domain_file = REPO_DIR / "domain.conf"
    lines = [
        f'# pVPN Control: "yes", "no", or "ask"',
        f'ENABLE_PVPN="{data.get("ENABLE_PVPN", "yes")}"',
        f'PVPN_USER="{data.get("PVPN_USER", "")}"',
        f'PVPN_PASS="{data.get("PVPN_PASS", "")}"',
        '',
        f'# Active Directory Domain Configuration',
        f'DOMAIN_NAME="{data.get("DOMAIN_NAME", "gsfcu.local")}"',
        f'REALM_NAME="{data.get("REALM_NAME", "GSFCU.LOCAL")}"',
        f'AD_DNS_IP="{data.get("AD_DNS_IP", "")}"',
        f'DOMAIN_USER="{data.get("DOMAIN_USER", "admin")}"',
        '',
        f'# Username Short-Name Toggle',
        f'ALLOW_SHORT_USERNAMES="{data.get("ALLOW_SHORT_USERNAMES", "yes")}"',
        '',
        f'# Set policy refresh interval',
        f'REFRESH_INTERVAL="{data.get("REFRESH_INTERVAL", "1h")}"',
        '',
        f'# System Timezone',
        f'SYSTEM_TIMEZONE="{data.get("SYSTEM_TIMEZONE", "Asia/Kolkata")}"',
        '',
        f'# Intranet Primary Server Configuration',
        f'USE_INTRANET_FIRST="{data.get("USE_INTRANET_FIRST", "yes")}"',
        f'INTRANET_HOST_NAME="{data.get("INTRANET_HOST_NAME", "GSFCUPLLAB203")}"',
        f'INTRANET_FALLBACK_IP="{data.get("INTRANET_FALLBACK_IP", "10.205.18.253")}"',
        f'INTRANET_PORT="{data.get("INTRANET_PORT", "8080")}"',
        '',
        f'# Blocked Software Notification Message',
        f'BLOCK_NOTIFICATION_TITLE="{data.get("BLOCK_NOTIFICATION_TITLE", "Unauthorized Application Blocked")}"',
        f'BLOCK_NOTIFICATION_MSG="{data.get("BLOCK_NOTIFICATION_MSG", "Access Denied: This application is blacklisted under University IT Policy and has been terminated and removed.")}"',
        '',
        f'# Unapproved Software Installation Academic Warning Message',
        f'ACADEMIC_WARNING_MSG="{data.get("ACADEMIC_WARNING_MSG", "WARNING: This software is not pre-approved. If this package is found to be non-academic or violates institution policy, strict disciplinary action will be initiated.")}"',
        ''
    ]
    with open(domain_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

def parse_device_rules():
    dev_file = CONFIG_DIR / "device-rules.conf"
    data = {"LOCK_BRIGHTNESS_100": "yes", "LOCK_VOLUME_100": "yes", "DEVICE_CHECK_INTERVAL": "5m"}
    if dev_file.exists():
        with open(dev_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or not line or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip().strip('"').strip("'")
    return data

def save_device_rules(data):
    dev_file = CONFIG_DIR / "device-rules.conf"
    lines = [
        "# ==============================================================================",
        "# AD-DMS Hardware & Device Policy Rules",
        "# ==============================================================================",
        f'LOCK_BRIGHTNESS_100="{data.get("LOCK_BRIGHTNESS_100", "yes")}"',
        f'LOCK_VOLUME_100="{data.get("LOCK_VOLUME_100", "yes")}"',
        f'DEVICE_CHECK_INTERVAL="{data.get("DEVICE_CHECK_INTERVAL", "5m")}"',
        ''
    ]
    with open(dev_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

def parse_lab_conf():
    lab_file = REPO_DIR / "lab.conf"
    labs = []
    if lab_file.exists():
        with open(lab_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or not line or ":" not in line:
                    continue
                parts = [p.strip() for p in line.split(":")]
                if len(parts) >= 3:
                    labs.append({"name": parts[0], "group": parts[1], "prefix": parts[2]})
    return labs

def parse_group_apps():
    ga_file = CONFIG_DIR / "group-apps.conf"
    dnf_map = {}
    flatpak_map = {}
    mode = "dnf"
    if ga_file.exists():
        with open(ga_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "--- FLATPAK PACKAGES ---" in line or "# --- FLATPAK" in line:
                    mode = "flatpak"
                    continue
                if line.startswith("#") or not line or ":" not in line:
                    continue
                parts = line.split(":", 1)
                pattern = parts[0].strip()
                pkgs = parts[1].strip()
                if mode == "dnf":
                    dnf_map[pattern] = pkgs
                else:
                    flatpak_map[pattern] = pkgs
    return {"dnf": dnf_map, "flatpak": flatpak_map}

def save_group_apps(data):
    ga_file = CONFIG_DIR / "group-apps.conf"
    dnf_map = data.get("dnf", {})
    flatpak_map = data.get("flatpak", {})
    lines = [
        "# ==============================================================================",
        "# Native DNF / RPM Packages by Hostname Pattern (Top Section)",
        "# Format -> HOSTNAME_PATTERN : package1 package2 package3 ...",
        "# =============================================================================="
    ]
    for pat, pkgs in dnf_map.items():
        lines.append(f"{pat:<12} : {pkgs}")
    lines.extend([
        "",
        "# --- FLATPAK PACKAGES ---",
        "# ==============================================================================",
        "# Flatpak AppStream IDs by Hostname Pattern (Bottom Section)",
        "# Format -> HOSTNAME_PATTERN : flatpak.id1 flatpak.id2 ...",
        "# =============================================================================="
    ])
    for pat, pkgs in flatpak_map.items():
        lines.append(f"{pat:<12} : {pkgs}")
    lines.append("")
    with open(ga_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

def get_violations():
    vdir = Path("/var/log/ad-dms-violations")
    records = []
    if vdir.exists():
        for count_file in vdir.glob("*.count"):
            user = count_file.stem
            try:
                count = int(count_file.read_text().strip() or "0")
            except Exception:
                count = 0
            records.append({"user": user, "count": count, "date": "Recorded on system"})
    return records

class AD_DMS_ServerHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # Serve from REPO_DIR so intranet clients can fetch /config/*, /presets/*, /install.sh, etc.
        super().__init__(*args, directory=str(REPO_DIR), **kwargs)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(url.query)

        # 1. UI Root (redirects / or /index.html to /web/index.html)
        if url.path in ["/", "/index.html"]:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            index_file = WEB_DIR / "index.html"
            self.wfile.write(index_file.read_bytes())
            return

        # 2. Web UI static assets
        if url.path.startswith("/web/") or url.path in ["/styles.css", "/app.js"]:
            rel_name = url.path.replace("/web/", "").lstrip("/")
            asset_path = WEB_DIR / rel_name
            if asset_path.exists():
                ctype = "text/css" if str(asset_path).endswith(".css") else "application/javascript" if str(asset_path).endswith(".js") else "text/html"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.end_headers()
                self.wfile.write(asset_path.read_bytes())
                return

        # 3. Client Telemetry & Monitoring API
        if url.path == "/api/clients":
            clients = load_clients()
            now = time.time()
            # Mark active if heartbeat was within last 180 seconds (3 mins)
            client_list = []
            for hostname, info in clients.items():
                last_seen = info.get("last_seen_ts", 0)
                info["is_active"] = (now - last_seen) < 180
                client_list.append(info)
            self.send_json_response({"clients": client_list})
            return

        # 3b. Audit Telemetry API (User login durations & Discovered Application packages)
        if url.path == "/api/audit":
            audit = load_audit_log()
            apps_list = list(audit.get("installed_apps", {}).values())
            self.send_json_response({
                "user_sessions": list(reversed(audit.get("user_sessions", []))),
                "installed_apps": apps_list
            })
            return

        # 4. Client Poll for Remote Command or Screenshot Request
        if url.path == "/api/command/poll":
            hostname = params.get("host", [""])[0].upper()
            commands = load_commands()
            cmd_to_run = commands.pop(hostname, None)
            if not cmd_to_run:
                # Check wildcard 'ALL' or matching lab prefix
                for target_pat, cmd in list(commands.items()):
                    if target_pat == "ALL" or target_pat in hostname:
                        cmd_to_run = cmd
                        break
            if cmd_to_run:
                save_commands(commands)
                self.send_json_response({"has_command": True, "command": cmd_to_run})
            else:
                self.send_json_response({"has_command": False})
            return

        # 5. Full Data for Web UI & TUI
        if url.path == "/api/all-data":
            clients = load_clients()
            now = time.time()
            active_count = sum(1 for c in clients.values() if (now - c.get("last_seen_ts", 0)) < 180)
            data = {
                "domain": parse_domain_conf(),
                "deviceRules": parse_device_rules(),
                "blocked": parse_split_conf(CONFIG_DIR / "blocked-apps.conf"),
                "allowed": parse_split_conf(CONFIG_DIR / "allowed-apps.conf"),
                "compulsory": parse_split_conf(CONFIG_DIR / "compulsory-apps.conf"),
                "labs": parse_lab_conf(),
                "groupApps": parse_group_apps(),
                "violations": get_violations(),
                "clients_count": len(clients),
                "active_clients_count": active_count
            }
            self.send_json_response(data)
            return

        # Fallback to standard file server for /config/*, /presets/*, /install.sh, /assets/*
        super().do_GET()

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8", errors="ignore") if content_length > 0 else "{}"
        try:
            req_data = json.loads(body)
        except Exception:
            req_data = {}

        # 1. Client Heartbeat Telemetry & Audit Tracker
        if url.path == "/api/heartbeat":
            hostname = req_data.get("hostname", "UNKNOWN").upper()
            ip = self.client_address[0]
            clients = load_clients()
            now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            now_ts = time.time()
            active_user = req_data.get("active_user", "none")
            
            # Update active client record
            prev_user = clients.get(hostname, {}).get("active_user", "none")
            clients[hostname] = {
                "hostname": hostname,
                "ip": req_data.get("ip", ip),
                "active_user": active_user,
                "session_type": req_data.get("session_type", "niri"),
                "uptime": req_data.get("uptime", "unknown"),
                "dms_version": req_data.get("dms_version", "installed"),
                "last_seen": now_str,
                "last_seen_ts": now_ts,
                "first_registered": clients.get(hostname, {}).get("first_registered", now_str)
            }
            save_clients(clients)

            # Update User Login Session History & Installed Apps Audit Log
            audit_data = load_audit_log()
            user_sessions = audit_data.get("user_sessions", [])
            installed_apps_map = audit_data.get("installed_apps", {})

            if active_user and active_user not in ["none", "nobody", "greeter", "root"]:
                # Check if this session is already open and ongoing
                session_found = False
                for sess in reversed(user_sessions):
                    if sess.get("hostname") == hostname and sess.get("user") == active_user:
                        # If heartbeat received within last 180s (3m), update ongoing session duration
                        if (now_ts - sess.get("last_seen_ts", 0)) < 180:
                            sess["last_seen"] = now_str
                            sess["last_seen_ts"] = now_ts
                            sess["duration_mins"] = max(1, int((now_ts - sess.get("start_ts", now_ts)) / 60))
                            sess["status"] = "Active"
                            session_found = True
                            break
                if not session_found:
                    # New distinct user login session initiated - preserves all previous historical sessions!
                    user_sessions.append({
                        "hostname": hostname,
                        "ip": req_data.get("ip", ip),
                        "user": active_user,
                        "session_type": req_data.get("session_type", "desktop"),
                        "login_time": now_str,
                        "start_ts": now_ts,
                        "last_seen": now_str,
                        "last_seen_ts": now_ts,
                        "duration_mins": 0,
                        "status": "Active"
                    })
                    # Persist up to 1,000 historical user sessions across reboots & logouts
                    if len(user_sessions) > 1000:
                        user_sessions = user_sessions[-1000:]
                    audit_data["user_sessions"] = user_sessions

            # Record Installed Apps Inventory
            apps = req_data.get("installed_apps", [])
            for app_spec in apps:
                if ":" in app_spec:
                    kind, name = app_spec.split(":", 1)
                else:
                    kind, name = "flatpak", app_spec
                if name not in installed_apps_map:
                    installed_apps_map[name] = {
                        "name": name,
                        "kind": kind,
                        "discovered_on": now_str,
                        "hosts": [hostname],
                        "users": [active_user] if active_user not in ["none", "nobody"] else []
                    }
                else:
                    entry = installed_apps_map[name]
                    if hostname not in entry.get("hosts", []):
                        entry["hosts"].append(hostname)
                    if active_user not in ["none", "nobody"] and active_user not in entry.get("users", []):
                        entry["users"].append(active_user)
            
            audit_data["installed_apps"] = installed_apps_map
            save_audit_log(audit_data)

            self.send_json_response({"status": "ok", "ack": True})
            return

        # 2. Client Fresh Installation Registration & Notification
        if url.path == "/api/register-install":
            hostname = req_data.get("hostname", "UNKNOWN").upper()
            ip = self.client_address[0]
            user = req_data.get("user", "admin")
            
            clients = load_clients()
            clients[hostname] = {
                "hostname": hostname,
                "ip": req_data.get("ip", ip),
                "active_user": user,
                "session_type": "niri",
                "uptime": "0 min",
                "last_seen": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "last_seen_ts": time.time(),
                "first_registered": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            }
            save_clients(clients)

            # Trigger host desktop notification if running in desktop environment
            try:
                subprocess.run([
                    "notify-send", "-a", "AD-DMS Intranet", "-u", "normal",
                    "🚀 New Workstation Enrolled",
                    f"Host: {hostname}\nIP: {ip}\nUser: {user}"
                ], check=False)
            except Exception:
                pass

            self.send_json_response({"status": "ok", "registered": True})
            return

        # 3. Client Screenshot Upload
        if url.path == "/api/screenshot/upload":
            hostname = req_data.get("hostname", "unknown").upper()
            img_b64 = req_data.get("image_base64", "")
            if img_b64:
                import base64
                img_data = base64.b64decode(img_b64)
                shot_path = SCREENSHOTS_DIR / f"{hostname}_latest.png"
                shot_path.write_bytes(img_data)
                self.send_json_response({"status": "ok", "saved_to": str(shot_path)})
            else:
                self.send_json_response({"status": "error", "message": "Missing image_base64"})
            return

        # 4. Schedule Remote Command / Screenshot Request from Host
        if url.path == "/api/command/dispatch":
            target = req_data.get("target", "ALL").upper()
            action = req_data.get("action", "")
            commands = load_commands()
            commands[target] = req_data
            save_commands(commands)
            self.send_json_response({"status": "ok", "dispatched_to": target})
            return

        # 5. Configuration Saving Endpoints
        if url.path == "/api/save-domain":
            save_domain_conf(req_data)
            self.send_json_response({"status": "ok", "message": "domain.conf updated successfully"})
            return

        if url.path == "/api/save-policies":
            if "blocked" in req_data:
                save_split_conf(CONFIG_DIR / "blocked-apps.conf", req_data["blocked"].get("dnf", []), req_data["blocked"].get("flatpak", []), "Native DNF / RPM Packages to Block & Remove")
            if "allowed" in req_data:
                save_split_conf(CONFIG_DIR / "allowed-apps.conf", req_data["allowed"].get("dnf", []), req_data["allowed"].get("flatpak", []), "Native DNF / RPM Packages")
            if "compulsory" in req_data:
                save_split_conf(CONFIG_DIR / "compulsory-apps.conf", req_data["compulsory"].get("dnf", []), req_data["compulsory"].get("flatpak", []), "Native DNF / RPM Packages")
            self.send_json_response({"status": "ok", "message": "Policy configurations saved successfully"})
            return

        if url.path == "/api/save-devices":
            save_device_rules(req_data)
            self.send_json_response({"status": "ok", "message": "device-rules.conf updated"})
            return

        if url.path == "/api/save-group-apps":
            save_group_apps(req_data)
            self.send_json_response({"status": "ok", "message": "group-apps.conf updated"})
            return

        if url.path == "/api/git-push":
            commit_msg = req_data.get("commit_msg", "feat: update AD-DMS policy configs via Control Center")
            try:
                subprocess.run(["git", "add", "-A"], cwd=str(REPO_DIR), check=True)
                subprocess.run(["git", "commit", "-m", commit_msg], cwd=str(REPO_DIR), check=False)
                res = subprocess.run(["git", "push", "origin", "main"], cwd=str(REPO_DIR), capture_output=True, text=True)
                if res.returncode == 0:
                    self.send_json_response({"status": "ok", "output": res.stdout or "Pushed to origin/main successfully!"})
                else:
                    self.send_json_response({"status": "error", "output": res.stderr or "Git push returned non-zero code."})
            except Exception as e:
                self.send_json_response({"status": "error", "output": str(e)})
            return

        self.send_response(404)
        self.end_headers()

    def send_json_response(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

def main():
    print("=" * 75)
    print("  AD-DMS INTRANET HOST SERVER & MONITORING BACKEND")
    print("=" * 75)
    print(f"  -> Serving Intranet Repository: {REPO_DIR}")
    print(f"  -> Control Center & API Port:   {PORT}")
    print(f"  -> Host Server Ready for Intranet Client Nodes & 'remote' TUI.\n")
    
    server = http.server.ThreadingHTTPServer(("", PORT), AD_DMS_ServerHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer shutting down.")

if __name__ == "__main__":
    main()
