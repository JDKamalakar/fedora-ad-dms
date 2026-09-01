package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ------------------------------------------------------------------------------
// Single Instance Lock using flock
// ------------------------------------------------------------------------------
var lockFile *os.File

func acquireSingleInstanceLock() {
	lockPath := filepath.Join(os.TempDir(), "ad-dms-remote-tui.lock")
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		fmt.Printf("Error creating lock file: %v\n", err)
		os.Exit(1)
	}
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err != nil {
		fmt.Println("⚠️  AD-DMS Remote TUI is already running in another terminal window!")
		fmt.Println("👉 Only one instance of the management console can run at a time.")
		os.Exit(1)
	}
	lockFile = f
}

// ------------------------------------------------------------------------------
// Dynamic DMS / Matugen Theme Parser
// ------------------------------------------------------------------------------
type DMSTheme struct {
	Primary   lipgloss.Color
	Secondary lipgloss.Color
	Accent    lipgloss.Color
	Warning   lipgloss.Color
	Error     lipgloss.Color
	Border    lipgloss.Color
	Bg        lipgloss.Color
	Fg        lipgloss.Color
	FgMuted   lipgloss.Color
	Selected  lipgloss.Color
}

func loadDMSTheme() DMSTheme {
	// Baseline Material You Fallback
	theme := DMSTheme{
		Primary:   lipgloss.Color("#4285F4"), // Google Material Blue
		Secondary: lipgloss.Color("#1976D2"), // Deep Material Blue
		Accent:    lipgloss.Color("#00C853"), // Material Vibrant Green
		Warning:   lipgloss.Color("#FFB300"), // Material Amber
		Error:     lipgloss.Color("#D32F2F"), // Material Crimson Red
		Border:    lipgloss.Color("#4285F4"),
		Bg:        lipgloss.Color("#1A1A2E"),
		Fg:        lipgloss.Color("#FFFFFF"),
		FgMuted:   lipgloss.Color("#9E9E9E"),
		Selected:  lipgloss.Color("#00E676"),
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return theme
	}

	// 1. Inspect ~/.config/gtk-3.0/dank-colors.css for active Matugen scheme
	dankCss := filepath.Join(home, ".config", "gtk-3.0", "dank-colors.css")
	if content, err := os.ReadFile(dankCss); err == nil {
		text := string(content)
		accentRe := regexp.MustCompile(`@define-color\s+accent_color\s+(#[0-9a-fA-F]{6})`)
		if m := accentRe.FindStringSubmatch(text); len(m) > 1 {
			theme.Primary = lipgloss.Color(m[1])
			theme.Border = lipgloss.Color(m[1])
			theme.Selected = lipgloss.Color(m[1])
		}
		bgRe := regexp.MustCompile(`@define-color\s+window_bg_color\s+(#[0-9a-fA-F]{6})`)
		if m := bgRe.FindStringSubmatch(text); len(m) > 1 {
			theme.Bg = lipgloss.Color(m[1])
		}
		fgRe := regexp.MustCompile(`@define-color\s+window_fg_color\s+(#[0-9a-fA-F]{6})`)
		if m := fgRe.FindStringSubmatch(text); len(m) > 1 {
			theme.Fg = lipgloss.Color(m[1])
		}
	}

	// 2. Inspect ~/.config/niri/dms/colors.kdl
	kdlPath := filepath.Join(home, ".config", "niri", "dms", "colors.kdl")
	if content, err := os.ReadFile(kdlPath); err == nil {
		text := string(content)
		activeRe := regexp.MustCompile(`active-color\s+"(#[0-9a-fA-F]{6})"`)
		if m := activeRe.FindStringSubmatch(text); len(m) > 1 {
			theme.Primary = lipgloss.Color(m[1])
			theme.Border = lipgloss.Color(m[1])
			theme.Selected = lipgloss.Color(m[1])
		}
		urgentRe := regexp.MustCompile(`urgent-color\s+"(#[0-9a-fA-F]{6})"`)
		if m := urgentRe.FindStringSubmatch(text); len(m) > 1 {
			theme.Error = lipgloss.Color(m[1])
		}
	}

	return theme
}

// ------------------------------------------------------------------------------
// Data Models
// ------------------------------------------------------------------------------
type ViewMode int

const (
	ViewMain ViewMode = iota
	ViewMonitor
	ViewScreenshot
	ViewSafeEditor
	ViewHistory
	ViewCommand
)

type ClientInfo struct {
	Hostname        string  `json:"hostname"`
	IP              string  `json:"ip"`
	ActiveUser      string  `json:"active_user"`
	SessionType     string  `json:"session_type"`
	Uptime          string  `json:"uptime"`
	DMSVersion      string  `json:"dms_version"`
	LastSeen        string  `json:"last_seen"`
	LastSeenTS      float64 `json:"last_seen_ts"`
	FirstRegistered string  `json:"first_registered"`
	IsActive        bool    `json:"is_active"`
}

type ClientsResponse struct {
	Clients []ClientInfo `json:"clients"`
}

type LabDefinition struct {
	Name   string
	Group  string
	Prefix string
}

type MenuItem struct {
	Icon string
	Name string
	Desc string
	Key  string
}

type Model struct {
	width        int
	height       int
	view         ViewMode
	cursor       int
	filterCursor int
	filterMode   string // "all", "active", "inactive"
	clients      []ClientInfo
	labs         []LabDefinition
	statusMsg    string
	repoDir      string
	backupDir    string
	apiURL       string
	menuItems    []MenuItem
	theme        DMSTheme
}

func initialModel() Model {
	exePath, err := os.Executable()
	rDir := "."
	if err == nil {
		rDir = filepath.Dir(exePath)
		if filepath.Base(rDir) == "tui" {
			rDir = filepath.Dir(rDir)
		}
	}
	home, _ := os.UserHomeDir()
	bDir := filepath.Join(home, ".ad-dms-backups")
	_ = os.MkdirAll(bDir, 0755)

	m := Model{
		view:       ViewMain,
		cursor:     0,
		filterMode: "all",
		repoDir:    rDir,
		backupDir:  bDir,
		apiURL:     "http://127.0.0.1:8080",
		statusMsg:  "System Ready",
		width:      100,
		height:     30,
		theme:      loadDMSTheme(),
		menuItems: []MenuItem{
			{"📊", "Live Workstation Monitor", "Active workstations, logged-in students & real-time telemetry", "1"},
			{"📸", "Instant Screen Capture", "Grab real-time screen frame from any online workstation", "2"},
			{"📝", "Safe Configuration Editor", "Edit domain configs with 20-backup / 7-day retention engine", "3"},
			{"⚡", "Execute Remote Lab Task", "Dispatch maintenance commands across single/all lab endpoints", "4"},
			{"📜", "Workstation Audit History", "Complete enrollment and connection history log", "5"},
			{"🔄", "Sync Policies & Push to Git", "Synchronize configurations across Intranet & GitHub", "6"},
			{"🚪", "Exit Control Center", "Close interactive management console", "7"},
		},
	}
	m.labs = readLabs(m.repoDir)
	return m
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		fetchClientsCmd(m.apiURL),
	)
}

type clientsMsg []ClientInfo

func fetchClientsCmd(apiURL string) tea.Cmd {
	return func() tea.Msg {
		resp, err := http.Get(apiURL + "/api/clients")
		if err != nil {
			return clientsMsg(nil)
		}
		defer resp.Body.Close()

		var cr ClientsResponse
		if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
			return clientsMsg(nil)
		}
		return clientsMsg(cr.Clients)
	}
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case clientsMsg:
		m.clients = msg
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "esc", "b":
			if m.view != ViewMain {
				m.view = ViewMain
				m.cursor = 0
				return m, nil
			}

		case "r":
			m.statusMsg = "Telemetry Refreshed"
			return m, fetchClientsCmd(m.apiURL)

		case "up", "k":
			if m.view == ViewMain || m.view == ViewSafeEditor {
				numCols := 2
				if m.width >= 120 {
					numCols = 3
				}
				if m.cursor >= numCols {
					m.cursor -= numCols
				}
			} else if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			if m.view == ViewMain || m.view == ViewSafeEditor {
				numCols := 2
				if m.width >= 120 {
					numCols = 3
				}
				maxItems := len(m.menuItems)
				if m.view == ViewSafeEditor {
					maxItems = 7
				}
				if m.cursor+numCols < maxItems {
					m.cursor += numCols
				} else if m.cursor < maxItems-1 {
					m.cursor = maxItems - 1
				}
			} else {
				maxIndex := len(m.menuItems) - 1
				if m.view == ViewMonitor {
					maxIndex = 2
				}
				if m.cursor < maxIndex {
					m.cursor++
				}
			}

		case "left", "h":
			if (m.view == ViewMain || m.view == ViewSafeEditor) && m.cursor > 0 {
				m.cursor--
			} else if m.view == ViewMonitor {
				if m.filterMode == "active" {
					m.filterMode = "all"
					return m, fetchClientsCmd(m.apiURL)
				} else if m.filterMode == "inactive" {
					m.filterMode = "active"
					return m, fetchClientsCmd(m.apiURL)
				}
			}

		case "right", "l":
			if m.view == ViewMain && m.cursor < len(m.menuItems)-1 {
				m.cursor++
			} else if m.view == ViewSafeEditor && m.cursor < 6 {
				m.cursor++
			} else if m.view == ViewMonitor {
				if m.filterMode == "all" {
					m.filterMode = "active"
					return m, fetchClientsCmd(m.apiURL)
				} else if m.filterMode == "active" {
					m.filterMode = "inactive"
					return m, fetchClientsCmd(m.apiURL)
				}
			}

		case "1", "2", "3", "4", "5", "6", "7":
			if m.view == ViewMain {
				idx := int(msg.String()[0] - '1')
				return m.handleMainMenuSelect(idx)
			} else if m.view == ViewSafeEditor {
				idx := int(msg.String()[0] - '1')
				return m.handleEditorSelect(idx)
			} else if m.view == ViewMonitor {
				switch msg.String() {
				case "1":
					m.filterMode = "all"
				case "2":
					m.filterMode = "active"
				case "3":
					m.filterMode = "inactive"
				}
				return m, fetchClientsCmd(m.apiURL)
			}

		case "enter":
			if m.view == ViewMain {
				return m.handleMainMenuSelect(m.cursor)
			} else if m.view == ViewMonitor {
				return m.handleMonitorSelect()
			} else if m.view == ViewSafeEditor {
				return m.handleEditorSelect(m.cursor)
			}
		}
	}

	return m, nil
}

func (m Model) handleMainMenuSelect(idx int) (tea.Model, tea.Cmd) {
	if idx < 0 || idx >= len(m.menuItems) {
		return m, nil
	}
	switch idx {
	case 0:
		m.view = ViewMonitor
		m.cursor = 0
		return m, fetchClientsCmd(m.apiURL)
	case 1:
		m.view = ViewScreenshot
		return m, nil
	case 2:
		m.view = ViewSafeEditor
		m.cursor = 0
		return m, nil
	case 3:
		m.view = ViewCommand
		return m, nil
	case 4:
		m.view = ViewHistory
		return m, fetchClientsCmd(m.apiURL)
	case 5:
		return m, triggerGitSync(m.repoDir)
	case 6:
		return m, tea.Quit
	}
	return m, nil
}

func (m Model) handleMonitorSelect() (tea.Model, tea.Cmd) {
	switch m.cursor {
	case 0:
		m.filterMode = "all"
	case 1:
		m.filterMode = "active"
	case 2:
		m.filterMode = "inactive"
	}
	return m, fetchClientsCmd(m.apiURL)
}

func (m Model) handleEditorSelect(idx int) (tea.Model, tea.Cmd) {
	files := []string{
		filepath.Join(m.repoDir, "domain.conf"),
		filepath.Join(m.repoDir, "config", "blocked-apps.conf"),
		filepath.Join(m.repoDir, "config", "allowed-apps.conf"),
		filepath.Join(m.repoDir, "config", "compulsory-apps.conf"),
		filepath.Join(m.repoDir, "config", "group-apps.conf"),
		filepath.Join(m.repoDir, "config", "device-rules.conf"),
		filepath.Join(m.repoDir, "config", "remote-tasks.sh"),
	}

	if idx >= 0 && idx < len(files) {
		target := files[idx]
		createConfigBackup(target, m.backupDir)
		editor := getPreferredEditor()

		c := exec.Command(editor, target)
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return nil
		})
	}
	return m, nil
}

func triggerGitSync(repoDir string) tea.Cmd {
	return func() tea.Msg {
		_ = exec.Command("git", "-C", repoDir, "add", "-A").Run()
		_ = exec.Command("git", "-C", repoDir, "commit", "-m", "feat: update policies via AD-DMS Go TUI").Run()
		_ = exec.Command("git", "-C", repoDir, "push", "origin", "main").Run()
		return nil
	}
}

// ------------------------------------------------------------------------------
// View Renderers: 4 Separate Full-Width Rounded Containers with DMS Theming
// ------------------------------------------------------------------------------
func (m Model) View() string {
	minWidth := 80
	minHeight := 22
	if m.width < minWidth || m.height < minHeight {
		warnBox := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(m.theme.Error).
			Padding(1, 2).
			Align(lipgloss.Center).
			Render(fmt.Sprintf("⚠️  TERMINAL WINDOW TOO SMALL\n\nSize: %d×%d | Required: %d×%d\n\n👉 Please maximize or expand your terminal window.",
				m.width, m.height, minWidth, minHeight))

		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, warnBox)
	}

	boxWidth := m.width - 2
	if boxWidth < 76 {
		boxWidth = 76
	}

	// 1. TOP HEADER BOX (Standalone Rounded Block)
	hostname, _ := os.Hostname()
	titleText := "🛡️  AD-DMS INTRANET CONTROL & MONITORING"
	metaText := fmt.Sprintf("Host: %s  |  API: %s  |  %s", hostname, m.apiURL, time.Now().Format("15:04:05"))
	headerContent := lipgloss.JoinVertical(lipgloss.Center,
		lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary).Render(titleText),
		lipgloss.NewStyle().Foreground(m.theme.Secondary).Render(metaText),
	)
	headerBox := lipgloss.NewStyle().
		Width(boxWidth).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Align(lipgloss.Center).
		Padding(0, 1).
		Render(headerContent)

	// 2. MAIN BODY BOX (Standalone Rounded Block)
	bodyHeight := m.height - 13
	if bodyHeight < 8 {
		bodyHeight = 8
	}

	var bodyInner string
	switch m.view {
	case ViewMain:
		bodyInner = m.renderMainMenu(boxWidth)
	case ViewMonitor:
		bodyInner = m.renderMonitorView(boxWidth)
	case ViewScreenshot:
		bodyInner = m.renderScreenshotView(boxWidth)
	case ViewSafeEditor:
		bodyInner = m.renderSafeEditorView(boxWidth)
	case ViewHistory:
		bodyInner = m.renderHistoryView(boxWidth)
	case ViewCommand:
		bodyInner = m.renderCommandView(boxWidth)
	}

	mainBox := lipgloss.NewStyle().
		Width(boxWidth).
		Height(bodyHeight).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Padding(0, 1).
		Render(bodyInner)

	// 3. DESCRIPTION BOX (Standalone Rounded Block)
	var descText string
	if m.view == ViewMain {
		cur := m.menuItems[m.cursor]
		descText = cur.Desc
	} else if m.view == ViewSafeEditor {
		editorFiles := []struct {
			name string
			desc string
		}{
			{"domain.conf", "Master domain, IP, Timezone, and alert notifications"},
			{"config/blocked-apps.conf", "Blacklisted DNF packages and Flatpaks to auto-remove"},
			{"config/allowed-apps.conf", "Whitelisted applications (passwordless install)"},
			{"config/compulsory-apps.conf", "Mandatory baseline software for all endpoints"},
			{"config/group-apps.conf", "Lab-specific software package mappings"},
			{"config/device-rules.conf", "100% Brightness & 100% Volume enforcement rules"},
			{"config/remote-tasks.sh", "Automated remote execution tasks & scripts"},
		}
		if m.cursor >= 0 && m.cursor < len(editorFiles) {
			f := editorFiles[m.cursor]
			descText = fmt.Sprintf("%s (Auto 20-backup / 7-day retention engine active)", f.desc)
		} else {
			descText = "Auto-creates timestamped backups before editing files"
		}
	} else if m.view == ViewMonitor {
		descText = "Workstation Telemetry: Press [r] to refresh ping status • Active filter is highlighted"
	} else if m.view == ViewScreenshot {
		descText = "Screen Capture: Grabs live display without notifying student and displays on host"
	} else if m.view == ViewHistory {
		descText = "Enrollment Audit: Chronological history of all workstations registered in domain"
	} else {
		descText = "Remote Tasks: Dispatch bash scripts or management tasks across network nodes"
	}

	descBox := lipgloss.NewStyle().
		Width(boxWidth).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Align(lipgloss.Center).
		Padding(0, 1).
		Render(lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true).Render(descText))

	// 4. NAVIGATION / FOOTER BOX (Standalone Rounded Block)
	navText := "[↑/↓/←/→] Navigate   •   [Enter] Select   •   [r] Refresh   •   [esc/b] Back   •   [q] Quit"
	footerBox := lipgloss.NewStyle().
		Width(boxWidth).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Align(lipgloss.Center).
		Padding(0, 1).
		Render(lipgloss.NewStyle().Foreground(m.theme.Secondary).Render(navText))

	// Combine all 4 rounded blocks centered vertically & horizontally
	fullUI := lipgloss.JoinVertical(lipgloss.Center,
		headerBox,
		mainBox,
		descBox,
		footerBox,
	)

	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, fullUI)
}

func (m Model) renderMainMenu(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(m.theme.Primary).
		Render("MODULE SELECTOR")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")

	// Calculate 2 or 3 columns
	numCols := 2
	if totalWidth >= 120 {
		numCols = 3
	}

	// Calculate fixed button width to avoid border distortion
	btnWidth := (totalWidth - 6 - (numCols-1)*2) / numCols
	if btnWidth < 34 {
		btnWidth = 34
	}

	var renderedButtons []string

	for i, item := range m.menuItems {
		isSelected := m.cursor == i

		var btnStyle lipgloss.Style
		if isSelected {
			btnStyle = lipgloss.NewStyle().
				Width(btnWidth).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Accent).
				Bold(true).
				Align(lipgloss.Center)
		} else {
			btnStyle = lipgloss.NewStyle().
				Width(btnWidth).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Border).
				Align(lipgloss.Center)
		}

		keyBadge := lipgloss.NewStyle().Foreground(m.theme.Primary).Bold(true).Render(fmt.Sprintf("[%s]", item.Key))
		var btnContent string
		if isSelected {
			btnName := lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true).Render(item.Name)
			btnContent = fmt.Sprintf("► %s %s %s ◄", keyBadge, item.Icon, btnName)
		} else {
			btnName := lipgloss.NewStyle().Foreground(m.theme.Primary).Render(item.Name)
			btnContent = fmt.Sprintf("%s %s %s", keyBadge, item.Icon, btnName)
		}

		renderedButtons = append(renderedButtons, btnStyle.Render(btnContent))
	}

	// Render buttons in clean rows centered
	for i := 0; i < len(renderedButtons); i += numCols {
		end := i + numCols
		if end > len(renderedButtons) {
			end = len(renderedButtons)
		}

		var rowItems []string
		for j := i; j < end; j++ {
			rowItems = append(rowItems, renderedButtons[j])
			if j < end-1 {
				rowItems = append(rowItems, "  ")
			}
		}
		rowStr := lipgloss.JoinHorizontal(lipgloss.Top, rowItems...)
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(rowStr) + "\n")
	}

	return b.String()
}

func (m Model) renderMonitorView(totalWidth int) string {
	var b strings.Builder

	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(m.theme.Primary).
		Render("WORKSTATION TELEMETRY & LAB MATRIX")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")

	filters := []string{"[1] All Devices", "[2] Active Only", "[3] Inactive Only"}
	var filterBadges []string

	for i, f := range filters {
		isSelected := (m.filterMode == "all" && i == 0) || (m.filterMode == "active" && i == 1) || (m.filterMode == "inactive" && i == 2)
		if isSelected {
			badge := lipgloss.NewStyle().
				Width(24).
				Bold(true).
				Foreground(m.theme.Accent).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Accent).
				Align(lipgloss.Center).
				Render("► " + f + " ◄")
			filterBadges = append(filterBadges, badge)
		} else {
			badge := lipgloss.NewStyle().
				Width(24).
				Foreground(m.theme.Primary).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Border).
				Align(lipgloss.Center).
				Render(f)
			filterBadges = append(filterBadges, badge)
		}
	}

	filterRow := lipgloss.JoinHorizontal(lipgloss.Top, filterBadges[0], "  ", filterBadges[1], "  ", filterBadges[2])
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(filterRow) + "\n\n")

	// Table Header (with Rounded Corners - 97 cols width)
	tblHeader := fmt.Sprintf("╭──────────────────┬─────────────────┬──────────────────────┬─────────────┬─────────────────────╮\n"+
		"│ %-16s │ %-15s │ %-20s │ %-11s │ %-19s │\n"+
		"├──────────────────┼─────────────────┼──────────────────────┼─────────────┼─────────────────────┤",
		"HOSTNAME", "IP ADDRESS", "ACTIVE USER", "STATUS", "LAST SEEN")

	var tableLines []string
	tableLines = append(tableLines, lipgloss.NewStyle().Foreground(m.theme.Primary).Render(tblHeader))

	totalShown := 0
	matchedHosts := make(map[string]bool)

	// Group by Labs
	for _, lab := range m.labs {
		var labClients []ClientInfo
		for _, c := range m.clients {
			if strings.Contains(strings.ToUpper(c.Hostname), strings.ToUpper(lab.Prefix)) {
				if m.filterMode == "active" && !c.IsActive {
					continue
				}
				if m.filterMode == "inactive" && c.IsActive {
					continue
				}
				labClients = append(labClients, c)
				matchedHosts[c.Hostname] = true
			}
		}

		if len(labClients) > 0 {
			headerStr := fmt.Sprintf("► LAB: %s (%s)", lab.Name, lab.Prefix)
			labHeaderLine := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Warning).Render(fmt.Sprintf("│ %-95s │", headerStr))
			tableLines = append(tableLines, labHeaderLine)

			for _, c := range labClients {
				totalShown++
				stStyled := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).Render("ONLINE")
				if !c.IsActive {
					stStyled = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).Render("OFFLINE")
				}
				userStr := lipgloss.NewStyle().Foreground(m.theme.Primary).Render(c.ActiveUser)
				row := fmt.Sprintf("│ %-16s │ %-15s │ %-20s │ %-11s │ %-19s │",
					c.Hostname, c.IP, userStr, stStyled, c.LastSeen)
				tableLines = append(tableLines, row)
			}
		}
	}

	// Unassigned Workstations
	var otherClients []ClientInfo
	for _, c := range m.clients {
		if !matchedHosts[c.Hostname] {
			if m.filterMode == "active" && !c.IsActive {
				continue
			}
			if m.filterMode == "inactive" && c.IsActive {
				continue
			}
			otherClients = append(otherClients, c)
		}
	}

	if len(otherClients) > 0 {
		unassignedLine := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Secondary).Render("│ ► GENERAL / UNASSIGNED WORKSTATIONS                                                           │")
		tableLines = append(tableLines, unassignedLine)
		for _, c := range otherClients {
			totalShown++
			stStyled := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).Render("ONLINE")
			if !c.IsActive {
				stStyled = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).Render("OFFLINE")
			}
			userStr := lipgloss.NewStyle().Foreground(m.theme.Primary).Render(c.ActiveUser)
			row := fmt.Sprintf("│ %-16s │ %-15s │ %-20s │ %-11s │ %-19s │",
				c.Hostname, c.IP, userStr, stStyled, c.LastSeen)
			tableLines = append(tableLines, row)
		}
	}

	if totalShown == 0 {
		emptyRow := fmt.Sprintf("│ %-95s │", "                       No matching workstations found in this filter.")
		tableLines = append(tableLines, emptyRow)
	}

	tblFooter := "╰──────────────────┴─────────────────┴──────────────────────┴─────────────┴─────────────────────╯"
	if totalShown == 0 {
		tblFooter = "╰─────────────────────────────────────────────────────────────────────────────────────────────╯"
	}
	tableLines = append(tableLines, lipgloss.NewStyle().Foreground(m.theme.Primary).Render(tblFooter))

	for _, line := range tableLines {
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(line) + "\n")
	}

	return b.String()
}

func (m Model) renderScreenshotView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary).Render("INSTANT REMOTE SCREEN CAPTURE")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")

	if len(m.clients) == 0 {
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Foreground(m.theme.Primary).Render("No active workstations connected to intranet.") + "\n")
	} else {
		for i, c := range m.clients {
			isSelected := m.cursor == i
			boxStyle := lipgloss.NewStyle().
				Width(totalWidth - 6).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Border).
				Padding(0, 1)

			stStyled := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).Render("ONLINE")
			if !c.IsActive {
				stStyled = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).Render("OFFLINE")
			}

			if isSelected {
				boxStyle = boxStyle.BorderForeground(m.theme.Accent).Bold(true)
			}

			line := fmt.Sprintf("[%d] %-18s  (User: %-15s | IP: %-15s | %s)", i+1, c.Hostname, c.ActiveUser, c.IP, stStyled)
			b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(boxStyle.Render(line)) + "\n")
		}
	}
	return b.String()
}

func (m Model) renderSafeEditorView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(m.theme.Primary).
		Render("SAFE CONFIGURATION EDITOR")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")

	files := []struct {
		name string
		desc string
	}{
		{"domain.conf", "Master domain, IP, Timezone, and alert notifications"},
		{"config/blocked-apps.conf", "Blacklisted DNF packages and Flatpaks to auto-remove"},
		{"config/allowed-apps.conf", "Whitelisted applications (passwordless install)"},
		{"config/compulsory-apps.conf", "Mandatory baseline software for all endpoints"},
		{"config/group-apps.conf", "Lab-specific software package mappings"},
		{"config/device-rules.conf", "100% Brightness & 100% Volume enforcement rules"},
		{"config/remote-tasks.sh", "Automated remote execution tasks & scripts"},
	}

	numCols := 2
	if totalWidth >= 120 {
		numCols = 3
	}

	btnWidth := (totalWidth - 6 - (numCols-1)*2) / numCols
	if btnWidth < 34 {
		btnWidth = 34
	}

	var renderedButtons []string

	for i, f := range files {
		isSelected := m.cursor == i

		var btnStyle lipgloss.Style
		if isSelected {
			btnStyle = lipgloss.NewStyle().
				Width(btnWidth).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Accent).
				Bold(true).
				Align(lipgloss.Center)
		} else {
			btnStyle = lipgloss.NewStyle().
				Width(btnWidth).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(m.theme.Border).
				Align(lipgloss.Center)
		}

		keyBadge := lipgloss.NewStyle().Foreground(m.theme.Primary).Bold(true).Render(fmt.Sprintf("[%d]", i+1))
		var btnContent string
		if isSelected {
			btnName := lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true).Render(f.name)
			btnContent = fmt.Sprintf("► %s %s ◄", keyBadge, btnName)
		} else {
			btnName := lipgloss.NewStyle().Foreground(m.theme.Primary).Render(f.name)
			btnContent = fmt.Sprintf("%s %s", keyBadge, btnName)
		}

		renderedButtons = append(renderedButtons, btnStyle.Render(btnContent))
	}

	for i := 0; i < len(renderedButtons); i += numCols {
		end := i + numCols
		if end > len(renderedButtons) {
			end = len(renderedButtons)
		}

		var rowItems []string
		for j := i; j < end; j++ {
			rowItems = append(rowItems, renderedButtons[j])
			if j < end-1 {
				rowItems = append(rowItems, "  ")
			}
		}
		rowStr := lipgloss.JoinHorizontal(lipgloss.Top, rowItems...)
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(rowStr) + "\n")
	}

	return b.String()
}

func (m Model) renderHistoryView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary).Render("WORKSTATION ENROLLMENT AUDIT LOG")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")

	if len(m.clients) == 0 {
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Foreground(m.theme.Primary).Render("No workstation enrollment records yet.") + "\n")
	} else {
		headerLine := fmt.Sprintf("  %-18s %-16s %-21s %-21s %s", "HOSTNAME", "IP ADDRESS", "FIRST JOINED", "LAST SEEN", "ACTIVE USER")
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Bold(true).Foreground(m.theme.Primary).Render(headerLine) + "\n")
		b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(strings.Repeat("-", 86)) + "\n")
		for _, c := range m.clients {
			row := fmt.Sprintf("  %-18s %-16s %-21s %-21s %s", c.Hostname, c.IP, c.FirstRegistered, c.LastSeen, c.ActiveUser)
			b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Foreground(m.theme.Primary).Render(row) + "\n")
		}
	}
	return b.String()
}

func (m Model) renderCommandView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary).Render("DISPATCH REMOTE COMMAND / TASK")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Render(title) + "\n\n")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Foreground(m.theme.Primary).Render("Dispatch administrative commands across single endpoints or entire labs.") + "\n")
	b.WriteString(lipgloss.NewStyle().Width(totalWidth).Align(lipgloss.Center).Foreground(m.theme.Warning).Render("(Scheduled commands execute automatically upon the next client heartbeat poll)") + "\n")
	return b.String()
}

// ------------------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------------------
func getPreferredEditor() string {
	editor := os.Getenv("EDITOR")
	if editor != "" {
		return editor
	}
	for _, cand := range []string{"nano", "micro", "vim", "vi"} {
		if _, err := exec.LookPath(cand); err == nil {
			return cand
		}
	}
	return "vi"
}

func createConfigBackup(filePath, backupDir string) {
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		return
	}
	base := filepath.Base(filePath)
	ts := time.Now().Format("20060102_150405")
	dest := filepath.Join(backupDir, fmt.Sprintf("%s.%s.bak", base, ts))

	input, err := os.ReadFile(filePath)
	if err != nil {
		return
	}
	_ = os.WriteFile(dest, input, 0644)
	pruneBackups(base, backupDir)
}

func pruneBackups(baseName, backupDir string) {
	entries, err := os.ReadDir(backupDir)
	if err != nil {
		return
	}

	type fileEntry struct {
		path    string
		modTime time.Time
	}
	var baks []fileEntry
	prefix := baseName + "."
	suffix := ".bak"

	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), prefix) && strings.HasSuffix(e.Name(), suffix) {
			info, _ := e.Info()
			baks = append(baks, fileEntry{
				path:    filepath.Join(backupDir, e.Name()),
				modTime: info.ModTime(),
			})
		}
	}

	sort.Slice(baks, func(i, j int) bool {
		return baks[i].modTime.After(baks[j].modTime)
	})

	now := time.Now()
	for i, b := range baks {
		ageDays := now.Sub(b.modTime).Hours() / 24
		if ageDays > 15 {
			if i >= 3 {
				os.Remove(b.path)
			}
		} else if i >= 20 {
			os.Remove(b.path)
		}
	}
}

func readLabs(repoDir string) []LabDefinition {
	var labs []LabDefinition
	labFile := filepath.Join(repoDir, "lab.conf")
	f, err := os.Open(labFile)
	if err != nil {
		return labs
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, ":") {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) >= 3 {
			labs = append(labs, LabDefinition{
				Name:   strings.TrimSpace(parts[0]),
				Group:  strings.TrimSpace(parts[1]),
				Prefix: strings.TrimSpace(parts[2]),
			})
		}
	}
	return labs
}

func main() {
	acquireSingleInstanceLock()
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running Go TUI: %v\n", err)
		os.Exit(1)
	}
}
