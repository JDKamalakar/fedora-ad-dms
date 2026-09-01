package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ANSI Styling Tokens matching pVPN TUI aesthetic
const (
	Bold      = "\033[1m"
	Dim       = "\033[2m"
	Cyan      = "\033[1;36m"
	Green     = "\033[1;32m"
	Yellow    = "\033[1;33m"
	Red       = "\033[1;31m"
	Magenta   = "\033[1;35m"
	Blue      = "\033[1;34m"
	White     = "\033[1;37m"
	Reset     = "\033[0m"
	ClearScreen = "\033[2J\033[H"
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

var (
	repoDir   string
	backupDir string
	apiURL    = "http://127.0.0.1:8080"
)

func init() {
	exePath, err := os.Executable()
	if err != nil {
		repoDir = "."
	} else {
		repoDir = filepath.Dir(exePath)
		// If binary is inside tui/, step up to repo root
		if filepath.Base(repoDir) == "tui" {
			repoDir = filepath.Dir(repoDir)
		}
	}
	home, _ := os.UserHomeDir()
	backupDir = filepath.Join(home, ".ad-dms-backups")
	os.MkdirAll(backupDir, 0755)
}

func clear() {
	fmt.Print(ClearScreen)
}

func drawHeader() {
	clear()
	hostname, _ := os.Hostname()
	t := time.Now().Format("2006-01-02 15:04:05")
	fmt.Printf("%s╔════════════════════════════════════════════════════════════════════════════════════╗%s\n", Cyan, Reset)
	fmt.Printf("%s║%s   %s%s🛡️  AD-DMS INTRANET CONTROL & MONITORING (GO ENGINE)%s  %s(Host: %s)%s             %s║%s\n", Cyan, Reset, Bold, Magenta, Reset, Dim, hostname, Reset, Cyan, Reset)
	fmt.Printf("%s╠════════════════════════════════════════════════════════════════════════════════════╣%s\n", Cyan, Reset)
	fmt.Printf("%s║%s  %sLocal API:%s %s%s%s   %s|%s   %sTime:%s %s%s%s                     %s║%s\n", Cyan, Reset, White, Reset, Green, apiURL, Reset, Dim, Reset, White, Reset, Yellow, t, Reset, Cyan, Reset)
	fmt.Printf("%s╚════════════════════════════════════════════════════════════════════════════════════╝%s\n\n", Cyan, Reset)
}

func ensureBackendRunning() {
	resp, err := http.Get(apiURL + "/api/all-data")
	if err != nil || resp.StatusCode != 200 {
		fmt.Printf("  -> %s[STARTING BACKEND]%s Launching background Intranet API server...\n", Yellow, Reset)
		cmd := exec.Command("python3", filepath.Join(repoDir, "web_server.py"))
		cmd.Dir = repoDir
		_ = cmd.Start()
		time.Sleep(1 * time.Second)
	}
}

// ------------------------------------------------------------------------------
// Backup Engine (Max 20 over 7 days, keep last 3 if >15 days)
// ------------------------------------------------------------------------------
func createConfigBackup(filePath string) {
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
	pruneBackups(base)
}

func pruneBackups(baseName string) {
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

func readLabs() []LabDefinition {
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

func fetchClients() []ClientInfo {
	resp, err := http.Get(apiURL + "/api/clients")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	var cr ClientsResponse
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return nil
	}
	return cr.Clients
}

// ------------------------------------------------------------------------------
// Main UI Flow
// ------------------------------------------------------------------------------
func main() {
	ensureBackendRunning()
	reader := bufio.NewReader(os.Stdin)

	for {
		drawHeader()
		fmt.Printf("  %s%sSelect a Management Mode:%s\n\n", Bold, White, Reset)
		fmt.Printf("    %s[1]%s 📊 %sLive Device Monitor & Telemetry Scanner%s  %s(Active labs, users & ping)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[2]%s 📸 %sInstant Remote Screen Capture%s            %s(Grab student/workstation screen)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[3]%s 📝 %sSafe Configuration Editor%s                %s(domain.conf, blocked/allowed apps)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[4]%s ⚡ %sExecute Remote Lab Command%s               %s(Run tasks on single or all labs)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[5]%s 📜 %sWorkstation Connection History%s          %s(Joined devices audit log)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[6]%s 🔄 %sTrigger Global Policy Sync & Git Push%s   %s(Push latest policies)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[7]%s 🚪 %sExit Control Center%s\n\n", Cyan, Reset, Bold, Reset)

		fmt.Print("  Enter selection [1-7]: ")
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)

		switch choice {
		case "1":
			deviceMonitorMenu(reader)
		case "2":
			remoteScreenshotMenu(reader)
		case "3":
			safeConfigEditorMenu(reader)
		case "4":
			remoteExecMenu(reader)
		case "5":
			connectionHistoryMenu(reader)
		case "6":
			triggerSyncPush(reader)
		case "7", "q", "Q":
			fmt.Printf("\n  %sGoodbye!%s\n\n", Green, Reset)
			os.Exit(0)
		}
	}
}

// ------------------------------------------------------------------------------
// Device Monitor Views
// ------------------------------------------------------------------------------
func deviceMonitorMenu(reader *bufio.Reader) {
	for {
		drawHeader()
		fmt.Printf("  %s%sSelect Device Filter:%s\n\n", Bold, White, Reset)
		fmt.Printf("    %s[1]%s 🌐 Show ALL Registered Devices\n", Cyan, Reset)
		fmt.Printf("    %s[2]%s 🟢 Show ACTIVE (Online) Devices Only\n", Cyan, Reset)
		fmt.Printf("    %s[3]%s 🔴 Show INACTIVE (Offline) Devices Only\n", Cyan, Reset)
		fmt.Printf("    %s[4]%s ↩️  Back to Main Menu\n\n", Cyan, Reset)

		fmt.Print("  Select filter [1-4]: ")
		fchoice, _ := reader.ReadString('\n')
		fchoice = strings.TrimSpace(fchoice)

		switch fchoice {
		case "1":
			viewDevicesByLab("all", reader)
		case "2":
			viewDevicesByLab("active", reader)
		case "3":
			viewDevicesByLab("inactive", reader)
		case "4":
			return
		}
	}
}

func viewDevicesByLab(filter string, reader *bufio.Reader) {
	labs := readLabs()

	for {
		drawHeader()
		fmt.Printf("  %s%s=== INTRANET WORKSTATIONS MONITOR (Filter: %s) ===%s\n", Bold, Cyan, strings.ToUpper(filter), Reset)
		fmt.Printf("  %sPress [r] to Refresh, [s] to Screenshot a host, [c] for Remote Command, [b] to Back%s\n\n", Dim, Reset)

		clients := fetchClients()

		fmt.Println("  ┌──────────────────┬─────────────────┬──────────────────────┬─────────────┬─────────────────────┐")
		fmt.Printf("  │ %s%-16s%s│ %s%-15s%s│ %s%-20s%s│ %s%-11s%s│ %s%-19s%s│\n", Bold, "HOSTNAME", Reset, Bold, "IP ADDRESS", Reset, Bold, "ACTIVE USER", Reset, Bold, "STATUS", Reset, Bold, "LAST SEEN", Reset)
		fmt.Println("  ├──────────────────┼─────────────────┼──────────────────────┼─────────────┼─────────────────────┤")

		totalShown := 0
		matchedHosts := make(map[string]bool)

		// Display grouped by Lab
		for _, lab := range labs {
			var labClients []ClientInfo
			for _, c := range clients {
				if strings.Contains(strings.ToUpper(c.Hostname), strings.ToUpper(lab.Prefix)) {
					if filter == "active" && !c.IsActive {
						continue
					}
					if filter == "inactive" && c.IsActive {
						continue
					}
					labClients = append(labClients, c)
					matchedHosts[c.Hostname] = true
				}
			}

			if len(labClients) > 0 {
				headerStr := fmt.Sprintf("► LAB: %s (%s)", lab.Name, lab.Prefix)
				fmt.Printf("  │ %s%s%-80s%s│\n", Bold, Yellow, headerStr, Reset)

				for _, c := range labClients {
					totalShown++
					stStr := "ONLINE"
					stColor := Green
					if !c.IsActive {
						stStr = "OFFLINE"
						stColor = Red
					}
					fmt.Printf("  │  %-16s│ %-16s│ %-21s│ %s%-12s%s│ %-20s│\n", c.Hostname, c.IP, c.ActiveUser, stColor, stStr, Reset, c.LastSeen)
				}
			}
		}

		// Display Unassigned / Other Workstations
		var otherClients []ClientInfo
		for _, c := range clients {
			if !matchedHosts[c.Hostname] {
				if filter == "active" && !c.IsActive {
					continue
				}
				if filter == "inactive" && c.IsActive {
					continue
				}
				otherClients = append(otherClients, c)
			}
		}

		if len(otherClients) > 0 {
			fmt.Printf("  │ %s%s%-80s%s│\n", Bold, Blue, "► GENERAL / UNASSIGNED WORKSTATIONS", Reset)
			for _, c := range otherClients {
				totalShown++
				stStr := "ONLINE"
				stColor := Green
				if !c.IsActive {
					stStr = "OFFLINE"
					stColor = Red
				}
				fmt.Printf("  │  %-16s│ %-16s│ %-21s│ %s%-12s%s│ %-20s│\n", c.Hostname, c.IP, c.ActiveUser, stColor, stStr, Reset, c.LastSeen)
			}
		}

		if totalShown == 0 {
			fmt.Printf("  │  %s%-78s%s│\n", Dim, "No matching devices found in this filter.", Reset)
		}
		fmt.Println("  └──────────────────┴─────────────────┴──────────────────────┴─────────────┴─────────────────────┘\n")

		fmt.Print("  Command [r: Refresh | s: Screenshot | c: Remote Cmd | b: Back]: ")
		action, _ := reader.ReadString('\n')
		action = strings.TrimSpace(strings.ToLower(action))

		switch action {
		case "r", "":
			continue
		case "s":
			triggerInteractiveScreenshot(reader)
		case "c":
			triggerInteractiveCommand(reader)
		case "b", "q":
			return
		}
	}
}

// ------------------------------------------------------------------------------
// Remote Screenshot
// ------------------------------------------------------------------------------
func remoteScreenshotMenu(reader *bufio.Reader) {
	drawHeader()
	fmt.Printf("  %s%s=== INSTANT REMOTE SCREEN CAPTURE ===%s\n\n", Bold, Cyan, Reset)
	triggerInteractiveScreenshot(reader)
}

func triggerInteractiveScreenshot(reader *bufio.Reader) {
	fmt.Print("  Enter target Workstation Hostname (e.g. GSFCUPLLAB203): ")
	host, _ := reader.ReadString('\n')
	host = strings.ToUpper(strings.TrimSpace(host))
	if host == "" {
		return
	}

	fmt.Printf("  -> %s[DISPATCHING]%s Requesting instant screenshot from '%s'...\n", Yellow, Reset, host)

	payload, _ := json.Marshal(map[string]string{
		"target": host,
		"action": "screenshot",
	})
	_, _ = http.Post(apiURL+"/api/command/dispatch", "application/json", bytes.NewBuffer(payload))

	fmt.Printf("  -> %s[WAITING]%s Waiting for client to upload screen frame (up to 8s)...\n", Cyan, Reset)
	shotFile := filepath.Join(repoDir, "data", "screenshots", fmt.Sprintf("%s_latest.png", host))
	_ = os.Remove(shotFile)

	for i := 0; i < 8; i++ {
		time.Sleep(1 * time.Second)
		if fi, err := os.Stat(shotFile); err == nil && fi.Size() > 0 {
			fmt.Printf("  -> %s[SUCCESS] Screenshot received!%s Saved to: %s\n", Green, Reset, shotFile)
			// Open viewer if desktop session is active
			_ = exec.Command("xdg-open", shotFile).Start()
			fmt.Print("\n  Press [Enter] to continue...")
			_, _ = reader.ReadString('\n')
			return
		}
	}

	fmt.Printf("  -> %s[TIMEOUT] Client '%s' did not respond. Check if online and scanner is active.%s\n", Red, host, Reset)
	fmt.Print("\n  Press [Enter] to continue...")
	_, _ = reader.ReadString('\n')
}

// ------------------------------------------------------------------------------
// Remote Command Execution
// ------------------------------------------------------------------------------
func remoteExecMenu(reader *bufio.Reader) {
	drawHeader()
	fmt.Printf("  %s%s=== DISPATCH REMOTE COMMAND ===%s\n\n", Bold, Cyan, Reset)
	triggerInteractiveCommand(reader)
}

func triggerInteractiveCommand(reader *bufio.Reader) {
	fmt.Print("  Enter Target Hostname or Lab Prefix (or 'ALL'): ")
	target, _ := reader.ReadString('\n')
	target = strings.ToUpper(strings.TrimSpace(target))
	if target == "" {
		return
	}

	fmt.Print("  Enter Shell Command to Execute on Target: ")
	cmdStr, _ := reader.ReadString('\n')
	cmdStr = strings.TrimSpace(cmdStr)
	if cmdStr == "" {
		return
	}

	payload, _ := json.Marshal(map[string]string{
		"target": target,
		"action": "exec",
		"cmd":    cmdStr,
	})
	_, _ = http.Post(apiURL+"/api/command/dispatch", "application/json", bytes.NewBuffer(payload))

	fmt.Printf("\n  -> %s[DISPATCHED]%s Command scheduled for target '%s'. Executes on next heartbeat.\n", Green, Reset, target)
	fmt.Print("\n  Press [Enter] to continue...")
	_, _ = reader.ReadString('\n')
}

// ------------------------------------------------------------------------------
// Safe Config Editor with 20-Backup / 7-Day Engine
// ------------------------------------------------------------------------------
func safeConfigEditorMenu(reader *bufio.Reader) {
	for {
		drawHeader()
		fmt.Printf("  %s%sSelect Configuration File to Edit (Safe Editor with Backups):%s\n\n", Bold, White, Reset)
		fmt.Printf("    %s[1]%s ⚙️  %sdomain.conf%s            %s(Domain, IP, Timezone, Notification msgs)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[2]%s 🚫 %sblocked-apps.conf%s      %s(Blacklisted DNF packages & Flatpaks)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[3]%s ✅ %sallowed-apps.conf%s      %s(Whitelisted passwordless applications)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[4]%s 📌 %scompulsory-apps.conf%s   %s(Mandatory baseline software)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[5]%s 🏫 %sgroup-apps.conf%s        %s(Lab-specific hostname package mappings)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[6]%s 💡 %sdevice-rules.conf%s      %s(100%% Brightness & Volume locks)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[7]%s ⚡ %sremote-tasks.sh%s        %s(Automated maintenance task script)%s\n", Cyan, Reset, Bold, Reset, Dim, Reset)
		fmt.Printf("    %s[8]%s ↩️  Back to Main Menu\n\n", Cyan, Reset)

		fmt.Print("  Select file [1-8]: ")
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)

		var targetFile string
		switch choice {
		case "1":
			targetFile = filepath.Join(repoDir, "domain.conf")
		case "2":
			targetFile = filepath.Join(repoDir, "config", "blocked-apps.conf")
		case "3":
			targetFile = filepath.Join(repoDir, "config", "allowed-apps.conf")
		case "4":
			targetFile = filepath.Join(repoDir, "config", "compulsory-apps.conf")
		case "5":
			targetFile = filepath.Join(repoDir, "config", "group-apps.conf")
		case "6":
			targetFile = filepath.Join(repoDir, "config", "device-rules.conf")
		case "7":
			targetFile = filepath.Join(repoDir, "config", "remote-tasks.sh")
		case "8":
			return
		default:
			continue
		}

		if _, err := os.Stat(targetFile); err == nil {
			createConfigBackup(targetFile)
			fmt.Printf("\n  -> %s[BACKUP CREATED]%s Saved backup copy in: %s/\n", Green, Reset, backupDir)

			editor := os.Getenv("EDITOR")
			if editor == "" {
				for _, cand := range []string{"nano", "micro", "vim", "vi"} {
					if _, err := exec.LookPath(cand); err == nil {
						editor = cand
						break
					}
				}
			}
			if editor == "" {
				editor = "vi"
			}

			cmd := exec.Command(editor, targetFile)
			cmd.Stdin = os.Stdin
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			_ = cmd.Run()

			if strings.HasSuffix(targetFile, ".sh") {
				testCmd := exec.Command("bash", "-n", targetFile)
				if err := testCmd.Run(); err == nil {
					fmt.Printf("  -> %s[SYNTAX OK]%s Script syntax verified.\n", Green, Reset)
				} else {
					fmt.Printf("  -> %s[SYNTAX ERROR]%s Detected syntax error in %s!\n", Red, Reset, targetFile)
				}
			}

			fmt.Print("\n  Press [Enter] to continue...")
			_, _ = reader.ReadString('\n')
		}
	}
}

// ------------------------------------------------------------------------------
// Connection History
// ------------------------------------------------------------------------------
func connectionHistoryMenu(reader *bufio.Reader) {
	drawHeader()
	fmt.Printf("  %s%s=== WORKSTATION ENROLLMENT & CONNECTION AUDIT LOG ===%s\n\n", Bold, Cyan, Reset)

	clients := fetchClients()
	if len(clients) == 0 {
		fmt.Println("  No workstations have registered yet.")
	} else {
		sort.Slice(clients, func(i, j int) bool {
			return clients[i].LastSeenTS > clients[j].LastSeenTS
		})

		fmt.Printf("  %-18s %-16s %-21s %-21s %s\n", "HOSTNAME", "IP ADDRESS", "FIRST JOINED", "LAST SEEN", "ACTIVE USER")
		fmt.Println("  " + strings.Repeat("-", 86))
		for _, c := range clients {
			fmt.Printf("  %-18s %-16s %-21s %-21s %s\n", c.Hostname, c.IP, c.FirstRegistered, c.LastSeen, c.ActiveUser)
		}
	}

	fmt.Print("\n  Press [Enter] to return...")
	_, _ = reader.ReadString('\n')
}

// ------------------------------------------------------------------------------
// Git Synchronization
// ------------------------------------------------------------------------------
func triggerSyncPush(reader *bufio.Reader) {
	drawHeader()
	fmt.Printf("  %s%s=== SYNCHRONIZE POLICIES & PUSH TO GIT ===%s\n\n", Bold, Cyan, Reset)
	fmt.Print("  Enter commit summary [Default: Update AD-DMS configurations via Go TUI]: ")
	cmsg, _ := reader.ReadString('\n')
	cmsg = strings.TrimSpace(cmsg)
	if cmsg == "" {
		cmsg = "Update AD-DMS configurations via Go TUI"
	}

	fmt.Printf("\n  -> %s[COMMITTING & PUSHING]%s Executing Git synchronization...\n", Yellow, Reset)

	gitAdd := exec.Command("git", "add", "-A")
	gitAdd.Dir = repoDir
	_ = gitAdd.Run()

	gitCommit := exec.Command("git", "commit", "-m", "feat: "+cmsg)
	gitCommit.Dir = repoDir
	_ = gitCommit.Run()

	gitPush := exec.Command("git", "push", "origin", "main")
	gitPush.Dir = repoDir
	gitPush.Stdout = os.Stdout
	gitPush.Stderr = os.Stderr
	_ = gitPush.Run()

	fmt.Printf("\n  -> %s[DONE]%s Intranet & GitHub repositories synchronized.\n", Green, Reset)
	fmt.Print("\n  Press [Enter] to continue...")
	_, _ = reader.ReadString('\n')
}
