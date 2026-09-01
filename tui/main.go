package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ANSI System Colors (Adapt dynamically to terminal dark/light themes)
var (
	ColorPrimary   = lipgloss.Color("6")  // System Cyan
	ColorSecondary = lipgloss.Color("4")  // System Blue
	ColorAccent    = lipgloss.Color("2")  // System Green
	ColorWarning   = lipgloss.Color("3")  // System Yellow
	ColorError     = lipgloss.Color("1")  // System Red
	ColorBorder    = lipgloss.Color("6")  // System Cyan Border
	ColorFg        = lipgloss.Color("15") // Bright White
	ColorFgMuted   = lipgloss.Color("7")  // Standard Light Gray/White for readable descriptions
	ColorSelected  = lipgloss.Color("14") // Bright Cyan
)

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
	width          int
	height         int
	view           ViewMode
	cursor         int
	filterCursor   int
	filterMode     string // "all", "active", "inactive"
	clients        []ClientInfo
	labs           []LabDefinition
	statusMsg      string
	repoDir        string
	backupDir      string
	apiURL         string
	menuItems      []MenuItem
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
			if m.view == ViewMain {
				return m, tea.Quit
			}
			m.view = ViewMain
			m.cursor = 0
			return m, nil

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
			if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			maxIndex := len(m.menuItems) - 1
			if m.view == ViewMonitor {
				maxIndex = 2
			} else if m.view == ViewSafeEditor {
				maxIndex = 6
			}
			if m.cursor < maxIndex {
				m.cursor++
			}

		case "1", "2", "3", "4", "5", "6", "7":
			if m.view == ViewMain {
				idx := int(msg.String()[0] - '1')
				return m.handleMainMenuSelect(idx)
			} else if m.view == ViewSafeEditor {
				idx := int(msg.String()[0] - '1')
				return m.handleEditorSelect(idx)
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
// View Renderers (Full Window Responsive Containers)
// ------------------------------------------------------------------------------
func (m Model) View() string {
	contentWidth := m.width - 4
	if contentWidth < 40 {
		contentWidth = 40
	}
	contentHeight := m.height - 4
	if contentHeight < 15 {
		contentHeight = 15
	}

	outerStyle := lipgloss.NewStyle().
		Width(contentWidth).
		Height(contentHeight).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ColorBorder).
		Padding(0, 1)

	var b strings.Builder

	// Top App Header
	hostname, _ := os.Hostname()
	topBar := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorPrimary).
		Render(fmt.Sprintf("🛡️  AD-DMS INTRANET CONTROL & MONITORING"))

	metaBar := lipgloss.NewStyle().
		Foreground(ColorFgMuted).
		Render(fmt.Sprintf("Host: %s | API: %s | %s", hostname, m.apiURL, time.Now().Format("15:04:05")))

	headerBlock := lipgloss.JoinVertical(lipgloss.Left, topBar, metaBar)
	b.WriteString(headerBlock + "\n\n")

	switch m.view {
	case ViewMain:
		b.WriteString(m.renderMainMenu(contentWidth))
	case ViewMonitor:
		b.WriteString(m.renderMonitorView(contentWidth))
	case ViewScreenshot:
		b.WriteString(m.renderScreenshotView(contentWidth))
	case ViewSafeEditor:
		b.WriteString(m.renderSafeEditorView(contentWidth))
	case ViewHistory:
		b.WriteString(m.renderHistoryView(contentWidth))
	case ViewCommand:
		b.WriteString(m.renderCommandView(contentWidth))
	}

	// Bottom Navigation Bar
	footerText := lipgloss.NewStyle().
		Foreground(ColorFgMuted).
		Render("[↑/↓/j/k] Navigate  •  [Enter] Select  •  [r] Refresh  •  [esc/b] Back  •  [q] Quit")

	return outerStyle.Render(lipgloss.JoinVertical(lipgloss.Left, b.String(), "\n"+footerText))
}

func (m Model) renderMainMenu(totalWidth int) string {
	cardWidth := totalWidth - 4
	if cardWidth < 30 {
		cardWidth = 30
	}

	var b strings.Builder
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorPrimary).
		Render("SELECT MANAGEMENT MODULE:")
	b.WriteString(title + "\n\n")

	for i, item := range m.menuItems {
		isSelected := m.cursor == i

		// Container Button Style
		var boxStyle lipgloss.Style
		if isSelected {
			boxStyle = lipgloss.NewStyle().
				Width(cardWidth).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(ColorAccent).
				Padding(0, 1).
				Bold(true)
		} else {
			boxStyle = lipgloss.NewStyle().
				Width(cardWidth).
				Border(lipgloss.NormalBorder()).
				BorderForeground(lipgloss.Color("8")).
				Padding(0, 1)
		}

		icon := item.Icon
		keyBadge := lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorPrimary).
			Render(fmt.Sprintf("[%s]", item.Key))

		nameStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorFg)
		if isSelected {
			nameStyle = nameStyle.Foreground(ColorAccent)
		}
		nameStr := nameStyle.Render(item.Name)

		descStr := lipgloss.NewStyle().
			Foreground(ColorFgMuted).
			Render(item.Desc)

		lineContent := fmt.Sprintf("%s %s %s  -  %s", keyBadge, icon, nameStr, descStr)
		b.WriteString(boxStyle.Render(lineContent) + "\n")
	}

	return b.String()
}

func (m Model) renderMonitorView(totalWidth int) string {
	var b strings.Builder

	filterTitle := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorPrimary).
		Render("FILTER BY WORKSTATION STATUS:")

	b.WriteString(filterTitle + " ")

	filters := []string{"[1] All Devices", "[2] Active Only", "[3] Inactive Only"}
	for i, f := range filters {
		isActiveFilter := (m.filterMode == "all" && i == 0) || (m.filterMode == "active" && i == 1) || (m.filterMode == "inactive" && i == 2)
		if isActiveFilter {
			b.WriteString(lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorAccent).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(ColorAccent).
				Padding(0, 1).
				Render(f) + "  ")
		} else {
			b.WriteString(lipgloss.NewStyle().
				Foreground(ColorFgMuted).
				Render(f) + "  ")
		}
	}
	b.WriteString("\n\n")

	// Table Header
	tblHeader := fmt.Sprintf("┌──────────────────┬─────────────────┬──────────────────────┬─────────────┬─────────────────────┐\n"+
		"│ %-16s │ %-15s │ %-20s │ %-11s │ %-19s │\n"+
		"├──────────────────┼─────────────────┼──────────────────────┼─────────────┼─────────────────────┤",
		"HOSTNAME", "IP ADDRESS", "ACTIVE USER", "STATUS", "LAST SEEN")
	b.WriteString(tblHeader + "\n")

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
			b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(ColorWarning).Render(fmt.Sprintf("│ %-81s│\n", headerStr)))

			for _, c := range labClients {
				totalShown++
				stStr := "ONLINE"
				stStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
				if !c.IsActive {
					stStr = "OFFLINE"
					stStyle = lipgloss.NewStyle().Bold(true).Foreground(ColorError)
				}
				userStr := lipgloss.NewStyle().Foreground(ColorFg).Render(c.ActiveUser)
				row := fmt.Sprintf("│  %-16s│ %-16s│ %-21s│ %-21s│ %-20s│",
					c.Hostname, c.IP, userStr, stStyle.Render(stStr), c.LastSeen)
				b.WriteString(row + "\n")
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
		b.WriteString(lipgloss.NewStyle().Bold(true).Foreground(ColorSecondary).Render("│ ► GENERAL / UNASSIGNED WORKSTATIONS                                             │\n"))
		for _, c := range otherClients {
			totalShown++
			stStr := "ONLINE"
			stStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
			if !c.IsActive {
				stStr = "OFFLINE"
				stStyle = lipgloss.NewStyle().Bold(true).Foreground(ColorError)
			}
			userStr := lipgloss.NewStyle().Foreground(ColorFg).Render(c.ActiveUser)
			row := fmt.Sprintf("│  %-16s│ %-16s│ %-21s│ %-21s│ %-20s│",
				c.Hostname, c.IP, userStr, stStyle.Render(stStr), c.LastSeen)
			b.WriteString(row + "\n")
		}
	}

	if totalShown == 0 {
		b.WriteString(fmt.Sprintf("│  %-78s│\n", lipgloss.NewStyle().Foreground(ColorFgMuted).Render("No matching workstations found in this filter.")))
	}

	b.WriteString("└──────────────────┴─────────────────┴──────────────────────┴─────────────┴─────────────────────┘\n")
	return b.String()
}

func (m Model) renderScreenshotView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(ColorPrimary).Render("INSTANT REMOTE SCREEN CAPTURE:")
	b.WriteString(title + "\n\n")
	b.WriteString("Select a registered workstation to capture its live desktop display:\n\n")

	if len(m.clients) == 0 {
		b.WriteString(lipgloss.NewStyle().Foreground(ColorFgMuted).Render("No active workstations connected to intranet.") + "\n")
	} else {
		for i, c := range m.clients {
			isSelected := m.cursor == i
			boxStyle := lipgloss.NewStyle().
				Width(totalWidth - 6).
				Border(lipgloss.NormalBorder()).
				BorderForeground(lipgloss.Color("8")).
				Padding(0, 1)

			if isSelected {
				boxStyle = boxStyle.BorderForeground(ColorAccent).Bold(true)
			}

			stStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent).Render("ONLINE")
			if !c.IsActive {
				stStyle = lipgloss.NewStyle().Bold(true).Foreground(ColorError).Render("OFFLINE")
			}

			line := fmt.Sprintf("[%d] %-18s  (User: %-15s | IP: %-15s | %s)",
				i+1, c.Hostname, c.ActiveUser, c.IP, stStyle)
			b.WriteString(boxStyle.Render(line) + "\n")
		}
	}
	return b.String()
}

func (m Model) renderSafeEditorView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(ColorPrimary).Render("SAFE CONFIGURATION EDITOR (20-BACKUP / 7-DAY ROTATION ENGINE):")
	b.WriteString(title + "\n\n")

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

	for i, f := range files {
		isSelected := m.cursor == i
		boxStyle := lipgloss.NewStyle().
			Width(totalWidth - 6).
			Border(lipgloss.NormalBorder()).
			BorderForeground(lipgloss.Color("8")).
			Padding(0, 1)

		if isSelected {
			boxStyle = boxStyle.BorderForeground(ColorAccent).Bold(true)
		}

		nameStr := lipgloss.NewStyle().Bold(true).Foreground(ColorFg).Render(f.name)
		if isSelected {
			nameStr = lipgloss.NewStyle().Bold(true).Foreground(ColorAccent).Render(f.name)
		}
		descStr := lipgloss.NewStyle().Foreground(ColorFgMuted).Render(f.desc)

		line := fmt.Sprintf("[%d] %-28s - %s", i+1, nameStr, descStr)
		b.WriteString(boxStyle.Render(line) + "\n")
	}

	return b.String()
}

func (m Model) renderHistoryView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(ColorPrimary).Render("WORKSTATION ENROLLMENT AUDIT LOG:")
	b.WriteString(title + "\n\n")

	if len(m.clients) == 0 {
		b.WriteString(lipgloss.NewStyle().Foreground(ColorFgMuted).Render("No workstation enrollment records yet.") + "\n")
	} else {
		b.WriteString(fmt.Sprintf("  %-18s %-16s %-21s %-21s %s\n", "HOSTNAME", "IP ADDRESS", "FIRST JOINED", "LAST SEEN", "ACTIVE USER"))
		b.WriteString("  " + strings.Repeat("-", 86) + "\n")
		for _, c := range m.clients {
			b.WriteString(fmt.Sprintf("  %-18s %-16s %-21s %-21s %s\n", c.Hostname, c.IP, c.FirstRegistered, c.LastSeen, c.ActiveUser))
		}
	}
	return b.String()
}

func (m Model) renderCommandView(totalWidth int) string {
	var b strings.Builder
	title := lipgloss.NewStyle().Bold(true).Foreground(ColorPrimary).Render("DISPATCH REMOTE COMMAND / TASK:")
	b.WriteString(title + "\n\n")
	b.WriteString("Dispatch administrative commands across single endpoints or entire labs.\n")
	b.WriteString(lipgloss.NewStyle().Foreground(ColorFgMuted).Render("(Scheduled commands execute automatically upon the next client heartbeat poll)") + "\n")
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
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running Go TUI: %v\n", err)
		os.Exit(1)
	}
}
