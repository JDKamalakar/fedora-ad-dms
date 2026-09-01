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

// Adaptive System / Terminal Colors (Inherits terminal theme: Dark/Light/Custom)
var (
	ColorPrimary   = lipgloss.Color("6")  // Cyan (ANSI 6)
	ColorSecondary = lipgloss.Color("4")  // Blue (ANSI 4)
	ColorAccent    = lipgloss.Color("2")  // Green (ANSI 2)
	ColorSuccess   = lipgloss.Color("2")  // Green (ANSI 2)
	ColorWarning   = lipgloss.Color("3")  // Yellow (ANSI 3)
	ColorError     = lipgloss.Color("1")  // Red (ANSI 1)
	ColorMuted     = lipgloss.Color("8")  // Bright Black / Gray (ANSI 8)
	ColorFg        = lipgloss.Color("7")  // White / Default Foreground (ANSI 7)
	ColorFgDim     = lipgloss.Color("8")  // Dim / Gray (ANSI 8)
	ColorBorder    = lipgloss.Color("6")  // Cyan / System border
)

const (
	Bold   = "\033[1m"
	Dim    = "\033[2m"
	Yellow = "\033[1;33m"
	Blue   = "\033[1;34m"
	Reset  = "\033[0m"
)

// Lipgloss Styles using terminal native backgrounds & colors
var (
	styleBox = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorBorder).
			Padding(1, 2)

	styleTitle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorPrimary).
			MarginBottom(1)

	styleSubTitle = lipgloss.NewStyle().
			Foreground(ColorPrimary).
			Bold(true)

	styleSelected = lipgloss.NewStyle().
			Foreground(ColorAccent).
			Bold(true)

	styleNormal = lipgloss.NewStyle()

	styleDim = lipgloss.NewStyle().
			Foreground(ColorFgDim)

	styleSuccess = lipgloss.NewStyle().
			Foreground(ColorSuccess).
			Bold(true)

	styleError = lipgloss.NewStyle().
			Foreground(ColorError).
			Bold(true)

	styleBadge = lipgloss.NewStyle().
			Foreground(ColorAccent).
			Bold(true)
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
	statusColor    lipgloss.Color
	targetHost     string
	shotStatus     string
	repoDir        string
	backupDir      string
	apiURL         string
	selectedFile   string
	confirmAction  string
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
		view:        ViewMain,
		cursor:      0,
		filterMode:  "all",
		repoDir:     rDir,
		backupDir:   bDir,
		apiURL:      "http://127.0.0.1:8080",
		statusMsg:   "Ready",
		statusColor: ColorAccent,
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

type tickMsg time.Time
type clientsMsg []ClientInfo
type screenshotUploadedMsg string
type errMsg error

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
			// Live Refresh
			m.statusMsg = "Refreshed telemetry"
			m.statusColor = ColorSuccess
			return m, fetchClientsCmd(m.apiURL)

		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			maxIndex := 5
			if m.view == ViewMonitor {
				maxIndex = 3 // 3 filter options
			} else if m.view == ViewSafeEditor {
				maxIndex = 6 // 7 config files
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
		_ = exec.Command("git", "-C", repoDir, "commit", "-m", "feat: update policies via Go TUI").Run()
		_ = exec.Command("git", "-C", repoDir, "push", "origin", "main").Run()
		return nil
	}
}

// ------------------------------------------------------------------------------
// View Renderers
// ------------------------------------------------------------------------------
func (m Model) View() string {
	var b strings.Builder

	// Top Banner / Header Box
	hostname, _ := os.Hostname()
	titleText := fmt.Sprintf("🛡️  AD-DMS INTRANET CONTROL & MONITORING (pVPN Go TUI)")
	subText := fmt.Sprintf("Host: %s | API: %s | %s", hostname, m.apiURL, time.Now().Format("15:04:05"))

	header := lipgloss.JoinVertical(lipgloss.Left,
		styleTitle.Render(titleText),
		styleDim.Render(subText),
	)

	b.WriteString(header + "\n\n")

	switch m.view {
	case ViewMain:
		b.WriteString(m.renderMainMenu())
	case ViewMonitor:
		b.WriteString(m.renderMonitorView())
	case ViewScreenshot:
		b.WriteString(m.renderScreenshotView())
	case ViewSafeEditor:
		b.WriteString(m.renderSafeEditorView())
	case ViewHistory:
		b.WriteString(m.renderHistoryView())
	case ViewCommand:
		b.WriteString(m.renderCommandView())
	}

	// Footer / Hotkey hints
	footer := fmt.Sprintf("\n%s[↑/↓/j/k] Navigate  •  [Enter] Select  •  [r] Refresh  •  [esc/b] Back  •  [q] Quit%s", Dim, Reset)
	b.WriteString(footer)

	return styleBox.Render(b.String())
}

func (m Model) renderMainMenu() string {
	items := []struct {
		icon string
		name string
		desc string
	}{
		{"📊", "Live Device Monitor & Lab Scanner", "Active workstations, current users & online status"},
		{"📸", "Instant Remote Screen Capture", "Grab live desktop view from student machines"},
		{"📝", "Safe Configuration Editor", "Edit domain.conf & policies with 20-backup 7-day rotation"},
		{"⚡", "Execute Remote Lab Command", "Dispatch maintenance tasks across labs"},
		{"📜", "Workstation Connection History", "Full audit log of enrolled machines"},
		{"🔄", "Trigger Policy Sync & Git Push", "Synchronize rules across Intranet & GitHub"},
		{"🚪", "Exit Control Center", "Quit Go TUI"},
	}

	var b strings.Builder
	b.WriteString(styleSubTitle.Render("SELECT MANAGEMENT MODULE:") + "\n\n")

	for i, item := range items {
		cursorStr := "  "
		itemStyle := styleNormal
		if m.cursor == i {
			cursorStr = "► "
			itemStyle = styleSelected
		}

		line := fmt.Sprintf("%s[%d] %s %s  %s(%s)%s",
			cursorStr, i+1, item.icon, itemStyle.Render(item.name), Dim, item.desc, Reset)
		b.WriteString(line + "\n")
	}

	return b.String()
}

func (m Model) renderMonitorView() string {
	var b strings.Builder

	b.WriteString(styleSubTitle.Render("FILTER BY STATUS:") + " ")
	filters := []string{"[1] All Devices", "[2] Active Only", "[3] Inactive Only"}
	for i, f := range filters {
		if (m.filterMode == "all" && i == 0) || (m.filterMode == "active" && i == 1) || (m.filterMode == "inactive" && i == 2) {
			b.WriteString(styleBadge.Render(f) + "  ")
		} else {
			b.WriteString(styleDim.Render(f) + "  ")
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
			b.WriteString(fmt.Sprintf("│ %s%-80s%s│\n", Yellow, headerStr, Reset))

			for _, c := range labClients {
				totalShown++
				stStr := "ONLINE"
				stStyle := styleSuccess
				if !c.IsActive {
					stStr = "OFFLINE"
					stStyle = styleError
				}
				row := fmt.Sprintf("│  %-16s│ %-16s│ %-21s│ %-21s│ %-20s│",
					c.Hostname, c.IP, c.ActiveUser, stStyle.Render(stStr), c.LastSeen)
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
		b.WriteString(fmt.Sprintf("│ %s%-80s%s│\n", Blue, "► GENERAL / UNASSIGNED WORKSTATIONS", Reset))
		for _, c := range otherClients {
			totalShown++
			stStr := "ONLINE"
			stStyle := styleSuccess
			if !c.IsActive {
				stStr = "OFFLINE"
				stStyle = styleError
			}
			row := fmt.Sprintf("│  %-16s│ %-16s│ %-21s│ %-21s│ %-20s│",
				c.Hostname, c.IP, c.ActiveUser, stStyle.Render(stStr), c.LastSeen)
			b.WriteString(row + "\n")
		}
	}

	if totalShown == 0 {
		b.WriteString(fmt.Sprintf("│  %s%-78s%s│\n", Dim, "No matching workstations found in this filter.", Reset))
	}

	b.WriteString("└──────────────────┴─────────────────┴──────────────────────┴─────────────┴─────────────────────┘\n")
	return b.String()
}

func (m Model) renderScreenshotView() string {
	var b strings.Builder
	b.WriteString(styleSubTitle.Render("INSTANT REMOTE SCREEN CAPTURE:") + "\n\n")
	b.WriteString("  Select a registered workstation to capture its current active display:\n\n")

	if len(m.clients) == 0 {
		b.WriteString("  " + styleDim.Render("No active workstations connected to intranet.") + "\n")
	} else {
		for i, c := range m.clients {
			cursorStr := "  "
			itemStyle := styleNormal
			if m.cursor == i {
				cursorStr = "► "
				itemStyle = styleSelected
			}
			statusStr := styleSuccess.Render("ONLINE")
			if !c.IsActive {
				statusStr = styleError.Render("OFFLINE")
			}
			line := fmt.Sprintf("%s[%d] %-18s (User: %-15s | IP: %-15s | %s)",
				cursorStr, i+1, itemStyle.Render(c.Hostname), c.ActiveUser, c.IP, statusStr)
			b.WriteString(line + "\n")
		}
	}
	return b.String()
}

func (m Model) renderSafeEditorView() string {
	var b strings.Builder
	b.WriteString(styleSubTitle.Render("SAFE CONFIGURATION EDITOR (20-BACKUP / 7-DAY ROTATION):") + "\n\n")

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
		cursorStr := "  "
		itemStyle := styleNormal
		if m.cursor == i {
			cursorStr = "► "
			itemStyle = styleSelected
		}
		line := fmt.Sprintf("%s[%d] %-28s %s(%s)%s",
			cursorStr, i+1, itemStyle.Render(f.name), Dim, f.desc, Reset)
		b.WriteString(line + "\n")
	}

	return b.String()
}

func (m Model) renderHistoryView() string {
	var b strings.Builder
	b.WriteString(styleSubTitle.Render("WORKSTATION ENROLLMENT AUDIT LOG:") + "\n\n")

	if len(m.clients) == 0 {
		b.WriteString("  " + styleDim.Render("No workstation enrollment records yet.") + "\n")
	} else {
		b.WriteString(fmt.Sprintf("  %-18s %-16s %-21s %-21s %s\n", "HOSTNAME", "IP ADDRESS", "FIRST JOINED", "LAST SEEN", "ACTIVE USER"))
		b.WriteString("  " + strings.Repeat("-", 86) + "\n")
		for _, c := range m.clients {
			b.WriteString(fmt.Sprintf("  %-18s %-16s %-21s %-21s %s\n", c.Hostname, c.IP, c.FirstRegistered, c.LastSeen, c.ActiveUser))
		}
	}
	return b.String()
}

func (m Model) renderCommandView() string {
	var b strings.Builder
	b.WriteString(styleSubTitle.Render("DISPATCH REMOTE COMMAND / TASK:") + "\n\n")
	b.WriteString("  Dispatch administrative commands across single endpoints or entire labs.\n")
	b.WriteString("  " + styleDim.Render("(Scheduled commands execute automatically upon the next client heartbeat poll)") + "\n")
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
	p := tea.NewProgram(initialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running Go TUI: %v\n", err)
		os.Exit(1)
	}
}
