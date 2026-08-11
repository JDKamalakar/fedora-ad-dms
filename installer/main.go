package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

type Config struct {
	DomainName   string
	ADDNSIP      string
	DomainUser   string
	DomainPass   string
	SelectedLab  string
	UpdateSystem bool
}

type LabEntry struct {
	Name    string
	ID      string
	Pattern string
}

type Task struct {
	Title string
	Cmd   string
}

var (
	app           *tview.Application
	pages         *tview.Pages
	config        Config
	labEntries    []LabEntry
	labNameMap    map[string]string
	logFile       *os.File
	scriptDir     string
	logPath       = "/var/log/fedora-ad-setup.log"
	pendingPkgs   int
	tasks         []Task
	taskStates    []string // "pending", "running", "success", "failed"
	statusList    *tview.TextView
	progressBar   *tview.TextView
	logView       *tview.TextView
)

func main() {
	if os.Geteuid() != 0 {
		fmt.Println("Error: This installer must be run as root (use sudo).")
		os.Exit(1)
	}

	// Apply Modern Dark Palette
	tview.Styles.PrimitiveBackgroundColor = tcell.NewRGBColor(24, 24, 37)       // Deep Slate
	tview.Styles.ContrastBackgroundColor = tcell.NewRGBColor(49, 50, 68)        // Surface Gray
	tview.Styles.MoreContrastBackgroundColor = tcell.NewRGBColor(137, 180, 250) // Bright Blue
	tview.Styles.BorderColor = tcell.NewRGBColor(88, 91, 112)                    // Border Gray
	tview.Styles.TitleColor = tcell.NewRGBColor(137, 180, 250)                   // Lavender/Blue
	tview.Styles.PrimaryTextColor = tcell.NewRGBColor(205, 214, 244)            // Off-white
	tview.Styles.SecondaryTextColor = tcell.NewRGBColor(245, 194, 231)          // Soft Pink

	var err error
	logFile, err = os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Printf("Failed to open log file: %v\n", err)
		os.Exit(1)
	}
	defer logFile.Close()

	logWrite(fmt.Sprintf("=== Active Directory & DMS Deployment: %s ===", time.Now().Format(time.RFC1123)))

	ex, err := os.Executable()
	if err == nil {
		scriptDir = filepath.Dir(ex)
	} else {
		scriptDir, _ = os.Getwd()
	}

	loadDomainConfig()
	loadLabConfig()
	pendingPkgs = countPendingUpdates()

	app = tview.NewApplication()
	pages = tview.NewPages()

	pages.AddPage("form", buildConfigForm(), true, true)

	if err := app.SetRoot(pages, true).EnableMouse(true).Run(); err != nil {
		panic(err)
	}
}

func logWrite(msg string) {
	if logFile != nil {
		logFile.WriteString(msg + "\n")
	}
}

// Fixed Domain Config Loader with Comment & Quote Stripping
func loadDomainConfig() {
	config.DomainName = "gsfcu.local"
	config.DomainUser = "Administrator"
	config.UpdateSystem = true

	searchPaths := []string{
		filepath.Join(scriptDir, "domain.conf"),
		filepath.Join(scriptDir, "..", "domain.conf"),
		"/etc/fedora-ad-dms/domain.conf",
	}

	var file *os.File
	var err error
	for _, p := range searchPaths {
		file, err = os.Open(p)
		if err == nil {
			break
		}
	}
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Strip inline comments (# ...)
		if idx := strings.Index(line, "#"); idx != -1 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			val := strings.TrimSpace(parts[1])
			val = strings.Trim(val, `"'`) // Clean quotes
			val = strings.TrimSpace(val)

			switch key {
			case "DOMAIN_NAME":
				config.DomainName = val
			case "AD_DNS_IP":
				config.ADDNSIP = val
			case "DOMAIN_USER":
				config.DomainUser = val
			}
		}
	}
}

func loadLabConfig() {
	labNameMap = make(map[string]string)
	searchPaths := []string{
		filepath.Join(scriptDir, "lab.conf"),
		filepath.Join(scriptDir, "..", "lab.conf"),
	}

	var file *os.File
	var err error
	for _, p := range searchPaths {
		file, err = os.Open(p)
		if err == nil {
			break
		}
	}
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if idx := strings.Index(line, "#"); idx != -1 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		parts := strings.Split(line, ":")
		if len(parts) >= 2 {
			entry := LabEntry{
				Name: strings.TrimSpace(parts[0]),
				ID:   strings.TrimSpace(parts[1]),
			}
			if len(parts) >= 3 {
				entry.Pattern = strings.TrimSpace(parts[2])
			}
			labEntries = append(labEntries, entry)
			labNameMap[entry.ID] = entry.Name
		}
	}
}

func countPendingUpdates() int {
	cmd := exec.Command("dnf", "check-update", "-q")
	output, _ := cmd.Output()
	lines := strings.Split(string(output), "\n")
	count := 0
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "Security:") && len(strings.Fields(line)) >= 3 {
			count++
		}
	}
	return count
}

// --- MODERN FORM UI PAGE ---

func buildConfigForm() tview.Primitive {
	form := tview.NewForm()
	form.SetBorder(true).
		SetTitle(" Fedora AD & DMS Deployment Setup ").
		SetTitleColor(tcell.NewRGBColor(137, 180, 250))

	form.SetFieldBackgroundColor(tcell.NewRGBColor(49, 50, 68))
	form.SetFieldTextColor(tcell.NewRGBColor(205, 214, 244))
	form.SetLabelColor(tcell.NewRGBColor(147, 153, 178))
	form.SetButtonBackgroundColor(tcell.NewRGBColor(137, 180, 250))
	form.SetButtonTextColor(tcell.NewRGBColor(17, 17, 27))
	form.SetButtonActivatedStyle(tcell.StyleDefault.Background(tcell.NewRGBColor(245, 194, 231)).Foreground(tcell.NewRGBColor(17, 17, 27)))

	// Domain Information Fields
	form.AddInputField("Domain Name", config.DomainName, 34, nil, func(text string) { config.DomainName = text })
	form.AddInputField("AD DNS IP", config.ADDNSIP, 34, nil, func(text string) { config.ADDNSIP = text })
	form.AddInputField("Domain Admin User", config.DomainUser, 34, nil, func(text string) { config.DomainUser = text })
	form.AddPasswordField("Domain Admin Password", "", 34, '*', func(text string) { config.DomainPass = text })

	// Explicit Yes/No Dropdown for Package Updates
	updateLabel := fmt.Sprintf("Update System Packages Now? (%d updates pending)", pendingPkgs)
	form.AddDropDown(updateLabel, []string{"Yes (Update system)", "No (Skip updates)"}, 0, func(option string, index int) {
		config.UpdateSystem = (index == 0)
	})

	// Auto-Detect Lab based on Hostname
	hostname, _ := os.Hostname()
	hostUpper := strings.ToUpper(hostname)
	defaultLabIndex := 0
	matchedName := "None"

	labOptions := []string{}
	for i, entry := range labEntries {
		label := fmt.Sprintf("%s (%s)", entry.Name, entry.ID)
		labOptions = append(labOptions, label)

		if entry.Pattern != "" && strings.Contains(hostUpper, strings.ToUpper(entry.Pattern)) {
			defaultLabIndex = i
			matchedName = entry.Name
		}
	}

	if len(labOptions) > 0 {
		config.SelectedLab = labEntries[defaultLabIndex].ID
		dropdownLabel := fmt.Sprintf("Assigned Lab (Matched '%s' -> %s)", hostname, matchedName)
		form.AddDropDown(dropdownLabel, labOptions, defaultLabIndex, func(option string, index int) {
			if index >= 0 && index < len(labEntries) {
				config.SelectedLab = labEntries[index].ID
			}
		})
	}

	// Trigger Action
	startAction := func() {
		if strings.TrimSpace(config.DomainPass) == "" {
			showErrorModal("Domain Admin Password is required!")
			return
		}
		buildTasksList()
		pages.AddPage("execution", buildExecutionPage(), true, true)
		pages.SwitchToPage("execution")
		go runDeploymentTasks()
	}

	form.AddButton("Start Deployment", startAction)
	form.AddButton("Exit", func() { app.Stop() })

	// Instant Hotkeys: Press Ctrl+S or Ctrl+Enter anywhere to submit immediately
	form.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		if event.Key() == tcell.KeyCtrlS || (event.Key() == tcell.KeyEnter && event.Modifiers()&tcell.ModCtrl != 0) {
			startAction()
			return nil
		}
		return event
	})

	// Help Bar Footer
	helpText := tview.NewTextView().
		SetDynamicColors(true).
		SetTextAlign(tview.AlignCenter).
		SetText("[pink]Hotkeys:[white] [bold]Ctrl+S[reset] or [bold]Ctrl+Enter[reset] to Deploy immediately  |  [bold]Tab[reset] Navigate fields")

	// Center Form in Middle of Screen
	centeredFlex := tview.NewFlex().
		AddItem(nil, 0, 1, false).
		AddItem(tview.NewFlex().SetDirection(tview.FlexRow).
			AddItem(nil, 0, 1, false).
			AddItem(form, 20, 1, true).
			AddItem(helpText, 2, 1, false).
			AddItem(nil, 0, 1, false), 82, 1, true).
		AddItem(nil, 0, 1, false)

	return centeredFlex
}

func showErrorModal(msg string) {
	modal := tview.NewModal().
		SetText(msg).
		AddButtons([]string{"OK"}).
		SetDoneFunc(func(buttonIndex int, buttonLabel string) {
			pages.RemovePage("errorModal")
		})
	modal.SetBackgroundColor(tcell.NewRGBColor(69, 71, 90))
	pages.AddPage("errorModal", modal, true, true)
}

// --- EXECUTION DASHBOARD PAGE ---

func buildTasksList() {
	tasks = []Task{
		{"Swapping LibreOffice for ONLYOFFICE", "dnf remove -y 'libreoffice*' && dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm onlyoffice-desktopeditors"},
	}

	if config.UpdateSystem {
		tasks = append(tasks, Task{"Updating System Packages", "dnf update -y"})
	}

	tasks = append(tasks, []Task{
		{"Installing AD & Security Dependencies", "dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit"},
		{"Installing Dank Material Shell (DMS)", "curl -fsSL https://install.danklinux.com -o /tmp/dms-install.sh && chmod 777 /tmp/dms-install.sh && bash /tmp/dms-install.sh; rm -f /tmp/dms-install.sh"},
		{"Configuring DNS & Clock Sync", buildNetworkCmd()},
		{"Joining Active Directory Realm", fmt.Sprintf("echo '%s' | realm join --user='%s' '%s' --verbose", config.DomainPass, config.DomainUser, config.DomainName)},
		{"Applying Lab Access Rules", buildLabAccessCmd()},
		{"Installing Policy Refresh & PAM Hooks", buildPolicySyncCmd()},
		{"Finalizing /etc/skel & System Services", buildFinalizeCmd()},
	}...)

	taskStates = make([]string, len(tasks))
	for i := range taskStates {
		taskStates[i] = "pending"
	}
}

func buildExecutionPage() tview.Primitive {
	statusList = tview.NewTextView().SetDynamicColors(true)
	statusList.SetBorder(true).SetTitle(" Deployment Checklist ").SetTitleColor(tcell.NewRGBColor(137, 180, 250))

	logView = tview.NewTextView().SetDynamicColors(true).SetScrollable(true).SetChangedFunc(func() {
		app.Draw()
	})
	logView.SetBorder(true).SetTitle(" Live Output ").SetTitleColor(tcell.NewRGBColor(166, 227, 161))

	progressBar = tview.NewTextView().SetDynamicColors(true)
	progressBar.SetBorder(true).SetTitle(" Progress ").SetTitleColor(tcell.NewRGBColor(249, 226, 175))

	renderStepList()
	renderProgressBar(0, len(tasks))

	leftPanel := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(statusList, 0, 3, false).
		AddItem(progressBar, 5, 1, false)

	mainFlex := tview.NewFlex().SetDirection(tview.FlexColumn).
		AddItem(leftPanel, 44, 1, false).
		AddItem(logView, 0, 2, true)

	return mainFlex
}

func renderStepList() {
	var sb strings.Builder
	for i, task := range tasks {
		state := taskStates[i]
		switch state {
		case "success":
			sb.WriteString(fmt.Sprintf("[green][✓] Step %d:[white] %s\n", i+1, task.Title))
		case "running":
			sb.WriteString(fmt.Sprintf("[yellow][➜] Step %d:[white] %s\n", i+1, task.Title))
		case "failed":
			sb.WriteString(fmt.Sprintf("[red][✗] Step %d:[white] %s\n", i+1, task.Title))
		default:
			sb.WriteString(fmt.Sprintf("[gray][ ] Step %d: %s[white]\n", i+1, task.Title))
		}
	}
	app.QueueUpdateDraw(func() {
		statusList.SetText(sb.String())
	})
}

func renderProgressBar(completed, total int) {
	width := 24
	pct := 0
	if total > 0 {
		pct = (completed * 100) / total
	}
	filled := (completed * width) / total

	bar := strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
	msg := fmt.Sprintf("\n [dodgerblue][%s][white] %d%% (%d/%d)", bar, pct, completed, total)

	app.QueueUpdateDraw(func() {
		progressBar.SetText(msg)
	})
}

func runDeploymentTasks() {
	total := len(tasks)
	for i, task := range tasks {
		taskStates[i] = "running"
		renderStepList()

		appendLog(fmt.Sprintf("\n[cyan]=== Step %d/%d: %s ===[white]\n", i+1, total, task.Title))

		err := execBashCmd(task.Cmd)
		if err != nil {
			taskStates[i] = "failed"
			appendLog(fmt.Sprintf("[red]ERROR in step '%s': %v[white]\n", task.Title, err))
		} else {
			taskStates[i] = "success"
			appendLog(fmt.Sprintf("[green]SUCCESS: %s complete.[white]\n", task.Title))
		}

		renderStepList()
		renderProgressBar(i+1, total)
	}

	appendLog("\n[gold]===============================================[white]")
	appendLog("[green]Deployment Finished Successfully! Press ENTER to exit.[white]")

	app.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		if event.Key() == tcell.KeyEnter {
			app.Stop()
		}
		return event
	})
}

func appendLog(msg string) {
	logWrite(msg)
	app.QueueUpdateDraw(func() {
		logView.Write([]byte(msg))
		logView.ScrollToEnd()
	})
}

func execBashCmd(cmdStr string) error {
	cmd := exec.Command("bash", "-c", cmdStr)

	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()

	if err := cmd.Start(); err != nil {
		return err
	}

	var wg sync.WaitGroup
	wg.Add(2)

	streamOutput := func(r io.Reader) {
		defer wg.Done()
		scanner := bufio.NewScanner(r)
		for scanner.Scan() {
			text := scanner.Text()
			appendLog(text + "\n")
		}
	}

	go streamOutput(stdout)
	go streamOutput(stderr)

	wg.Wait()
	return cmd.Wait()
}

// --- HELPER COMMAND GENERATORS ---

func buildNetworkCmd() string {
	if config.ADDNSIP == "" {
		return "systemctl enable --now chronyd && chronyc makestep"
	}
	return fmt.Sprintf("nmcli connection modify 'Wired connection 1' ipv4.dns '%s' ipv4.dns-search '%s' ipv4.ignore-auto-dns yes && nmcli connection up 'Wired connection 1' || true; systemctl enable --now chronyd && chronyc makestep", config.ADDNSIP, config.DomainName)
}

func buildLabAccessCmd() string {
	if config.SelectedLab == "" {
		return "echo 'No lab selected.'"
	}
	cmds := []string{fmt.Sprintf("realm permit -g '%s'", config.SelectedLab)}
	for id := range labNameMap {
		if id != config.SelectedLab {
			cmds = append(cmds, fmt.Sprintf("realm deny -g '%s'", id))
		}
	}
	return strings.Join(cmds, " && ")
}

func buildPolicySyncCmd() string {
	parentDir := filepath.Dir(scriptDir)
	return fmt.Sprintf(`
		cp '%s/refresh-app-policies.sh' /usr/local/bin/refresh-app-policies &&
		chmod 755 /usr/local/bin/refresh-app-policies &&
		echo '#!/bin/bash' > /usr/local/bin/refresh &&
		echo 'sudo /usr/local/bin/refresh-app-policies' >> /usr/local/bin/refresh &&
		chmod 755 /usr/local/bin/refresh &&
		if ! grep -q 'refresh-app-policies' /etc/pam.d/postlogin; then
			echo 'session optional pam_exec.so type=open_session /usr/local/bin/refresh-app-policies' >> /etc/pam.d/postlogin
		fi &&
		/usr/local/bin/refresh-app-policies || true
	`, parentDir)
}

func buildFinalizeCmd() string {
	parentDir := filepath.Dir(scriptDir)
	return fmt.Sprintf(`
		authselect select sssd with-mkhomedir --force &&
		systemctl enable --now oddjobd &&
		THEME_ARCHIVE='%s/niri-dms-config.tar.gz' &&
		if [ -f "$THEME_ARCHIVE" ]; then
			mkdir -p /etc/skel/.config /etc/skel/.local/share &&
			tar -xzf "$THEME_ARCHIVE" -C /etc/skel &&
			chmod -R 755 /etc/skel/.config /etc/skel/.local
		fi &&
		mkdir -p /var/cache/dms-greeter && chmod 777 /var/cache/dms-greeter &&
		sss_cache -E || true &&
		systemctl restart sssd oddjobd greetd || true
	`, parentDir)
}