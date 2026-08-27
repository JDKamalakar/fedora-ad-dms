#!/usr/bin/env python3
"""
AD-DMS Web Server & Configuration API Backend
Serves Material 3 Expressive UI and provides direct read/write REST endpoints
for live configuration files and git operations.
"""

import http.server
import json
import os
import subprocess
import urllib.parse
from pathlib import Path

PORT = 8080
REPO_DIR = Path(__file__).resolve().parent
CONFIG_DIR = REPO_DIR / "config"
WEB_DIR = REPO_DIR / "web"

def parse_split_conf(file_path):
    """Parses a conf file with DNF (top) and Flatpak (bottom) sections."""
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
    """Writes back DNF and Flatpak sections to a conf file."""
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

class AD_DMS_Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/api/all-data":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            
            data = {
                "domain": parse_domain_conf(),
                "deviceRules": parse_device_rules(),
                "blocked": parse_split_conf(CONFIG_DIR / "blocked-apps.conf"),
                "allowed": parse_split_conf(CONFIG_DIR / "allowed-apps.conf"),
                "compulsory": parse_split_conf(CONFIG_DIR / "compulsory-apps.conf"),
                "labs": parse_lab_conf(),
                "groupApps": parse_group_apps(),
                "violations": get_violations()
            }
            self.wfile.write(json.dumps(data).encode("utf-8"))
            return

        super().do_GET()

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            req_data = json.loads(body)
        except Exception:
            req_data = {}

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
    print("=" * 70)
    print("  AD-DMS CONTROL CENTER | MATERIAL 3 EXPRESSIVE BACKEND & UI")
    print("=" * 70)
    print(f"  -> Serving live repository configs from: {REPO_DIR}")
    print(f"  -> Access Control Center at: http://localhost:{PORT}")
    print(f"  -> Press Ctrl+C to stop server.\n")
    
    server = http.server.ThreadingHTTPServer(("", PORT), AD_DMS_Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer shutting down.")

if __name__ == "__main__":
    main()
