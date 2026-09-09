package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ------------------------------------------------------------------------------
// Dynamic DMS Theme — terminal-adaptive colors (no hardcoded dark-only values)
// ------------------------------------------------------------------------------
type DMSTheme struct {
	Primary   lipgloss.AdaptiveColor
	Secondary lipgloss.AdaptiveColor
	Accent    lipgloss.AdaptiveColor
	Warning   lipgloss.AdaptiveColor
	Error     lipgloss.AdaptiveColor
	Border    lipgloss.AdaptiveColor
	Fg        lipgloss.AdaptiveColor
	FgMuted   lipgloss.AdaptiveColor
	Selected  lipgloss.AdaptiveColor
}

func loadDMSTheme() DMSTheme {
	theme := DMSTheme{
		Primary:   lipgloss.AdaptiveColor{Light: "#1565C0", Dark: "#4FC3F7"},
		Secondary: lipgloss.AdaptiveColor{Light: "#1976D2", Dark: "#81D4FA"},
		Accent:    lipgloss.AdaptiveColor{Light: "#2E7D32", Dark: "#69F0AE"},
		Warning:   lipgloss.AdaptiveColor{Light: "#E65100", Dark: "#FFB300"},
		Error:     lipgloss.AdaptiveColor{Light: "#B71C1C", Dark: "#EF5350"},
		Border:    lipgloss.AdaptiveColor{Light: "#1565C0", Dark: "#4FC3F7"},
		Fg:        lipgloss.AdaptiveColor{Light: "#212121", Dark: "#ECEFF1"},
		FgMuted:   lipgloss.AdaptiveColor{Light: "#757575", Dark: "#90A4AE"},
		Selected:  lipgloss.AdaptiveColor{Light: "#00695C", Dark: "#00E676"},
	}

	home, _ := os.UserHomeDir()

	dankCss := filepath.Join(home, ".config", "gtk-3.0", "dank-colors.css")
	if content, err := os.ReadFile(dankCss); err == nil {
		text := string(content)
		if m := regexp.MustCompile(`@define-color\s+accent_color\s+(#[0-9a-fA-F]{6})`).FindStringSubmatch(text); len(m) > 1 {
			c := m[1]
			theme.Primary = lipgloss.AdaptiveColor{Light: c, Dark: c}
			theme.Border = lipgloss.AdaptiveColor{Light: c, Dark: c}
			theme.Selected = lipgloss.AdaptiveColor{Light: c, Dark: c}
		}
		if m := regexp.MustCompile(`@define-color\s+window_fg_color\s+(#[0-9a-fA-F]{6})`).FindStringSubmatch(text); len(m) > 1 {
			c := m[1]
			theme.Fg = lipgloss.AdaptiveColor{Light: c, Dark: c}
		}
	}

	kdlPath := filepath.Join(home, ".config", "niri", "dms", "colors.kdl")
	if content, err := os.ReadFile(kdlPath); err == nil {
		text := string(content)
		if m := regexp.MustCompile(`active-color\s+"(#[0-9a-fA-F]{6})"`).FindStringSubmatch(text); len(m) > 1 {
			c := m[1]
			theme.Primary = lipgloss.AdaptiveColor{Light: c, Dark: c}
			theme.Border = lipgloss.AdaptiveColor{Light: c, Dark: c}
			theme.Selected = lipgloss.AdaptiveColor{Light: c, Dark: c}
		}
		if m := regexp.MustCompile(`urgent-color\s+"(#[0-9a-fA-F]{6})"`).FindStringSubmatch(text); len(m) > 1 {
			c := m[1]
			theme.Error = lipgloss.AdaptiveColor{Light: c, Dark: c}
		}
	}

	return theme
}

// ------------------------------------------------------------------------------
// Step Definitions
// ------------------------------------------------------------------------------
type StepStatus int

const (
	StepPending StepStatus = iota
	StepRunning
	StepDone
	StepFailed
)

type StepInfo struct {
	Title  string
	Status StepStatus
}

// ------------------------------------------------------------------------------
// Messages
// ------------------------------------------------------------------------------
type outputLineMsg string
type syncFinishedMsg struct{ err error }
type tickMsg time.Time

// ------------------------------------------------------------------------------
// Model
// ------------------------------------------------------------------------------
type Model struct {
	width        int
	height       int
	theme        DMSTheme
	steps        []StepInfo
	currentStep  int
	spinnerFrame int
	spinnerChars []string
	logLines     []string
	logOffset    int    // lines scrolled up from tail; 0 = auto-follow
	syncSource   string // "Local File" / "Intranet" / "GitHub"
	done         bool
	err          error
	startTime    time.Time
	elapsed      time.Duration
}

func initialModel() Model {
	// Detect source from last_source file
	src := detectSyncSource()

	steps := []StepInfo{
		{Title: "Policy Configs", Status: StepRunning},
		{Title: "Compulsory Apps", Status: StepPending},
		{Title: "Blocked Apps", Status: StepPending},
		{Title: "Perms & Guards", Status: StepPending},
		{Title: "Group & Lab Apps", Status: StepPending},
		{Title: "Remote Tasks", Status: StepPending},
	}
	return Model{
		width:        90,
		height:       28,
		theme:        loadDMSTheme(),
		steps:        steps,
		spinnerChars: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
		logLines:     []string{"Initializing AD-DMS Policy Synchronization Engine..."},
		syncSource:   src,
		startTime:    time.Now(),
	}
}

func detectSyncSource() string {
	// Check last_source log written by refresh-app-policies.sh
	for _, p := range []string{"/etc/ad-dms/.last_source", "/var/log/ad-dms/.last_source"} {
		if b, err := os.ReadFile(p); err == nil {
			s := strings.TrimSpace(string(b))
			if s != "" {
				return s
			}
		}
	}
	// Probe connectivity to intranet quickly
	if out, err := exec.Command("curl", "-fsSL", "-m", "1",
		"http://GSFCUPLLAB203:8080/api/health").Output(); err == nil && len(out) > 0 {
		return "Intranet (GSFCUPLLAB203)"
	}
	return "Detecting…"
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(tea.EnterAltScreen, tickCmd(), runSyncProcessCmd())
}

func tickCmd() tea.Cmd {
	return tea.Tick(80*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

var processLineChan = make(chan string, 200)
var processErrChan = make(chan error, 1)

func runSyncProcessCmd() tea.Cmd {
	return func() tea.Msg {
		go func() {
			script := "/etc/ad-dms/refresh-app-policies.sh"
			if !fileExists(script) {
				for _, c := range []string{
					"/home/jk/Projects/fedora-ad-dms/config/refresh-app-policies.sh",
					"./config/refresh-app-policies.sh",
				} {
					if fileExists(c) {
						script = c
						break
					}
				}
			}
			cmd := exec.Command("sudo", script)
			cmd.Env = append(os.Environ(), "TERM=xterm-256color")
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				processErrChan <- err
				return
			}
			cmd.Stderr = cmd.Stdout
			if err := cmd.Start(); err != nil {
				processErrChan <- err
				return
			}
			r := bufio.NewReader(stdout)
			for {
				line, err := r.ReadString('\n')
				if len(line) > 0 {
					processLineChan <- strings.TrimRight(line, "\r\n")
				}
				if err != nil {
					break
				}
			}
			processErrChan <- cmd.Wait()
		}()
		return listenNextLine()
	}
}

func listenNextLine() tea.Msg {
	select {
	case l := <-processLineChan:
		return outputLineMsg(l)
	case e := <-processErrChan:
		return syncFinishedMsg{err: e}
	}
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// ------------------------------------------------------------------------------
// Update
// ------------------------------------------------------------------------------
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.MouseMsg:
		if msg.Action == tea.MouseActionPress {
			switch msg.Button {
			case tea.MouseButtonWheelUp:
				m.logOffset += 3
			case tea.MouseButtonWheelDown:
				if m.logOffset > 0 {
					m.logOffset -= 3
					if m.logOffset < 0 {
						m.logOffset = 0
					}
				}
			}
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			return m, tea.Quit
		case "enter":
			if m.done {
				return m, tea.Quit
			}
		case "up", "k":
			m.logOffset += 3
		case "down", "j":
			if m.logOffset > 0 {
				m.logOffset -= 3
				if m.logOffset < 0 {
					m.logOffset = 0
				}
			}
		case "end", "G":
			m.logOffset = 0
		}

	case tickMsg:
		m.spinnerFrame = (m.spinnerFrame + 1) % len(m.spinnerChars)
		if !m.done {
			m.elapsed = time.Since(m.startTime)
		}
		return m, tickCmd()

	case outputLineMsg:
		plain := stripANSI(string(msg))
		m.logLines = append(m.logLines, string(msg))
		if len(m.logLines) > 500 {
			m.logLines = m.logLines[len(m.logLines)-500:]
		}

		// Detect sync source from live output
		if strings.Contains(plain, "Intranet Localhost") || strings.Contains(plain, "127.0.0.1") {
			m.syncSource = "Intranet (local host)"
		} else if strings.Contains(plain, "Intranet") && m.syncSource == "Detecting…" {
			m.syncSource = "Intranet"
		} else if strings.Contains(plain, "GitHub") && m.syncSource == "Detecting…" {
			m.syncSource = "GitHub Fallback"
		} else if strings.Contains(plain, "Local File") && m.syncSource == "Detecting…" {
			m.syncSource = "Local File"
		}

		// Step progression
		switch {
		case strings.Contains(plain, "[REFETCH]") || strings.Contains(plain, "Updating policy engine"):
			m.setStep(0, StepRunning)
		case strings.Contains(plain, "[1/4] Processing compulsory"):
			m.setStep(0, StepDone); m.setStep(1, StepRunning)
		case strings.Contains(plain, "[2/4] Processing blocked"):
			m.setStep(1, StepDone); m.setStep(2, StepRunning)
		case strings.Contains(plain, "[3/4] Processing allowed"):
			m.setStep(2, StepDone); m.setStep(3, StepRunning)
		case strings.Contains(plain, "[4/4] Processing group"):
			m.setStep(3, StepDone); m.setStep(4, StepRunning)
		case strings.Contains(plain, "[5/5] Processing remote"):
			m.setStep(4, StepDone); m.setStep(5, StepRunning)
		case strings.Contains(plain, "ALL SYSTEM & APP POLICIES SYNCHRONIZED"):
			m.setStep(5, StepDone)
		}

		return m, func() tea.Msg { return listenNextLine() }

	case syncFinishedMsg:
		m.done = true
		m.err = msg.err
		if m.err == nil {
			for i := range m.steps {
				m.steps[i].Status = StepDone
			}
		} else if m.currentStep < len(m.steps) {
			m.steps[m.currentStep].Status = StepFailed
		}
	}
	return m, nil
}

func (m *Model) setStep(idx int, status StepStatus) {
	if idx >= 0 && idx < len(m.steps) {
		m.steps[idx].Status = status
		m.currentStep = idx
	}
}

func stripANSI(s string) string {
	return regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`).ReplaceAllString(s, "")
}

func truncate(s string, maxW int) string {
	runes := []rune(s)
	if len(runes) <= maxW {
		return s
	}
	if maxW <= 1 {
		return "…"
	}
	return string(runes[:maxW-1]) + "…"
}

// ------------------------------------------------------------------------------
// View
// ------------------------------------------------------------------------------
func (m Model) View() string {
	// Minimum usable size
	if m.width < 50 || m.height < 8 {
		warn := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Error).
			Padding(1, 2).Align(lipgloss.Center).
			Render(fmt.Sprintf("⚠ TOO SMALL\n%d×%d  need 50×8", m.width, m.height))
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, warn)
	}

	spinner := m.spinnerChars[m.spinnerFrame]
	host, _ := os.Hostname()
	timerStr := fmt.Sprintf("%02d:%02d", int(m.elapsed.Minutes()), int(m.elapsed.Seconds())%60)

	// ── HEADER ─────────────────────────────────────────────────────────────────
	headerInner := lipgloss.JoinVertical(lipgloss.Center,
		lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary).
			Render("🔄  AD-DMS POLICY ENGINE SYNCHRONIZATION"),
		lipgloss.NewStyle().Foreground(m.theme.Secondary).
			Render(fmt.Sprintf("Host: %s  •  %s elapsed", host, timerStr)),
	)
	headerBox := lipgloss.NewStyle().
		Width(m.width - 4).
		Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Border).
		Align(lipgloss.Center).Padding(0, 1).
		Render(headerInner)
	headerH := lipgloss.Height(headerBox)

	// ── FOOTER ─────────────────────────────────────────────────────────────────
	var footerTxt string
	switch {
	case !m.done:
		footerTxt = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Warning).
			Render(fmt.Sprintf("⚡ %s  Synchronizing… do not interrupt.", spinner))
	case m.err != nil:
		footerTxt = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).
			Render(fmt.Sprintf("✖  Error: %v  •  [q] to exit", m.err))
	default:
		footerTxt = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).
			Render("✔  ALL POLICIES SYNCHRONIZED  •  [Enter]/[q] to exit")
	}
	footerBox := lipgloss.NewStyle().
		Width(m.width - 4).
		Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Border).
		Align(lipgloss.Center).Padding(0, 1).
		Render(footerTxt)
	footerH := lipgloss.Height(footerBox)

	// ── BODY HEIGHT ────────────────────────────────────────────────────────────
	bodyH := m.height - headerH - footerH
	if bodyH < 3 {
		bodyH = 3
	}
	innerH := bodyH - 2 // subtract top+bottom border
	if innerH < 1 {
		innerH = 1
	}

	// ── SIDEBAR (left) — steps + source ────────────────────────────────────────
	// Sidebar width: 36 cols (or 32/28 on very narrow terminals) to ensure step titles and IP never truncate
	sideW := 36
	if m.width < 95 {
		sideW = 32
	}
	if m.width < 80 {
		sideW = 28
	}
	// Inner content width = sideW - 2 (border) - 2 (padding)
	contentW := sideW - 4
	if contentW < 10 {
		contentW = 10
	}

	mutedSt := lipgloss.NewStyle().Foreground(m.theme.FgMuted)
	smallSt := lipgloss.NewStyle().Foreground(m.theme.Secondary).Bold(true)

	var sideLines []string

	// Source line above step 1: cleanly split host and IP/target onto next line
	sideLines = append(sideLines, smallSt.Render("SOURCE:"))
	for _, sl := range formatSourceLines(m.syncSource, contentW) {
		sideLines = append(sideLines, mutedSt.Render(sl))
	}
	sideLines = append(sideLines, "") // blank separator before Step 1

	for i, step := range m.steps {
		var icon string
		var labelSt lipgloss.Style
		switch step.Status {
		case StepPending:
			icon = mutedSt.Render("○")
			labelSt = mutedSt
		case StepRunning:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Warning).Render(spinner)
			labelSt = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary)
		case StepDone:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).Render("✔")
			labelSt = lipgloss.NewStyle().Foreground(m.theme.Fg)
		case StepFailed:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).Render("✖")
			labelSt = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error)
		}
		numStr := fmt.Sprintf("[%d/6]", i+1)
		// Available width for title: contentW minus icon(1) minus space(1) minus num(5) minus space(1)
		titleMaxW := contentW - 8
		if titleMaxW < 4 {
			titleMaxW = 4
		}
		title := truncate(step.Title, titleMaxW)
		line := fmt.Sprintf("%s %s %s", icon, mutedSt.Render(numStr), labelSt.Render(title))
		sideLines = append(sideLines, line)
	}

	// Pad to fill innerH
	for len(sideLines) < innerH {
		sideLines = append(sideLines, "")
	}
	// Clip if too tall
	if len(sideLines) > innerH {
		sideLines = sideLines[:innerH]
	}

	sidebarBox := lipgloss.NewStyle().
		Width(sideW).Height(innerH).
		Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Border).
		Padding(0, 1).
		Render(strings.Join(sideLines, "\n"))

	// ── LOG PANEL (right) ─────────────────────────────────────────────────────
	logPanelW := (m.width - 4) - sideW - 1
	if logPanelW < 10 {
		logPanelW = 10
	}
	// logInnerH is the exact number of text lines available for the log viewport
	// (innerH minus 1 line for the "── LIVE TELEMETRY ──" header)
	logInnerH := innerH - 1
	if logInnerH < 1 {
		logInnerH = 1
	}

	// Clamp scroll
	maxOff := len(m.logLines) - logInnerH
	if maxOff < 0 {
		maxOff = 0
	}
	if m.logOffset > maxOff {
		m.logOffset = maxOff
	}
	if m.logOffset < 0 {
		m.logOffset = 0
	}

	endIdx := len(m.logLines) - m.logOffset
	startIdx := endIdx - logInnerH
	if startIdx < 0 {
		startIdx = 0
	}
	if endIdx > len(m.logLines) {
		endIdx = len(m.logLines)
	}
	if endIdx < startIdx {
		endIdx = startIdx
	}

	scrollHint := ""
	if m.logOffset > 0 {
		scrollHint = "  " + lipgloss.NewStyle().Foreground(m.theme.Warning).
			Render(fmt.Sprintf("↑ %d lines up", m.logOffset))
	}
	logTitle := lipgloss.JoinHorizontal(lipgloss.Left,
		lipgloss.NewStyle().Bold(true).Foreground(m.theme.Secondary).Render("── LIVE TELEMETRY ──"),
		scrollHint,
	)

	var visibleLogs []string
	if len(m.logLines) > 0 && startIdx < endIdx {
		visibleLogs = m.logLines[startIdx:endIdx]
	}
	for len(visibleLogs) < logInnerH {
		visibleLogs = append(visibleLogs, "")
	}

	logContent := strings.Join(visibleLogs, "\n")

	logBox := lipgloss.NewStyle().
		Width(logPanelW).Height(innerH).
		Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Border).
		Padding(0, 1).
		Render(lipgloss.JoinVertical(lipgloss.Left, logTitle, logContent))

	// ── ASSEMBLE ───────────────────────────────────────────────────────────────
	bodyRow := lipgloss.JoinHorizontal(lipgloss.Top, sidebarBox, " ", logBox)
	fullUI := lipgloss.JoinVertical(lipgloss.Left, headerBox, bodyRow, footerBox)

	// Place from TOP (not Center) so header never clips on small terminals
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Top, fullUI)
}

func formatSourceLines(src string, maxW int) []string {
	if src == "" || src == "Detecting…" {
		return []string{truncate("⬡ Detecting…", maxW)}
	}
	// Strip trailing timestamps like " - Synced at Tue Sep 8..."
	clean := src
	if idx := strings.Index(clean, " - Synced at"); idx != -1 {
		clean = strings.TrimSpace(clean[:idx])
	} else if idx := strings.Index(clean, " - Synced"); idx != -1 {
		clean = strings.TrimSpace(clean[:idx])
	}

	// If source contains parentheses like "Intranet Host (127.0.0.1:8080)" or "Intranet IP (10.205.18.253:8080)"
	if idx := strings.Index(clean, " ("); idx != -1 {
		mainPart := strings.TrimSpace(clean[:idx])
		subPart := strings.TrimSpace(clean[idx:])
		return []string{
			truncate("⬡ "+mainPart, maxW),
			truncate("  "+subPart, maxW),
		}
	}
	return []string{truncate("⬡ "+clean, maxW)}
}

// ------------------------------------------------------------------------------
// Main & CLI Flag Interceptor
// ------------------------------------------------------------------------------
func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		if args[0] == "-v" || args[0] == "--v" || args[0] == "-version" || args[0] == "--version" {
			fmt.Println("\033[1;36m[AD-DMS REFRESH TUI]\033[0m Version: \033[1;32m2.1.0-fast-ss-responsive\033[0m")
			return
		}
		forwardToBash(args)
		return
	}
	if os.Geteuid() != 0 {
		cmd := exec.Command("sudo", append([]string{os.Args[0]}, args...)...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				os.Exit(exitErr.ExitCode())
			}
			os.Exit(1)
		}
		return
	}
	p := tea.NewProgram(initialModel(), tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func forwardToBash(args []string) {
	flag := args[0]
	if flag == "-v" || flag == "--v" || flag == "-version" || flag == "--version" {
		fmt.Println("\033[1;36m[AD-DMS REFRESH TUI]\033[0m Version: \033[1;32m2.1.0-fast-ss-responsive\033[0m")
		os.Exit(0)
	}
	if flag == "-t" || flag == "--t" || flag == "-time" || flag == "--time" {
		out, err := exec.Command("systemctl", "list-timers", "ad-dms-refresh.timer", "--no-pager").Output()
		if err == nil && strings.Contains(string(out), "ad-dms-refresh.timer") {
			for _, l := range strings.Split(string(out), "\n") {
				if strings.Contains(l, "ad-dms-refresh.timer") {
					f := strings.Fields(l)
					left, next := "unknown", "unknown"
					if len(f) >= 3 {
						left = f[2]
					}
					if len(f) >= 2 {
						next = f[0] + " " + f[1]
					}
					fmt.Printf("\033[1;36m[AD-DMS TIMER]\033[0m Next refresh in: \033[1;32m%s\033[0m (Next: %s)\n", left, next)
					os.Exit(0)
				}
			}
		}
		fmt.Println("\033[1;33m[AD-DMS TIMER]\033[0m ad-dms-refresh.timer is inactive or not installed.")
		os.Exit(0)
	}
	if flag == "-hb" || flag == "--hb" || flag == "-heartbeat" || flag == "--heartbeat" {
		if fileExists("/usr/local/bin/heartbeat") {
			cmd := exec.Command("/usr/local/bin/heartbeat")
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			_ = cmd.Run()
		}
		os.Exit(0)
	}
	shPath := "/etc/ad-dms/refresh-app-policies.sh"
	if !fileExists(shPath) {
		for _, c := range []string{
			"/home/jk/Projects/fedora-ad-dms/config/refresh-app-policies.sh",
			"./config/refresh-app-policies.sh",
		} {
			if fileExists(c) {
				shPath = c
				break
			}
		}
	}
	cmd := exec.Command("bash", append([]string{shPath}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if e, ok := err.(*exec.ExitError); ok {
			os.Exit(e.ExitCode())
		}
		os.Exit(1)
	}
	os.Exit(0)
}
