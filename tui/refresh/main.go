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
	theme := DMSTheme{
		Primary:   lipgloss.Color("#4285F4"),
		Secondary: lipgloss.Color("#1976D2"),
		Accent:    lipgloss.Color("#00C853"),
		Warning:   lipgloss.Color("#FFB300"),
		Error:     lipgloss.Color("#D32F2F"),
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
// Step Definitions
// ------------------------------------------------------------------------------
type StepStatus int

const (
	StepPending StepStatus = iota
	StepRunning
	StepDone
	StepFailed
	StepSkipped
)

type StepInfo struct {
	Title  string
	Detail string
	Status StepStatus
}

// ------------------------------------------------------------------------------
// Bubble Tea Messages
// ------------------------------------------------------------------------------
type outputLineMsg string
type syncFinishedMsg struct {
	err error
}
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
	done         bool
	err          error
	startTime    time.Time
	elapsed      time.Duration
}

func initialModel() Model {
	steps := []StepInfo{
		{Title: "Updating Policy Configs", Detail: "Syncing configuration files from Intranet / GitHub fallback", Status: StepRunning},
		{Title: "Processing Compulsory Apps", Detail: "Verifying and installing baseline mandatory packages", Status: StepPending},
		{Title: "Processing Blocked Software", Detail: "Scanning RPMs, Flatpaks, and applying DNF exclusions", Status: StepPending},
		{Title: "Enforcing Permissions & Guards", Detail: "Deploying Polkit, sudoers, hardware guards & aliases", Status: StepPending},
		{Title: "Applying Group & Lab Apps", Detail: "Evaluating hostname lab pattern rules and group software", Status: StepPending},
		{Title: "Executing Remote Administrative Tasks", Detail: "Running maintenance scripts, timer sync & daemon verify", Status: StepPending},
	}

	return Model{
		width:        90,
		height:       28,
		theme:        loadDMSTheme(),
		steps:        steps,
		currentStep:  0,
		spinnerFrame: 0,
		spinnerChars: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
		logLines:     []string{"Initializing AD-DMS Policy Synchronization Engine..."},
		done:         false,
		startTime:    time.Now(),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		tickCmd(),
		runSyncProcessCmd(),
	)
}

func tickCmd() tea.Cmd {
	return tea.Tick(80*time.Millisecond, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// Channel to stream output lines from the spawned bash process
var processLineChan = make(chan string, 200)
var processErrChan = make(chan error, 1)

func runSyncProcessCmd() tea.Cmd {
	return func() tea.Msg {
		go func() {
			// Find policy engine script
			engineScript := "/etc/ad-dms/refresh-app-policies.sh"
			if !fileExists(engineScript) {
				for _, cand := range []string{
					"/home/jk/Projects/fedora-ad-dms/config/refresh-app-policies.sh",
					"./config/refresh-app-policies.sh",
				} {
					if fileExists(cand) {
						engineScript = cand
						break
					}
				}
			}

			// Pre-fetch configs if needed or run policy refresh script directly
			cmd := exec.Command("sudo", engineScript)
			cmd.Env = append(os.Environ(), "TERM=xterm-256color")

			stdout, err := cmd.StdoutPipe()
			if err != nil {
				processErrChan <- err
				return
			}
			cmd.Stderr = cmd.Stdout // merge stdout and stderr

			if err := cmd.Start(); err != nil {
				processErrChan <- err
				return
			}

			reader := bufio.NewReader(stdout)
			for {
				line, err := reader.ReadString('\n')
				if len(line) > 0 {
					clean := strings.TrimRight(line, "\r\n")
					processLineChan <- clean
				}
				if err != nil {
					break
				}
			}

			cmdErr := cmd.Wait()
			processErrChan <- cmdErr
		}()

		return listenNextLine()
	}
}

func listenNextLine() tea.Msg {
	select {
	case line := <-processLineChan:
		return outputLineMsg(line)
	case err := <-processErrChan:
		return syncFinishedMsg{err: err}
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
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			return m, tea.Quit
		case "enter":
			if m.done {
				return m, tea.Quit
			}
		}

	case tickMsg:
		m.spinnerFrame = (m.spinnerFrame + 1) % len(m.spinnerChars)
		if !m.done {
			m.elapsed = time.Since(m.startTime)
		}
		return m, tickCmd()

	case outputLineMsg:
		line := string(msg)
		plainLine := stripANSI(line)
		m.logLines = append(m.logLines, line)
		if len(m.logLines) > 200 {
			m.logLines = m.logLines[len(m.logLines)-200:]
		}

		// Progress stage recognition
		if strings.Contains(plainLine, "[REFETCH]") || strings.Contains(plainLine, "Updating policy engine") {
			m.setStep(0, StepRunning, "Synchronizing config files from intranet/cloud...")
		} else if strings.Contains(plainLine, "[1/4] Processing compulsory-apps.conf") {
			m.setStep(0, StepDone, "Config files synchronized successfully")
			m.setStep(1, StepRunning, "Verifying mandatory packages & Flatpaks...")
		} else if strings.Contains(plainLine, "[2/4] Processing blocked-apps.conf") {
			m.setStep(1, StepDone, "Mandatory baseline software synchronized")
			m.setStep(2, StepRunning, "Scanning exclusions and purging blocked packages...")
		} else if strings.Contains(plainLine, "[3/4] Processing allowed-apps.conf") {
			m.setStep(2, StepDone, "System exclusions and blacklists applied")
			m.setStep(3, StepRunning, "Configuring Polkit, sudoers, guards & autostart...")
		} else if strings.Contains(plainLine, "[4/4] Processing group-apps.conf") {
			m.setStep(3, StepDone, "Permissions and desktop environments configured")
			m.setStep(4, StepRunning, "Matching hostname to lab software rules...")
		} else if strings.Contains(plainLine, "[5/5] Processing remote tasks") {
			m.setStep(4, StepDone, "Lab group applications synchronized")
			m.setStep(5, StepRunning, "Executing remote administrative maintenance tasks...")
		} else if strings.Contains(plainLine, "ALL SYSTEM & APP POLICIES SYNCHRONIZED") {
			m.setStep(5, StepDone, "All system policies synchronized successfully")
		}

		// Continue listening for next line
		return m, func() tea.Msg {
			return listenNextLine()
		}

	case syncFinishedMsg:
		m.done = true
		m.err = msg.err
		if m.err == nil {
			for i := range m.steps {
				m.steps[i].Status = StepDone
			}
		} else {
			if m.currentStep < len(m.steps) {
				m.steps[m.currentStep].Status = StepFailed
			}
		}
		return m, nil
	}

	return m, nil
}

func (m *Model) setStep(idx int, status StepStatus, detail string) {
	if idx >= 0 && idx < len(m.steps) {
		m.steps[idx].Status = status
		if detail != "" {
			m.steps[idx].Detail = detail
		}
		m.currentStep = idx
	}
}

func stripANSI(str string) string {
	ansiRegex := regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)
	return ansiRegex.ReplaceAllString(str, "")
}

// ------------------------------------------------------------------------------
// View
// ------------------------------------------------------------------------------
func (m Model) View() string {
	minWidth := 74
	minHeight := 20
	if m.width < minWidth || m.height < minHeight {
		warn := lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(m.theme.Error).
			Padding(1, 2).
			Align(lipgloss.Center).
			Render(fmt.Sprintf("⚠️  TERMINAL WINDOW TOO SMALL\n\nSize: %d×%d | Required: %d×%d\nPlease enlarge terminal.", m.width, m.height, minWidth, minHeight))
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, warn)
	}

	boxWidth := m.width - 4
	if boxWidth > 96 {
		boxWidth = 96
	}

	// 1. TOP HEADER
	host, _ := os.Hostname()
	titleText := "🔄  AD-DMS POLICY ENGINE SYNCHRONIZATION"
	timerStr := fmt.Sprintf("Elapsed: %02d:%02d", int(m.elapsed.Minutes()), int(m.elapsed.Seconds())%60)
	metaText := fmt.Sprintf("Host: %s  •  Universal Policy Engine  •  %s", host, timerStr)

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

	// 2. STEP PROGRESSION CARD
	var stepLines []string
	spinner := m.spinnerChars[m.spinnerFrame]

	for i, step := range m.steps {
		var icon string
		var titleStyle lipgloss.Style
		var detailStyle = lipgloss.NewStyle().Foreground(m.theme.FgMuted)

		switch step.Status {
		case StepPending:
			icon = lipgloss.NewStyle().Foreground(m.theme.FgMuted).Render("○")
			titleStyle = lipgloss.NewStyle().Foreground(m.theme.FgMuted)
		case StepRunning:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Warning).Render(spinner)
			titleStyle = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Primary)
			detailStyle = lipgloss.NewStyle().Foreground(m.theme.Selected)
		case StepDone:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).Render("✔")
			titleStyle = lipgloss.NewStyle().Foreground(m.theme.Fg)
		case StepFailed:
			icon = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).Render("✖")
			titleStyle = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error)
		case StepSkipped:
			icon = lipgloss.NewStyle().Foreground(m.theme.Warning).Render("⊘")
			titleStyle = lipgloss.NewStyle().Foreground(m.theme.FgMuted)
		}

		line := fmt.Sprintf(" %s  %s  %s",
			icon,
			titleStyle.Render(fmt.Sprintf("[%d/6] %-34s", i+1, step.Title)),
			detailStyle.Render(step.Detail),
		)
		stepLines = append(stepLines, line)
	}

	stepsBox := lipgloss.NewStyle().
		Width(boxWidth).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Padding(0, 1).
		Render(strings.Join(stepLines, "\n"))

	// 3. LIVE LOG STREAM CARD
	logHeight := m.height - 18
	if logHeight < 5 {
		logHeight = 5
	}

	visibleLogs := m.logLines
	if len(visibleLogs) > logHeight {
		visibleLogs = visibleLogs[len(visibleLogs)-logHeight:]
	}

	logContent := strings.Join(visibleLogs, "\n")
	logTitle := lipgloss.NewStyle().Bold(true).Foreground(m.theme.Secondary).Render("── LIVE ENGINE TELEMETRY OUTPUT ──")

	logBox := lipgloss.NewStyle().
		Width(boxWidth).
		Height(logHeight + 1).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Padding(0, 1).
		Render(lipgloss.JoinVertical(lipgloss.Left, logTitle, logContent))

	// 4. FOOTER STATUS
	var statusMsg string
	if !m.done {
		statusMsg = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Warning).
			Render(fmt.Sprintf("⚡ %s Synchronization in progress... Please do not interrupt.", spinner))
	} else if m.err != nil {
		statusMsg = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Error).
			Render(fmt.Sprintf("✖ Policy Synchronization completed with errors: %v  •  Press [Enter] or [q] to exit", m.err))
	} else {
		statusMsg = lipgloss.NewStyle().Bold(true).Foreground(m.theme.Accent).
			Render("✔ ALL SYSTEM & APP POLICIES SYNCHRONIZED SUCCESSFULLY  •  Press [Enter] or [q] to exit")
	}

	footerBox := lipgloss.NewStyle().
		Width(boxWidth).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(m.theme.Border).
		Align(lipgloss.Center).
		Padding(0, 1).
		Render(statusMsg)

	fullUI := lipgloss.JoinVertical(lipgloss.Center,
		headerBox,
		stepsBox,
		logBox,
		footerBox,
	)

	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, fullUI)
}

// ------------------------------------------------------------------------------
// Main & CLI Flag Interceptor
// ------------------------------------------------------------------------------
func main() {
	args := os.Args[1:]

	// If any CLI flag is provided (e.g. -t, --time, -s, --source, -hb, --heartbeat, -p, --ping),
	// delegate directly to the bash script logic and exit!
	if len(args) > 0 {
		forwardToBash(args)
		return
	}

	// Self-elevate with sudo if not root, while preserving TTY
	if os.Geteuid() != 0 {
		cmd := exec.Command("sudo", append([]string{os.Args[0]}, args...)...)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				os.Exit(exitErr.ExitCode())
			}
			os.Exit(1)
		}
		return
	}

	// Launch Go Bubble Tea TUI
	p := tea.NewProgram(initialModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error launching refresh TUI: %v\n", err)
		os.Exit(1)
	}
}

func forwardToBash(args []string) {
	flag := args[0]
	// If checking timer (-t / --time)
	if flag == "-t" || flag == "--t" || flag == "-time" || flag == "--time" {
		out, err := exec.Command("systemctl", "list-timers", "ad-dms-refresh.timer", "--no-pager").Output()
		if err == nil && strings.Contains(string(out), "ad-dms-refresh.timer") {
			lines := strings.Split(string(out), "\n")
			for _, l := range lines {
				if strings.Contains(l, "ad-dms-refresh.timer") {
					fields := strings.Fields(l)
					leftTime := "unknown"
					nextDate := "unknown"
					if len(fields) >= 3 {
						leftTime = fields[2]
					}
					if len(fields) >= 2 {
						nextDate = fields[0] + " " + fields[1]
					}
					fmt.Printf("\033[1;36m[AD-DMS TIMER]\033[0m Next policy refresh scheduled in: \033[1;32m%s\033[0m (Next run: %s)\n", leftTime, nextDate)
					os.Exit(0)
				}
			}
		}
		fmt.Println("\033[1;33m[AD-DMS TIMER]\033[0m ad-dms-refresh.timer is currently inactive or not installed.")
		os.Exit(0)
	}

	// If checking heartbeat (-hb / --heartbeat)
	if flag == "-hb" || flag == "--hb" || flag == "-heartbeat" || flag == "--heartbeat" {
		if fileExists("/usr/local/bin/heartbeat") {
			cmd := exec.Command("/usr/local/bin/heartbeat")
			cmd.Stdin = os.Stdin
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			_ = cmd.Run()
			os.Exit(0)
		}
	}

	// If -s, --source, -p, --ping or anything else, delegate to the shell UI handler script
	shPath := "/etc/ad-dms/refresh-app-policies.sh"
	if !fileExists(shPath) {
		for _, cand := range []string{
			"/home/jk/Projects/fedora-ad-dms/config/refresh-app-policies.sh",
			"./config/refresh-app-policies.sh",
		} {
			if fileExists(cand) {
				shPath = cand
				break
			}
		}
	}

	cmd := exec.Command("bash", append([]string{shPath}, args...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
	os.Exit(0)
}
