package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// --- ANSI Colors & Formatting ---
const (
	Reset     = "\033[0m"
	Bold      = "\033[1m"
	Dim       = "\033[2m"
	Underline = "\033[4m"

	Red     = "\033[31m"
	Green   = "\033[32m"
	Yellow  = "\033[33m"
	Blue    = "\033[34m"
	Magenta = "\033[35m"
	Cyan    = "\033[36m"
	White   = "\033[37m"

	BgBlue   = "\033[44m"
	BgCyan   = "\033[46m"
	BgGray   = "\033[100m"
	BrightW  = "\033[97m"
)

type Config struct {
	DomainName   string
	ADDNSIP      string
	DomainUser   string
	DomainPass   string
	SelectedLab  string
	LabName      string
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
	config      Config
	labEntries  []LabEntry
	labNameMap  map[string]string
	logFile     *os.File
	scriptDir   string
	logPath     = "/var/log/fedora-ad-setup.log"
	matchedHost string
	matchedLab  string
	matchedID   string
)

func main() {
	if os.Geteuid() != 0 {
		fmt.Printf("%s[!] Error: This installer must be run as root (use sudo).%s\n", Red, Reset)
		os.Exit(1)
	}

	var err error
	logFile, err = os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		fmt.Printf("%s[!] Failed to open log file %s: %v%s\n", Red, logPath, err, Reset)
		os.Exit(1)
	}
	defer logFile.Close()

	logWrite(fmt.Sprintf("=== Active Directory & DMS Deployment: %s ===\n", time.Now().Format(time.RFC1123)))

	ex, err := os.Executable()
	if err == nil {
		scriptDir = filepath.Dir(ex)
	} else {
		scriptDir, _ = os.Getwd()
	}

	loadDomainConfig()
	loadLabConfig()

	clearScreen()
	printBanner()
	promptUserConfig()
	printSummary()

	if !confirmPrompt("\nProceed with deployment?") {
		fmt.Printf("\n%s[!] Deployment cancelled by user.%s\n", Yellow, Reset)
		os.Exit(0)
	}

	clearScreen()
	printBanner()
	runDeployment()
}

func printBanner() {
	fmt.Printf("%s%s", Cyan, Bold)
	fmt.Println(`  ██████╗ ███╗   ███╗███████╗  █████╗ ██████╗ `)
	fmt.Println(`  ██╔══██╗████╗ ████║██╔════╝ ██╔══██╗██╔══██╗`)
	fmt.Println(`  ██║  ██║██╔████╔██║███████╗ ███████║██║  ██║`)
	fmt.Println(`  ██║  ██║██║╚██╔╝██║╚════██║ ██╔══██║██║  ██║`)
	fmt.Println(`  ██████╔╝██║ ╚═╝ ██║███████║ ██║  ██║██████╔╝`)
	fmt.Printf("   %sFedora Active Directory & DMS Deployment Utility%s\n\n", Blue+Bold, Reset)
}

func clearScreen() {
	fmt.Print("\033[H\033[2J")
}

func logWrite(msg string) {
	if logFile != nil {
		logFile.WriteString(msg)
	}
}

func loadDomainConfig() {
	config.DomainName = "gsfcu.local"
	config.DomainUser = "admin"
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
			val = strings.Trim(val, `"'`)
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

func promptInput(promptText, defaultValue string) string {
	fmt.Printf("%s[?] %s [%s%s%s]: ", Cyan, promptText, Green, defaultValue, Reset)
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)
	if input == "" {
		return defaultValue
	}
	return input
}

func promptPassword(promptText string) string {
	for {
		fmt.Printf("%s[?] %s: %s", Cyan, promptText, Reset)
		cmd := exec.Command("stty", "-echo")
		cmd.Stdin = os.Stdin
		cmd.Run()

		reader := bufio.NewReader(os.Stdin)
		pass, _ := reader.ReadString('\n')

		cmd = exec.Command("stty", "echo")
		cmd.Stdin = os.Stdin
		cmd.Run()

		fmt.Println()
		pass = strings.TrimSpace(pass)
		if pass != "" {
			return pass
		}
		fmt.Printf("%s[!] Password cannot be empty! Please try again.%s\n", Red, Reset)
	}
}

func promptUserConfig() {
	hostname, _ := os.Hostname()
	matchedHost = hostname
	matchedLab = "None"
	matchedID = ""
	hostUpper := strings.ToUpper(hostname)
	defaultLabIdx := 0

	for i, entry := range labEntries {
		if entry.Pattern != "" && strings.Contains(hostUpper, strings.ToUpper(entry.Pattern)) {
			defaultLabIdx = i
			matchedLab = entry.Name
			matchedID = entry.ID
			break
		}
	}

	fmt.Printf("%s┌── %sSystem Detection%s\n", Dim, Bold+White, Reset)
	fmt.Printf("%s│%s  Host Name   : %s%s%s\n", Dim, Reset, Yellow, matchedHost, Reset)
	fmt.Printf("%s│%s  Detected Lab: %s%s (%s)%s\n", Dim, Reset, Green, matchedLab, matchedID, Reset)
	fmt.Printf("%s└──%s\n\n", Dim, Reset)

	fmt.Printf("%s%s=== Configuration Prompts ===%s\n", Bold, Blue, Reset)
	config.DomainName = promptInput("Domain Name", config.DomainName)
	config.ADDNSIP = promptInput("AD DNS IP", config.ADDNSIP)
	config.DomainUser = promptInput("Domain Admin User", config.DomainUser)
	config.DomainPass = promptPassword("Domain Admin Password")

	// Select Lab Menu
	if len(labEntries) > 0 {
		fmt.Printf("\n%s[?] Select Assigned Lab:%s\n", Cyan, Reset)
		for i, entry := range labEntries {
			marker := " "
			if i == defaultLabIdx {
				marker = "*"
			}
			fmt.Printf("   %s[%d]%s %s (%s) %s%s%s\n", Yellow, i+1, Reset, entry.Name, entry.ID, Green, marker, Reset)
		}
		labChoiceStr := promptInput("Enter lab option (1-"+strconv.Itoa(len(labEntries))+")", strconv.Itoa(defaultLabIdx+1))
		choiceNum, err := strconv.Atoi(labChoiceStr)
		if err == nil && choiceNum >= 1 && choiceNum <= len(labEntries) {
			config.SelectedLab = labEntries[choiceNum-1].ID
			config.LabName = labEntries[choiceNum-1].Name
		} else {
			config.SelectedLab = labEntries[defaultLabIdx].ID
			config.LabName = labEntries[defaultLabIdx].Name
		}
	}

	// System Updates
	updateChoice := promptInput("Perform Full System Updates? (y/n)", "y")
	config.UpdateSystem = strings.ToLower(updateChoice) == "y" || strings.ToLower(updateChoice) == "yes"
}

func printSummary() {
	fmt.Printf("\n%s%s┌────────────────────────────────────────────────────────┐%s\n", Bold, Cyan, Reset)
	fmt.Printf("%s%s│              Deployment Configuration Summary          │%s\n", Bold, Cyan, Reset)
	fmt.Printf("%s%s├────────────────────────────────────────────────────────┤%s\n", Bold, Cyan, Reset)
	fmt.Printf("%s│ Domain Name   : %s%-38s%s│\n", Cyan, White, config.DomainName, Cyan)
	fmt.Printf("%s│ AD DNS IP     : %s%-38s%s│\n", Cyan, White, config.ADDNSIP, Cyan)
	fmt.Printf("%s│ Domain Admin  : %s%-38s%s│\n", Cyan, White, config.DomainUser, Cyan)
	fmt.Printf("%s│ Assigned Lab  : %s%-38s%s│\n", Cyan, White, fmt.Sprintf("%s (%s)", config.LabName, config.SelectedLab), Cyan)
	updatesTxt := "No (Skip)"
	if config.UpdateSystem {
		updatesTxt = "Yes (Full Update)"
	}
	fmt.Printf("%s│ System Updates: %s%-38s%s│\n", Cyan, White, updatesTxt, Cyan)
	fmt.Printf("%s%s└────────────────────────────────────────────────────────┘%s\n", Bold, Cyan, Reset)
}

func confirmPrompt(promptText string) bool {
	fmt.Printf("%s[?] %s [Y/n]: %s", Yellow, promptText, Reset)
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(strings.ToLower(input))
	return input == "" || input == "y" || input == "yes"
}

func runDeployment() {
	tasks := []Task{
		{"Releasing Package Manager Locks", "systemctl stop packagekit || true; pkill -9 packagekitd || true; pkill -9 dnf || true"},
		{"Swapping LibreOffice for ONLYOFFICE", "dnf remove -y --setopt=lock_timeout=10 'libreoffice*' && dnf install -y --setopt=lock_timeout=10 --nogpgcheck https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm onlyoffice-desktopeditors"},
	}

	if config.UpdateSystem {
		tasks = append(tasks, Task{"Updating System Packages", "dnf update -y --setopt=lock_timeout=10"})
	}

	tasks = append(tasks, []Task{
		{"Installing AD & Security Dependencies", "dnf install -y --setopt=lock_timeout=10 realmd sssd sssd-ad adcli krb5-workstation oddjob oddjob-mkhomedir samba-common-tools bind-utils chrony NetworkManager polkit"},
		{"Installing Dank Material Shell (DMS)", "curl -fsSL --connect-timeout 10 --max-time 60 https://install.danklinux.com -o /tmp/dms-install.sh && chmod 777 /tmp/dms-install.sh && (yes | bash /tmp/dms-install.sh || true); rm -f /tmp/dms-install.sh"},
		{"Configuring DNS & Clock Sync", buildNetworkCmd()},
		{"Joining Active Directory Realm", fmt.Sprintf("echo '%s' | realm join --user='%s' '%s' --verbose", config.DomainPass, config.DomainUser, config.DomainName)},
		{"Applying Lab Access Rules", buildLabAccessCmd()},
		{"Installing Policy Refresh & PAM Hooks", buildPolicySyncCmd()},
		{"Finalizing /etc/skel & System Services", buildFinalizeCmd()},
	}...)

	total := len(tasks)
	fmt.Printf("%s%s=== Starting Deployment (%d Steps) ===%s\n\n", Bold, Green, total, Reset)

	failedSteps := 0

	for i, task := range tasks {
		stepNum := i + 1
		fmt.Printf("%s[➜] Step %d/%d: %s%s\n", Yellow, stepNum, total, task.Title, Reset)
		logWrite(fmt.Sprintf("\n=== Step %d/%d: %s ===\n", stepNum, total, task.Title))

		err := execBashCmdWithLiveOutput(task.Cmd)
		if err != nil {
			failedSteps++
			fmt.Printf("%s[✗] Step %d/%d Failed: %s%s\n\n", Red, stepNum, total, task.Title, Reset)
			logWrite(fmt.Sprintf("[ERROR] Step %d failed: %v\n", stepNum, err))
		} else {
			fmt.Printf("%s[✓] Step %d/%d Completed Successfully.%s\n\n", Green, stepNum, total, Reset)
			logWrite(fmt.Sprintf("[SUCCESS] Step %d complete.\n", stepNum))
		}
	}

	fmt.Printf("%s==================================================%s\n", Cyan, Reset)
	if failedSteps == 0 {
		fmt.Printf("%s%s[✓] Fedora AD & DMS Deployment Finished Successfully!%s\n", Bold, Green, Reset)
	} else {
		fmt.Printf("%s%s[!] Deployment completed with %d warning(s)/error(s). Check %s for details.%s\n", Bold, Yellow, failedSteps, logPath, Reset)
	}
	fmt.Printf("%s==================================================%s\n\n", Cyan, Reset)
}

func execBashCmdWithLiveOutput(cmdStr string) error {
	cmd := exec.Command("bash", "-c", "export DEBIAN_FRONTEND=noninteractive; "+cmdStr)
	cmd.Stdin = strings.NewReader("")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	var wg sync.WaitGroup
	wg.Add(2)

	streamOutput := func(r io.Reader) {
		defer wg.Done()
		scanner := bufio.NewScanner(r)
		for scanner.Scan() {
			line := scanner.Text()
			logWrite(line + "\n")
			fmt.Printf("   %s│%s %s\n", Dim, Reset, line)
		}
	}

	go streamOutput(stdout)
	go streamOutput(stderr)

	wg.Wait()
	return cmd.Wait()
}

func buildNetworkCmd() string {
	if config.ADDNSIP == "" {
		return "systemctl enable --now chronyd && chronyc makestep"
	}
	return fmt.Sprintf(`CONN=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ethernet | head -n1 | cut -d: -f1); if [ -n "$CONN" ]; then nmcli connection modify "$CONN" ipv4.dns '%s' ipv4.dns-search '%s' ipv4.ignore-auto-dns yes && nmcli connection up "$CONN" || true; else nmcli connection modify 'Wired connection 1' ipv4.dns '%s' ipv4.dns-search '%s' ipv4.ignore-auto-dns yes && nmcli connection up 'Wired connection 1' || true; fi; systemctl enable --now chronyd && chronyc makestep`, config.ADDNSIP, config.DomainName, config.ADDNSIP, config.DomainName)
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