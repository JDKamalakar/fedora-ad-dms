/* ==============================================================================
   AD-DMS Control Center | Client-Side Dynamic Controller
   M3 Tab Switcher, Local Configuration State, Live Actions & Export Engine
   ============================================================================== */

// State Object representing live repository configurations
const AppState = {
  domain: {
    ENABLE_PVPN: "yes",
    PVPN_USER: "gsfcu@proton.me",
    PVPN_PASS: "Test@1199",
    DOMAIN_NAME: "gsfcu.local",
    REALM_NAME: "GSFCU.LOCAL",
    AD_DNS_IP: "10.205.4.177",
    DOMAIN_USER: "admin",
    ALLOW_SHORT_USERNAMES: "yes",
    REFRESH_INTERVAL: "1h",
    SYSTEM_TIMEZONE: "Asia/Kolkata",
    BLOCK_NOTIFICATION_TITLE: "Unauthorized Application Blocked",
    BLOCK_NOTIFICATION_MSG: "Access Denied: This application is blacklisted under University IT Policy and has been terminated and removed.",
    ACADEMIC_WARNING_MSG: "WARNING: This software is not pre-approved. If this package is found to be non-academic or violates institution policy, strict disciplinary action will be initiated."
  },
  deviceRules: {
    LOCK_BRIGHTNESS_100: "yes",
    LOCK_VOLUME_100: "yes",
    DEVICE_CHECK_INTERVAL: "5m"
  },
  policies: {
    blocked: [
      "*steam*", "*game*", "lutris", "playonlinux", "minetest", "supertuxkart",
      "kmahjongg", "kmines", "kpat", "mines",
      "com.valvesoftware.Steam", "net.lutris.Lutris", "io.github.Faugus.faugus-launcher",
      "com.heroicgameslauncher.hgl", "org.DolphinEmu.dolphin-emu", "org.PPSSPP.PPSSPP"
    ],
    allowed: [
      "code", "vlc", "htop", "fastfetch", "chromium-browser.desktop", "firefox", "curl", "git", "kitty", "haruna",
      "org.videolan.VLC", "org.blender.Blender", "org.gimp.GIMP", "org.inkscape.Inkscape"
    ],
    compulsory: [
      "dms", "kitty", "niri", "greetd", "proton-vpn-gnome-desktop", "onlyoffice-desktopeditors"
    ]
  },
  labs: [
    { name: "Programming Lab", group: "prolab", prefix: "GSFCUPLLAB", apps: "code, git, gcc, python3" },
    { name: "Operating Systems Lab", group: "oslab", prefix: "GSFCUOSLAB", apps: "qemu, gdb, valgrind, gcc" },
    { name: "Data Science Lab", group: "dslab", prefix: "GSFCUDSLAB", apps: "jupyter-lab, pandas, r-base" },
    { name: "Data Engineering Lab", group: "delab", prefix: "GSFCUDELAB", apps: "dbeaver, postgresql, docker" },
    { name: "AI/ML Lab", group: "ailab", prefix: "GSFCUAILAB", apps: "pytorch, tensorflow, ollama" },
    { name: "Robotic & Automation Lab", group: "ralab", prefix: "GSFCURALAB", apps: "ros2, gazebo, arduino" },
    { name: "Cybersecurity Lab", group: "cslab", prefix: "GSFCUCSLAB", apps: "wireshark, nmap, burpsuite" },
    { name: "CAD Lab", group: "cadlab", prefix: "GSFCUCADLAB", apps: "freecad, blender, openscad" }
  ],
  violations: [
    { user: "student_lab1", count: 1, lastItem: "com.valvesoftware.Steam", date: "Today, 10:14 AM" },
    { user: "guest_user", count: 4, lastItem: "com.heroicgameslauncher.hgl", date: "Today, 11:30 AM" }
  ]
};

// Initialize Application
document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupThemeToggle();
  renderPolicyChips();
  renderViolations();
  renderLabs();
  setupAudioTest();
  updateStats();
});

// Tab Navigation
function setupNavigation() {
  const navItems = document.querySelectorAll('.m3-nav-item');
  const titleEl = document.getElementById('currentPageTitle');

  navItems.forEach(item => {
    item.addEventListener('click', () => {
      navItems.forEach(n => n.classList.remove('active'));
      item.classList.add('active');

      const targetTab = item.getAttribute('data-tab');
      document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
      const activePane = document.getElementById(`pane-${targetTab}`);
      if (activePane) activePane.classList.add('active');

      const label = item.querySelector('.nav-label').textContent;
      titleEl.textContent = label === 'Overview' ? 'System Overview' : `${label} Configuration`;
    });
  });
}

// Theme Toggle
function setupThemeToggle() {
  const btn = document.getElementById('themeToggle');
  btn.addEventListener('click', () => {
    document.body.classList.toggle('light-theme');
    const isLight = document.body.classList.contains('light-theme');
    btn.innerHTML = `<span class="material-symbols-rounded">${isLight ? 'light_mode' : 'dark_mode'}</span>`;
    showToast(isLight ? 'Switched to Light Material Theme' : 'Switched to Dark Material Theme', 'palette');
  });
}

// Render Policy Chips
function renderPolicyChips() {
  ['blocked', 'allowed', 'compulsory'].forEach(category => {
    const container = document.getElementById(`container${capitalize(category)}`);
    if (!container) return;
    container.innerHTML = '';

    AppState.policies[category].forEach(item => {
      const chip = document.createElement('div');
      chip.className = 'policy-chip';
      chip.innerHTML = `
        <span>${item}</span>
        <button onclick="removePolicyItem('${category}', '${item}')" title="Remove">&times;</button>
      `;
      container.appendChild(chip);
    });
  });
  updateStats();
}

function removePolicyItem(category, item) {
  AppState.policies[category] = AppState.policies[category].filter(i => i !== item);
  renderPolicyChips();
  showToast(`Removed rule: ${item}`, 'delete');
}

function addRulePrompt(category) {
  const item = prompt(`Enter package name or Flatpak App ID to add to ${category} policy:`);
  if (item && item.trim()) {
    AppState.policies[category].push(item.trim());
    renderPolicyChips();
    showToast(`Added ${item} to ${category} rules`, 'add_task');
  }
}

// Render Violations Table
function renderViolations() {
  const tbody = document.getElementById('violationsBody');
  if (!tbody) return;
  tbody.innerHTML = '';

  AppState.violations.forEach((v, index) => {
    const tr = document.createElement('tr');
    const isAlarm = v.count > 3;
    tr.innerHTML = `
      <td><strong>${v.user}</strong></td>
      <td><span class="m3-badge ${isAlarm ? 'border-error color-error' : 'success'}">${v.count} Violation(s)</span></td>
      <td>
        ${isAlarm 
          ? '<span class="color-error" style="font-weight:700;">🚨 Siren Triggered (100% Vol)</span>' 
          : '<span style="color:var(--md-sys-color-outline)">Normal (Silent)</span>'}
      </td>
      <td><code>${v.lastItem}</code> <span style="font-size:12px; color:var(--md-sys-color-outline);">(${v.date})</span></td>
      <td>
        <button class="m3-button secondary small" onclick="resetViolation(${index})">
          <span class="material-symbols-rounded">restart_alt</span> Reset
        </button>
      </td>
    `;
    tbody.appendChild(tr);
  });
}

function resetViolation(index) {
  const v = AppState.violations[index];
  v.count = 0;
  renderViolations();
  updateStats();
  showToast(`Reset violation score for user '${v.user}' to 0`, 'check');
}

function addMockViolation() {
  const user = prompt("Enter username to record violation against (e.g. oslab):", "oslab");
  if (!user) return;
  const app = prompt("Enter attempted blocked app ID:", "com.valvesoftware.Steam");
  
  let record = AppState.violations.find(v => v.user === user);
  if (record) {
    record.count++;
    record.lastItem = app || "unauthorized_app";
    record.date = "Just now";
  } else {
    AppState.violations.push({
      user: user,
      count: 1,
      lastItem: app || "unauthorized_app",
      date: "Just now"
    });
  }
  renderViolations();
  updateStats();
  showToast(`Violation recorded for '${user}'`, 'warning');
}

// Render Labs
function renderLabs() {
  const tbody = document.getElementById('labBody');
  if (!tbody) return;
  tbody.innerHTML = '';

  AppState.labs.forEach(lab => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><strong>${lab.name}</strong></td>
      <td><code>${lab.group}</code></td>
      <td><code>${lab.prefix}</code></td>
      <td><span style="color:var(--md-sys-color-on-surface-variant)">${lab.apps}</span></td>
    `;
    tbody.appendChild(tr);
  });
}

// Siren Audio Preview
function setupAudioTest() {
  const btn = document.getElementById('btnTestSiren');
  const audio = document.getElementById('sirenAudio');
  if (!btn || !audio) return;

  btn.addEventListener('click', () => {
    if (audio.paused) {
      audio.volume = 1.0;
      audio.play().then(() => {
        btn.innerHTML = '<span class="material-symbols-rounded">stop_circle</span> <span>Stop Siren</span>';
        showToast('Testing Siren.mp3 at 100% Volume', 'volume_up');
      }).catch(err => {
        showToast('Audio playback simulation initiated', 'volume_up');
      });
    } else {
      audio.pause();
      audio.currentTime = 0;
      btn.innerHTML = '<span class="material-symbols-rounded">play_circle</span> <span>Test Audio Playback</span>';
    }
  });
}

// Save Domain Settings
function saveDomainConfig() {
  AppState.domain.DOMAIN_NAME = document.getElementById('confDomainName').value;
  AppState.domain.REALM_NAME = document.getElementById('confRealmName').value;
  AppState.domain.AD_DNS_IP = document.getElementById('confDnsIp').value;
  AppState.domain.DOMAIN_USER = document.getElementById('confDomainUser').value;
  AppState.domain.REFRESH_INTERVAL = document.getElementById('confRefreshInterval').value;
  AppState.domain.SYSTEM_TIMEZONE = document.getElementById('confSystemTimezone').value;
  AppState.domain.BLOCK_NOTIFICATION_TITLE = document.getElementById('confBlockNotifTitle').value;
  AppState.domain.BLOCK_NOTIFICATION_MSG = document.getElementById('confBlockNotifMsg').value;
  AppState.domain.ACADEMIC_WARNING_MSG = document.getElementById('confAcademicWarningMsg').value;

  document.getElementById('timerCountdown').textContent = `Sync in: ~${AppState.domain.REFRESH_INTERVAL}`;
  showToast('domain.conf parameters updated successfully', 'check_circle');
}

// Save Device Rules
function saveDeviceRules() {
  const bright = document.getElementById('switchBrightness').checked;
  const vol = document.getElementById('switchVolume').checked;
  AppState.deviceRules.LOCK_BRIGHTNESS_100 = bright ? "yes" : "no";
  AppState.deviceRules.LOCK_VOLUME_100 = vol ? "yes" : "no";

  showToast('Hardware Governance rules updated (100% lock enabled)', 'tune');
}

// Update Stats
function updateStats() {
  document.getElementById('statAllowedCount').textContent = 
    AppState.policies.allowed.length + AppState.policies.compulsory.length;
  document.getElementById('statBlockedCount').textContent = AppState.policies.blocked.length;
  document.getElementById('statLabCount').textContent = AppState.labs.length;
  
  const totalViolations = AppState.violations.reduce((acc, curr) => acc + curr.count, 0);
  document.getElementById('statViolationCount').textContent = totalViolations;
}

// Export Configuration ZIP / Plain text bundle
document.getElementById('btnExportAll')?.addEventListener('click', () => {
  const domainText = `# Active Directory Domain Configuration\nENABLE_PVPN="${AppState.domain.ENABLE_PVPN}"\nDOMAIN_NAME="${AppState.domain.DOMAIN_NAME}"\nREALM_NAME="${AppState.domain.REALM_NAME}"\nAD_DNS_IP="${AppState.domain.AD_DNS_IP}"\nDOMAIN_USER="${AppState.domain.DOMAIN_USER}"\nALLOW_SHORT_USERNAMES="${AppState.domain.ALLOW_SHORT_USERNAMES}"\nREFRESH_INTERVAL="${AppState.domain.REFRESH_INTERVAL}"\nSYSTEM_TIMEZONE="${AppState.domain.SYSTEM_TIMEZONE}"\nBLOCK_NOTIFICATION_TITLE="${AppState.domain.BLOCK_NOTIFICATION_TITLE}"\nBLOCK_NOTIFICATION_MSG="${AppState.domain.BLOCK_NOTIFICATION_MSG}"\nACADEMIC_WARNING_MSG="${AppState.domain.ACADEMIC_WARNING_MSG}"\n`;

  const blob = new Blob([domainText], { type: 'text/plain' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'domain.conf';
  a.click();
  showToast('Exported domain.conf bundle', 'file_download');
});

document.getElementById('btnTriggerRefresh')?.addEventListener('click', () => {
  showToast('Triggering policy synchronization: refresh', 'sync');
});

// Toast Notification Engine
function showToast(message, icon = 'info') {
  const container = document.getElementById('toastContainer');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = 'm3-toast';
  toast.innerHTML = `<span class="material-symbols-rounded">${icon}</span> <span>${message}</span>`;
  container.appendChild(toast);

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(100%)';
    toast.style.transition = 'all 300ms ease';
    setTimeout(() => toast.remove(), 300);
  }, 3000);
}

function copyInstallCmd() {
  const cmd = 'curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/install.sh?$(date +%s)" | sudo bash';
  navigator.clipboard.writeText(cmd).then(() => {
    showToast('Deployment command copied to clipboard!', 'content_copy');
  });
}

function capitalize(s) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}
