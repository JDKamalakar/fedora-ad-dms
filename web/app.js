/* ==============================================================================
   AD-DMS Control Center | Client-Side Controller
   Live Repository Integration, Custom M3 Modals, DNF/Flatpak Split & Git Push
   ============================================================================== */

let AppState = {
  domain: {},
  deviceRules: {},
  blocked: { dnf: [], flatpak: [] },
  allowed: { dnf: [], flatpak: [] },
  compulsory: { dnf: [], flatpak: [] },
  labs: [],
  groupApps: { dnf: {}, flatpak: {} },
  violations: []
};

// Initialize on Load
document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupThemeToggle();
  setupAudioTest();
  setupGitPushButton();
  loadLiveConfigs();
  loadAuditLogs();

  // Auto-refresh live monitoring and audit tables every 5 seconds
  setInterval(() => {
    renderWorkstations(false);
    loadAuditLogs(false);
  }, 5000);
});

// Fetch Live Data from Server API
async function loadLiveConfigs() {
  try {
    const res = await fetch('/api/all-data');
    if (!res.ok) throw new Error('API fetch error');
    const data = await res.json();
    AppState = data;
    
    populateDomainForm();
    populateDeviceRules();
    renderPolicyChips();
    renderGroupApps();
    renderViolations();
    renderWorkstations();
    updateStats();
    showToast('Loaded active repository configurations', 'cloud_done');
  } catch (err) {
    console.error('Failed to load configs from API:', err);
    showToast('Offline Mode: Using local memory buffer', 'cloud_off');
  }
}

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

// Populate Domain Settings
function populateDomainForm() {
  const d = AppState.domain || {};
  document.getElementById('confDomainName').value = d.DOMAIN_NAME || 'gsfcu.local';
  document.getElementById('confRealmName').value = d.REALM_NAME || 'GSFCU.LOCAL';
  document.getElementById('confDnsIp').value = d.AD_DNS_IP || '10.205.4.177';
  document.getElementById('confDomainUser').value = d.DOMAIN_USER || 'admin';
  document.getElementById('confRefreshInterval').value = d.REFRESH_INTERVAL || '1h';
  document.getElementById('confSystemTimezone').value = d.SYSTEM_TIMEZONE || 'Asia/Kolkata';
  document.getElementById('confIntranetHost').value = d.INTRANET_HOST_NAME || 'GSFCUPLLAB203';
  document.getElementById('confIntranetIp').value = d.INTRANET_FALLBACK_IP || '10.205.18.253';
  document.getElementById('confBlockNotifTitle').value = d.BLOCK_NOTIFICATION_TITLE || 'Unauthorized Application Blocked';
  document.getElementById('confBlockNotifMsg').value = d.BLOCK_NOTIFICATION_MSG || 'Access Denied: This application is blacklisted under University IT Policy and has been terminated and removed.';
  document.getElementById('confAcademicWarningMsg').value = d.ACADEMIC_WARNING_MSG || 'WARNING: This software is not pre-approved. If this package is found to be non-academic or violates institution policy, strict disciplinary action will be initiated.';
  
  document.getElementById('timerCountdown').textContent = `Interval: ~${d.REFRESH_INTERVAL || '1h'}`;
}

async function saveDomainConfig() {
  AppState.domain.DOMAIN_NAME = document.getElementById('confDomainName').value.trim();
  AppState.domain.REALM_NAME = document.getElementById('confRealmName').value.trim();
  AppState.domain.AD_DNS_IP = document.getElementById('confDnsIp').value.trim();
  AppState.domain.DOMAIN_USER = document.getElementById('confDomainUser').value.trim();
  AppState.domain.REFRESH_INTERVAL = document.getElementById('confRefreshInterval').value.trim();
  AppState.domain.SYSTEM_TIMEZONE = document.getElementById('confSystemTimezone').value.trim();
  AppState.domain.INTRANET_HOST_NAME = document.getElementById('confIntranetHost').value.trim();
  AppState.domain.INTRANET_FALLBACK_IP = document.getElementById('confIntranetIp').value.trim();
  AppState.domain.BLOCK_NOTIFICATION_TITLE = document.getElementById('confBlockNotifTitle').value.trim();
  AppState.domain.BLOCK_NOTIFICATION_MSG = document.getElementById('confBlockNotifMsg').value.trim();
  AppState.domain.ACADEMIC_WARNING_MSG = document.getElementById('confAcademicWarningMsg').value.trim();

  try {
    const res = await fetch('/api/save-domain', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(AppState.domain)
    });
    const result = await res.json();
    showToast(result.message || 'Saved domain.conf', 'check_circle');
    document.getElementById('timerCountdown').textContent = `Interval: ~${AppState.domain.REFRESH_INTERVAL}`;
  } catch (err) {
    showToast('Saved domain settings in memory', 'check_circle');
  }
}

// Populate Device Rules
function populateDeviceRules() {
  const r = AppState.deviceRules || {};
  document.getElementById('switchBrightness').checked = (r.LOCK_BRIGHTNESS_100 || 'yes') === 'yes';
  document.getElementById('switchVolume').checked = (r.LOCK_VOLUME_100 || 'yes') === 'yes';
}

async function saveDeviceRules() {
  AppState.deviceRules.LOCK_BRIGHTNESS_100 = document.getElementById('switchBrightness').checked ? 'yes' : 'no';
  AppState.deviceRules.LOCK_VOLUME_100 = document.getElementById('switchVolume').checked ? 'yes' : 'no';

  try {
    const res = await fetch('/api/save-devices', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(AppState.deviceRules)
    });
    const result = await res.json();
    showToast(result.message || 'Saved device-rules.conf', 'tune');
  } catch (err) {
    showToast('Device rules saved in memory', 'tune');
  }
}

// Render Split Policy Chips (DNF and Flatpak separated)
function renderPolicyChips() {
  ['blocked', 'allowed', 'compulsory'].forEach(cat => {
    const dnfCont = document.getElementById(`container${capitalize(cat)}Dnf`);
    const fpCont = document.getElementById(`container${capitalize(cat)}Flatpak`);

    if (dnfCont) {
      dnfCont.innerHTML = '';
      (AppState[cat]?.dnf || []).forEach(item => {
        const chip = document.createElement('div');
        chip.className = 'policy-chip';
        chip.innerHTML = `<span>${item}</span><button onclick="removePolicyRule('${cat}', 'dnf', '${item}')" title="Remove">&times;</button>`;
        dnfCont.appendChild(chip);
      });
    }

    if (fpCont) {
      fpCont.innerHTML = '';
      (AppState[cat]?.flatpak || []).forEach(item => {
        const chip = document.createElement('div');
        chip.className = 'policy-chip chip-flatpak';
        chip.innerHTML = `<span>${item}</span><button onclick="removePolicyRule('${cat}', 'flatpak', '${item}')" title="Remove">&times;</button>`;
        fpCont.appendChild(chip);
      });
    }
  });
  updateStats();
}

async function removePolicyRule(category, type, item) {
  if (AppState[category] && AppState[category][type]) {
    AppState[category][type] = AppState[category][type].filter(i => i !== item);
    renderPolicyChips();
    await syncPoliciesToServer();
    showToast(`Removed rule: ${item}`, 'delete');
  }
}

async function syncPoliciesToServer() {
  try {
    await fetch('/api/save-policies', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        blocked: AppState.blocked,
        allowed: AppState.allowed,
        compulsory: AppState.compulsory
      })
    });
  } catch (err) {
    console.warn('Policy sync saved in memory buffer');
  }
}

// Open Custom Material Modal for Adding Policy Rule
function openAddPolicyModal(category) {
  const modal = document.getElementById('customModal');
  const title = document.getElementById('modalTitle');
  const body = document.getElementById('modalBody');
  const footer = document.getElementById('modalFooter');

  title.textContent = `Add Rule to ${capitalize(category)} Policy`;
  body.innerHTML = `
    <div class="m3-text-field" style="margin-bottom:14px;">
      <label for="modalAppType">Package Type</label>
      <select id="modalAppType">
        <option value="dnf">Native DNF / RPM Package (e.g. vlc, *game*)</option>
        <option value="flatpak">Flatpak AppStream ID (e.g. org.videolan.VLC)</option>
      </select>
    </div>
    <div class="m3-text-field">
      <label for="modalAppName">Application Name or Identifier</label>
      <input type="text" id="modalAppName" placeholder="e.g. htop or com.valvesoftware.Steam" autofocus required>
    </div>
  `;

  footer.innerHTML = `
    <button class="m3-button secondary" onclick="closeModal()">Cancel</button>
    <button class="m3-button primary" onclick="submitAddPolicyRule('${category}')">
      <span class="material-symbols-rounded">add_circle</span> Add Item
    </button>
  `;

  modal.classList.add('show');
  setTimeout(() => document.getElementById('modalAppName')?.focus(), 50);
}

async function submitAddPolicyRule(category) {
  const type = document.getElementById('modalAppType').value;
  const name = document.getElementById('modalAppName').value.trim();

  if (!name) {
    showToast('Please enter an application or package name', 'error');
    return;
  }

  if (!AppState[category]) AppState[category] = { dnf: [], flatpak: [] };
  if (!AppState[category][type]) AppState[category][type] = [];

  AppState[category][type].push(name);
  renderPolicyChips();
  closeModal();
  await syncPoliciesToServer();
  showToast(`Added ${name} to ${category} (${type.toUpperCase()})`, 'add_task');
}

// Group Apps Editor
function renderGroupApps() {
  const tbody = document.getElementById('groupAppsBody');
  if (!tbody) return;
  tbody.innerHTML = '';

  const labs = AppState.labs || [];
  const ga = AppState.groupApps || { dnf: {}, flatpak: {} };

  labs.forEach(lab => {
    const tr = document.createElement('tr');
    const dnfVal = ga.dnf[lab.prefix] || '';
    const fpVal = ga.flatpak[lab.prefix] || '';

    tr.innerHTML = `
      <td>
        <strong>${lab.prefix}</strong>
        <div style="font-size:12px; color:var(--md-sys-color-outline);">${lab.name} (${lab.group})</div>
      </td>
      <td>
        <input type="text" class="table-input" data-prefix="${lab.prefix}" data-type="dnf" value="${dnfVal}" placeholder="e.g. code gcc git">
      </td>
      <td>
        <input type="text" class="table-input" data-prefix="${lab.prefix}" data-type="flatpak" value="${fpVal}" placeholder="e.g. org.videolan.VLC">
      </td>
    `;
    tbody.appendChild(tr);
  });
}

async function saveGroupApps() {
  const inputs = document.querySelectorAll('#groupAppsBody .table-input');
  inputs.forEach(inp => {
    const prefix = inp.getAttribute('data-prefix');
    const type = inp.getAttribute('data-type');
    if (!AppState.groupApps[type]) AppState.groupApps[type] = {};
    AppState.groupApps[type][prefix] = inp.value.trim();
  });

  try {
    const res = await fetch('/api/save-group-apps', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(AppState.groupApps)
    });
    const result = await res.json();
    showToast(result.message || 'Saved group-apps.conf', 'check_circle');
  } catch (err) {
    showToast('Group apps saved in memory', 'check_circle');
  }
}

// Render Intranet Workstations
async function renderWorkstations(showLoading = true) {
  const tbody = document.getElementById('workstationsBody');
  if (!tbody) return;
  if (showLoading && tbody.innerHTML.trim() === '') {
    tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;">Loading active nodes...</td></tr>';
  }

  try {
    const res = await fetch('/api/clients');
    const data = await res.json();
    const clients = data.clients || [];

    if (clients.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" style="text-align:center; color:var(--md-sys-color-outline);">No intranet workstations registered yet.</td></tr>';
      return;
    }

    tbody.innerHTML = '';
    clients.forEach(c => {
      const tr = document.createElement('tr');
      const active = c.is_active;
      tr.innerHTML = `
        <td><strong>${c.hostname}</strong></td>
        <td><code>${c.ip}</code></td>
        <td><span style="font-weight:700; color:var(--md-sys-color-primary);">${c.active_user || 'none'}</span></td>
        <td><code>${c.session_type || 'niri'}</code></td>
        <td><span class="m3-badge ${active ? 'success' : 'border-error color-error'}">${active ? 'ONLINE' : 'OFFLINE'}</span></td>
        <td><span style="font-size:12px; color:var(--md-sys-color-outline);">${c.last_seen || ''}</span></td>
        <td>
          <button class="m3-button primary small" onclick="requestClientScreenshot('${c.hostname}')">
            <span class="material-symbols-rounded">screenshot</span> Capture
          </button>
        </td>
      `;
      tbody.appendChild(tr);
    });
  } catch (err) {
    tbody.innerHTML = '<tr><td colspan="7" style="text-align:center; color:var(--md-sys-color-error);">Failed to fetch client nodes.</td></tr>';
  }
}

async function requestClientScreenshot(hostname) {
  showToast(`Requesting screenshot from '${hostname}'...`, 'screenshot');
  try {
    await fetch('/api/command/dispatch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: hostname, action: 'screenshot' })
    });
    showToast(`Dispatched capture signal to ${hostname}. Checking for upload...`, 'hourglass_top');
  } catch (err) {
    showToast('Failed to dispatch screenshot signal', 'error');
  }
}
function renderViolations() {
  const tbody = document.getElementById('violationsBody');
  if (!tbody) return;
  tbody.innerHTML = '';

  (AppState.violations || []).forEach((v, index) => {
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
      <td><code>${v.lastItem || 'Policy Violation'}</code> <span style="font-size:12px; color:var(--md-sys-color-outline);">(${v.date})</span></td>
      <td>
        <button class="m3-button secondary small" onclick="resetViolationScore(${index})">
          <span class="material-symbols-rounded">restart_alt</span> Reset (0)
        </button>
      </td>
    `;
    tbody.appendChild(tr);
  });
}

function resetViolationScore(index) {
  const v = AppState.violations[index];
  v.count = 0;
  renderViolations();
  updateStats();
  showToast(`Reset violations for user '${v.user}' to 0`, 'check');
}

function openSimulateViolationModal() {
  const modal = document.getElementById('customModal');
  const title = document.getElementById('modalTitle');
  const body = document.getElementById('modalBody');
  const footer = document.getElementById('modalFooter');

  title.textContent = 'Simulate Policy Violation';
  body.innerHTML = `
    <div class="m3-text-field" style="margin-bottom:14px;">
      <label for="simUser">Username</label>
      <input type="text" id="simUser" value="oslab" placeholder="e.g. oslab" required>
    </div>
    <div class="m3-text-field">
      <label for="simApp">Attempted Blocked Application</label>
      <input type="text" id="simApp" value="com.valvesoftware.Steam" placeholder="e.g. com.valvesoftware.Steam" required>
    </div>
  `;

  footer.innerHTML = `
    <button class="m3-button secondary" onclick="closeModal()">Cancel</button>
    <button class="m3-button primary" onclick="submitSimulateViolation()">
      <span class="material-symbols-rounded">warning</span> Record Infraction
    </button>
  `;

  modal.classList.add('show');
}

function submitSimulateViolation() {
  const user = document.getElementById('simUser').value.trim();
  const app = document.getElementById('simApp').value.trim();
  if (!user) return;

  let record = (AppState.violations || []).find(v => v.user === user);
  if (record) {
    record.count++;
    record.lastItem = app;
    record.date = 'Just now';
  } else {
    AppState.violations.push({ user, count: 1, lastItem: app, date: 'Just now' });
  }

  renderViolations();
  updateStats();
  closeModal();
  showToast(`Recorded infraction for '${user}'`, 'warning');
}

// Git Push Trigger via Local Server API
function setupGitPushButton() {
  const btn = document.getElementById('btnGitPush');
  if (!btn) return;

  btn.addEventListener('click', async () => {
    const modal = document.getElementById('customModal');
    const title = document.getElementById('modalTitle');
    const body = document.getElementById('modalBody');
    const footer = document.getElementById('modalFooter');

    title.textContent = 'Commit & Push to GitHub';
    body.innerHTML = `
      <p style="color:var(--md-sys-color-on-surface-variant); font-size:14px; margin-bottom:14px;">
        This will save all active changes to Git and execute <code>git push origin main</code> directly on this system.
      </p>
      <div class="m3-text-field">
        <label for="gitCommitMsg">Commit Message</label>
        <input type="text" id="gitCommitMsg" value="feat: update AD-DMS configurations via Control Center">
      </div>
    `;

    footer.innerHTML = `
      <button class="m3-button secondary" onclick="closeModal()">Cancel</button>
      <button class="m3-button primary" id="btnConfirmGitPush" onclick="executeGitPush()">
        <span class="material-symbols-rounded">cloud_upload</span> Push to Main
      </button>
    `;

    modal.classList.add('show');
  });
}

async function executeGitPush() {
  const msg = document.getElementById('gitCommitMsg')?.value.trim() || 'feat: update policies via Control Center';
  closeModal();
  showToast('Executing: git push origin main...', 'cloud_sync');

  try {
    const res = await fetch('/api/git-push', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ commit_msg: msg })
    });
    const result = await res.json();
    if (result.status === 'ok') {
      showToast('Successfully pushed changes to GitHub repository!', 'cloud_done');
    } else {
      showToast(`Git Error: ${result.output}`, 'error');
    }
  } catch (err) {
    showToast('Failed to connect to local git backend', 'error');
  }
}

// Audio Siren Preview
function setupAudioTest() {
  const btn = document.getElementById('btnTestSiren');
  const audio = document.getElementById('sirenAudio');
  if (!btn || !audio) return;

  btn.addEventListener('click', () => {
    if (audio.paused) {
      audio.volume = 1.0;
      audio.play().then(() => {
        btn.innerHTML = '<span class="material-symbols-rounded">stop_circle</span> <span>Stop Siren</span>';
        showToast('Playing Siren.mp3 at 100% Volume', 'volume_up');
      }).catch(() => {
        showToast('Simulating Siren audio alert playback', 'volume_up');
      });
    } else {
      audio.pause();
      audio.currentTime = 0;
      btn.innerHTML = '<span class="material-symbols-rounded">play_circle</span> <span>Test Audio Playback</span>';
    }
  });
}

// Update Dashboard Statistics
function updateStats() {
  const blockedCount = (AppState.blocked?.dnf?.length || 0) + (AppState.blocked?.flatpak?.length || 0);
  const allowedCount = (AppState.allowed?.dnf?.length || 0) + (AppState.allowed?.flatpak?.length || 0) +
                       (AppState.compulsory?.dnf?.length || 0) + (AppState.compulsory?.flatpak?.length || 0);
  
  document.getElementById('statAllowedCount').textContent = allowedCount;
  document.getElementById('statBlockedCount').textContent = blockedCount;
  document.getElementById('statLabCount').textContent = AppState.labs?.length || 0;

  const totalViolations = (AppState.violations || []).reduce((acc, curr) => acc + curr.count, 0);
  document.getElementById('statViolationCount').textContent = totalViolations;
}

// Modal Helpers
function closeModal() {
  document.getElementById('customModal')?.classList.remove('show');
}

// Toast Notifications
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
  }, 3200);
}

function copyInstallCmd() {
  const cmd = 'curl -fsSL "https://raw.githubusercontent.com/JDKamalakar/fedora-ad-dms/main/install.sh?$(date +%s)" | sudo bash';
  navigator.clipboard.writeText(cmd).then(() => {
    showToast('Deployment command copied to clipboard!', 'content_copy');
  });
}

function capitalize(s) {
  if (!s) return '';
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// Load & Render Historical User Login Audit & Discovered Applications
async function loadAuditLogs(showToastMsg = false) {
  const sessionsBody = document.getElementById('auditSessionsBody');
  const appsBody = document.getElementById('auditAppsBody');
  if (!sessionsBody && !appsBody) return;

  try {
    const res = await fetch('/api/audit');
    if (!res.ok) return;
    const data = await res.json();

    const userSessions = data.user_sessions || [];
    const installedApps = data.installed_apps || [];

    if (sessionsBody) {
      if (userSessions.length === 0) {
        sessionsBody.innerHTML = '<tr><td colspan="7" style="text-align:center; color:var(--md-sys-color-outline);">No user login sessions recorded yet.</td></tr>';
      } else {
        sessionsBody.innerHTML = '';
        userSessions.forEach(s => {
          const tr = document.createElement('tr');
          const isOngoing = (s.duration_mins === 0 || s.status === 'Active');
          tr.innerHTML = `
            <td><strong>${s.hostname || 'UNKNOWN'}</strong></td>
            <td><code>${s.ip || '127.0.0.1'}</code></td>
            <td><span style="font-weight:700; color:var(--md-sys-color-primary);">${s.user || 'unknown'}</span></td>
            <td><code>${s.session_type || 'desktop'}</code></td>
            <td><span style="font-size:12px; color:var(--md-sys-color-on-surface);">${s.login_time || ''}</span></td>
            <td><span style="font-size:12px; color:var(--md-sys-color-outline);">${s.last_seen || ''}</span></td>
            <td>
              <span class="m3-badge ${isOngoing ? 'success' : 'secondary'}">
                ${s.duration_mins > 0 ? s.duration_mins + ' mins' : 'Active (<1m)'}
              </span>
            </td>
          `;
          sessionsBody.appendChild(tr);
        });
      }
    }

    if (appsBody) {
      if (installedApps.length === 0) {
        appsBody.innerHTML = '<tr><td colspan="5" style="text-align:center; color:var(--md-sys-color-outline);">No installed applications discovered yet.</td></tr>';
      } else {
        appsBody.innerHTML = '';
        installedApps.forEach(a => {
          const tr = document.createElement('tr');
          const hostsStr = (a.hosts || []).join(', ') || 'N/A';
          const usersStr = (a.users || []).join(', ') || 'System / All';
          tr.innerHTML = `
            <td><strong>${a.name || ''}</strong></td>
            <td><span class="m3-badge secondary">${(a.kind || 'pkg').toUpperCase()}</span></td>
            <td><span style="font-size:12px; color:var(--md-sys-color-outline);">${a.discovered_on || ''}</span></td>
            <td><code>${hostsStr}</code></td>
            <td><span style="font-weight:600; color:var(--md-sys-color-primary);">${usersStr}</span></td>
          `;
          appsBody.appendChild(tr);
        });
      }
    }

    if (showToastMsg) {
      showToast('Loaded active user login audit history', 'history');
    }
  } catch (err) {
    console.error('Failed to load audit data:', err);
  }
}
