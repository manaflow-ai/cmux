package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const tmuxNotifyHooksVersion = "1"
const tmuxNotifyHooksIndex = 458

var tmuxNotifyHookEvents = []string{
	"client-attached",
	"client-session-changed",
	"session-created",
	"window-linked",
	"window-renamed",
	"pane-focus-in",
	"after-select-pane",
}

func runTmuxNotifyCommand(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	subcommand := "help"
	if len(args) > 0 {
		subcommand = strings.ToLower(args[0])
		args = args[1:]
	}
	if hasArg(args, "--json") {
		jsonOutput = true
		args = removeArg(args, "--json")
	}

	switch subcommand {
	case "init", "bootstrap":
		return runTmuxNotifyHookInstaller(args, jsonOutput)
	case "refresh", "notify":
		return runTmuxNotifyRefresh(socketPath, args, jsonOutput, refreshAddr)
	case "help", "--help", "-h":
		fmt.Println("Usage: cmux tmux init [--force] [--json]\n       cmux tmux refresh [--event <name>] [--pane-tty <tty>] [--client-tty <tty>]")
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cmux tmux: unknown subcommand %q\n", subcommand)
		return 2
	}
}

func runTmuxNotifyHookInstaller(args []string, jsonOutput bool) int {
	force := hasArg(args, "--force")
	tmuxPath := findTmuxExecutable()
	if tmuxPath == "" {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "installed": false, "reason": "tmux_not_found"})
		return 0
	}

	if !force {
		stdout, status := runTmuxProcess(tmuxPath, []string{"show-options", "-gqv", "@cmux_hooks_version"})
		if status == 0 && strings.TrimSpace(stdout) == tmuxNotifyHooksVersion {
			printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "installed": false, "version": tmuxNotifyHooksVersion})
			return 0
		}
	}

	installed := []string{}
	for _, event := range tmuxNotifyHookEvents {
		status := runTmuxProcessStatus(tmuxPath, []string{"set-hook", "-g", tmuxNotifyHookTarget(event), tmuxNotifyHookCommand(event)})
		if status != 0 {
			printTmuxNotifyJSON(jsonOutput, map[string]any{
				"ok":        true,
				"installed": false,
				"reason":    "tmux_hook_failed",
				"event":     event,
			})
			return 0
		}
		installed = append(installed, event)
	}

	status := runTmuxProcessStatus(tmuxPath, []string{"set-option", "-g", "@cmux_hooks_version", tmuxNotifyHooksVersion})
	if status != 0 {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "installed": false, "reason": "tmux_marker_failed"})
		return 0
	}

	printTmuxNotifyJSON(jsonOutput, map[string]any{
		"ok":        true,
		"installed": true,
		"version":   tmuxNotifyHooksVersion,
		"events":    installed,
	})
	return 0
}

func runTmuxNotifyRefresh(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if socketPath == "" {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "updated": false, "reason": "socket_unavailable"})
		return 0
	}

	parsed, err := parseFlags(args, []string{"event", "pane-tty", "client-tty", "session", "window", "pane"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux tmux refresh: %v\n", err)
		return 2
	}

	workspaceID := firstNonEmpty(os.Getenv("CMUX_WORKSPACE_ID"), os.Getenv("CMUX_TAB_ID"))
	if workspaceID == "" {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "updated": false, "reason": "missing_workspace"})
		return 0
	}

	paneTTY := firstNonEmpty(parsed.flags["pane-tty"], currentTTYNameGo())
	if paneTTY == "" {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "updated": false, "reason": "missing_tty"})
		return 0
	}

	params := map[string]any{
		"workspace_id": workspaceID,
		"tty_name":     paneTTY,
	}
	if surfaceID := firstNonEmpty(os.Getenv("CMUX_PANEL_ID"), os.Getenv("CMUX_SURFACE_ID")); surfaceID != "" {
		params["surface_id"] = surfaceID
	}
	if value := strings.TrimSpace(parsed.flags["client-tty"]); value != "" {
		params["client_tty_name"] = value
	}
	if value := parsed.flags["event"]; value != "" {
		params["tmux_event"] = value
	}
	if value := parsed.flags["session"]; value != "" {
		params["tmux_session"] = value
	}
	if value := parsed.flags["window"]; value != "" {
		params["tmux_window"] = value
	}
	if value := parsed.flags["pane"]; value != "" {
		params["tmux_pane"] = value
	}

	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}
	result, err := rc.call("surface.report_tty", params)
	if err != nil {
		printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "updated": false, "reason": "socket_unavailable"})
		return 0
	}
	printTmuxNotifyJSON(jsonOutput, map[string]any{"ok": true, "updated": true, "result": result})
	return 0
}

func tmuxNotifyHookCommand(event string) string {
	cmux := tmuxShellQuote(currentCmuxExecutablePathForHook())
	refreshCommand := strings.Join([]string{
		cmux,
		"tmux refresh",
		"--event " + event,
		"--pane-tty \"#{pane_tty}\"",
		"--client-tty \"#{client_tty}\"",
		"--session \"#{session_name}\"",
		"--window \"#{window_index}\"",
		"--pane \"#{pane_id}\"",
		">/dev/null 2>&1 || true",
	}, " ")
	return "run-shell -b " + tmuxShellQuote(refreshCommand)
}

func tmuxNotifyHookTarget(event string) string {
	return fmt.Sprintf("%s[%d]", event, tmuxNotifyHooksIndex)
}

func findTmuxExecutable() string {
	if explicit := executableCandidate(os.Getenv("CMUX_TMUX_BIN")); explicit != "" {
		return explicit
	}
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if strings.TrimSpace(dir) == "" {
			continue
		}
		if candidate := executableCandidate(filepath.Join(dir, "tmux")); candidate != "" {
			return candidate
		}
	}
	return executableCandidate("/usr/bin/tmux")
}

func executableCandidate(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	if info, err := os.Stat(path); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
		return path
	}
	return ""
}

func currentCmuxExecutablePathForHook() string {
	if bundled := executableCandidate(os.Getenv("CMUX_BUNDLED_CLI_PATH")); bundled != "" {
		return bundled
	}
	if len(os.Args) > 0 && strings.Contains(os.Args[0], "/") {
		if abs, err := filepath.Abs(os.Args[0]); err == nil {
			return abs
		}
		return os.Args[0]
	}
	return "cmux"
}

func runTmuxProcess(path string, args []string) (string, int) {
	cmd := exec.Command(path, args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return string(output), exitErr.ExitCode()
		}
		return string(output), 1
	}
	return string(output), 0
}

func runTmuxProcessStatus(path string, args []string) int {
	cmd := exec.Command(path, args...)
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}
	return 0
}

func currentTTYNameGo() string {
	for _, file := range []*os.File{os.Stdin, os.Stdout, os.Stderr} {
		if file == nil {
			continue
		}
		if name, err := ttyNameForFile(file); err == nil && strings.TrimSpace(name) != "" && name != "not a tty" {
			return name
		}
	}
	return ""
}

func ttyNameForFile(file *os.File) (string, error) {
	for _, fdRoot := range []string{"/proc/self/fd", "/dev/fd"} {
		fdPath := filepath.Join(fdRoot, fmt.Sprintf("%d", file.Fd()))
		if target, err := os.Readlink(fdPath); err == nil && strings.HasPrefix(target, "/dev/") {
			return target, nil
		}
	}
	if conn, err := net.FileConn(file); err == nil {
		_ = conn.Close()
		return "", nil
	}
	return "", fmt.Errorf("not a tty")
}

func printTmuxNotifyJSON(enabled bool, payload map[string]any) {
	if !enabled {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		fmt.Println(`{"ok":true}`)
		return
	}
	fmt.Println(string(data))
}

func hasArg(args []string, needle string) bool {
	for _, arg := range args {
		if arg == needle {
			return true
		}
	}
	return false
}

func removeArg(args []string, needle string) []string {
	filtered := args[:0]
	for _, arg := range args {
		if arg != needle {
			filtered = append(filtered, arg)
		}
	}
	return filtered
}
