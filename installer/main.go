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
	DomainName  string
	ADDNSIP     string
	DomainUser  string
	DomainPass  string
	SelectedLab string
}

type LabEntry struct {
	Name    string
	ID      string
	Pattern string
}

var (
	app         *tview.Application
	pages       *tview.Pages
	config      Config
	labEntries  []LabEntry
	labNameMap  map[string]string
	logFile     *os.File
	scriptDir   string
	logPath     = "/var/log/fedora-ad-setup.log"
)

func main() {
	if os.Geteuid() != 0 {
		fmt.Println("Error: This installer must be run as root (use sudo).")
		os.Exit(1)
	}

	// Setup logging
	var err error
	logFile, err = os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Printf("Failed to open log file: %v\n", err)
		os.Exit(1)
	}
	defer logFile.Close()

	logWrite(fmt.Sprintf("=== Active Directory & DMS Setup Started: %s ===", time.Now().Format(time.RFC1123)))

	// Determine directory of execution
	ex, err := os.Executable()
	if err == nil {
		scriptDir = filepath.Dir(ex)
	} else {
		scriptDir, _ = os.Getwd()
	}

	// Load configuration files
	loadLabConfig()
	loadDomainConfig()

	app = tview.NewApplication()
	pages = tview.NewPages()

	// Step 1: Welcome Screen
	pages.AddPage("welcome", buildWelcomePage(), true, true)

	if err := app.SetRoot(pages, true).EnableMouse(true).Run(); err != nil {
		panic(err)
	}
}

func logWrite(msg string) {
	if logFile != nil {
		logFile.WriteString(msg + "\n")
	}
}

// Read domain.conf automatically
func loadDomainConfig() {
	// Defaults
	config.DomainName = "gsfcu.local"
	config.DomainUser = "Administrator"

	confPath := filepath.Join(scriptDir, "..", "domain.conf")
	file, err := os.Open(confPath)
	if err != nil {
		confPath = filepath.Join(scriptDir, "domain.conf")
		file, err = os.Open(confPath)
		if err != nil {
			return
		}
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
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
	confPath := filepath.Join(scriptDir, "..", "lab.conf")
	file, err := os.Open(confPath)
	if err != nil {
		confPath = filepath.Join(scriptDir, "lab.conf")
		file, err = os.Open(confPath)
		if err != nil {
			return
		}
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
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

// --- UI PAGES ---

func buildWelcomePage() tview.Primitive {
	modal := tview.NewModal().
		SetText("Fedora Active Directory & DMS Deployment Wizard\n\nThis utility will configure AD Authentication, Lab Access Rules, Policy Sync, and Desktop Themes.").
		AddButtons([]string{"Start Setup", "Cancel"}).
		SetDoneFunc(func(buttonIndex int, buttonLabel string) {
			if buttonLabel == "Start Setup" {
				pages.AddPage("form", buildConfigForm(), true, true)
				pages.SwitchToPage("form")
			} else {
				app.Stop()
			}
		})
	modal.SetBackgroundColor(tcell.ColorNavy)
	return modal
}

func buildConfigForm() tview.Primitive {
	form := tview.NewForm()
	form.SetBorder(true).SetTitle(" Configuration Settings ").SetTitleColor(tcell.ColorTeal)

	// Form fields pre-filled from domain.conf
	form.AddInputField("Domain Name", config.DomainName, 30, nil, func(text string) { config.DomainName = text })
	form.AddInputField("AD DNS IP", config.ADDNSIP, 30, nil, func(text string) { config.ADDNSIP = text })
	form.AddInputField("Domain Admin User", config.DomainUser, 30, nil, func(text string) { config.DomainUser = text })
	form.AddPasswordField("Domain Admin Password", "", 30, '*', func(text string) { config.DomainPass = text })

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
		dropdownLabel := fmt.Sprintf("Lab Access (Matched Host '%s' -> %s)", hostname, matchedName)
		form.AddDropDown(dropdownLabel, labOptions, defaultLabIndex, func(option string, index int) {
			if index >= 0 && index < len(labEntries) {
				config.SelectedLab = labEntries[index].ID
			}
		})
	}

	form.AddButton("Deploy System", func() {
		if config.DomainPass == "" {
			return
		}
		pages.AddPage("execution", buildExecutionPage(), true, true)
		pages.SwitchToPage("execution")
		go runDeploymentTasks()
	})

	form.AddButton("Cancel", func() { app.Stop() })
	return form
}

var (
	statusView *tview.TextView
	logView    *tview.TextView
)

func buildExecutionPage() tview.Primitive {
	statusView = tview.NewTextView().SetDynamicColors(true).SetRegions(true)
	statusView.SetBorder(true).SetTitle(" Progress Status ").SetTitleColor(tcell.ColorYellow)

	logView = tview.NewTextView().SetDynamicColors(true).SetScrollable(true).SetChangedFunc(func() {
		app.Draw()
	})
	logView.SetBorder(true).SetTitle(" Live Output Terminal ").SetTitleColor(tcell.ColorGreen)

	flex := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(statusView, 6, 1, false).
		AddItem(logView, 0, 3, true)

	return flex
}

// --- DEPLOYMENT ENGINE ---

type Task struct {
	Title string
	Cmd   string
}

func runDeploymentTasks() {
	tasks := []Task{
		{"Swapping LibreOffice for ONLYOFFICE", "dnf remove -y 'libreoffice*' && dnf install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm onlyoffice-desktopeditors"},
		{"Updating System Packages", "dnf update -y"},
		{"Installing AD & Security Dependencies", "dnf install -y realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit"},
		{"Installing Dank Material Shell (DMS)", "curl -fsSL https://install.danklinux.com -o /tmp/dms-install.sh && chmod 777 /tmp/dms-install.sh && bash /tmp/dms-install.sh; rm -f /tmp/dms-install.sh"},
		{"Configuring DNS & Clock Sync", buildNetworkCmd()},
		{"Joining Active Directory Realm", fmt.Sprintf("echo '%s' | realm join --user='%s' '%s' --verbose", config.DomainPass, config.DomainUser, config.DomainName)},
		{"Applying Lab Access Rules", buildLabAccessCmd()},
		{"Installing Policy Refresh & PAM Hooks", buildPolicySyncCmd()},
		{"Finalizing /etc/skel & System Services", buildFinalizeCmd()},
	}

	total := len(tasks)
	for i, task := range tasks {
		stepNum := i + 1
		updateStatus(fmt.Sprintf("[yellow]Executing Step %d/%d:[white] %s...", stepNum, total, task.Title))
		appendLog(fmt.Sprintf("\n[cyan]=== Step %d/%d: %s ===[white]\n", stepNum, total, task.Title))

		err := execBashCmd(task.Cmd)
		if err != nil {
			appendLog(fmt.Sprintf("[red]ERROR during step '%s': %v[white]\n", task.Title, err))
		} else {
			appendLog(fmt.Sprintf("[green]SUCCESS: Step '%s' complete.[white]\n", task.Title))
		}
	}

	updateStatus("[green]Deployment Finished Successfully! Press 'ENTER' to exit.")
	app.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		if event.Key() == tcell.KeyEnter {
			app.Stop()
		}
		return event
	})
}

func updateStatus(msg string) {
	app.QueueUpdateDraw(func() {
		statusView.SetText(msg)
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