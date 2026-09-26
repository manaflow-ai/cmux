package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Claude Code hooks on an SSH relay host. The Mac app owns delivery: the hook
// only admits one bounded event to `agent.hook.enqueue` and returns `{}` so a
// slow or missing relay never blocks the agent.

const (
	claudeHookMaximumInputBytes   = 1 << 20
	claudeHookMaximumPayloadBytes = 4 * 1024
	claudeHookRoundTripTimeout    = 3 * time.Second
	claudeHookDeclaredTimeout     = 5
)

// claudeRelayHookEvents are the non-decision lifecycle events the relay admits.
// Decision hooks (PermissionRequest, CronCreate guard) keep Claude's native
// behavior on remote hosts.
var claudeRelayHookEvents = []struct {
	event      string
	matcher    string
	subcommand string
}{
	{"SessionStart", "", "session-start"},
	{"UserPromptSubmit", "", "prompt-submit"},
	{"Stop", "", "stop"},
	{"Notification", "", "notification"},
	{"SessionEnd", "", "session-end"},
	{"PreToolUse", "AskUserQuestion|ExitPlanMode", "pre-tool-use"},
}

var claudeRelayHookSubcommands = func() map[string]bool {
	subcommands := make(map[string]bool, len(claudeRelayHookEvents))
	for _, definition := range claudeRelayHookEvents {
		subcommands[definition.subcommand] = true
	}
	return subcommands
}()

// Remote paths describe this host. The Mac replays the event locally, so they
// are removed before admission rather than resolved against the Mac's disk.
var claudeHookFilesystemKeys = map[string]bool{
	"cwd": true, "working_directory": true, "workingDirectory": true,
	"project_dir": true, "projectDir": true, "project_path": true, "projectPath": true,
	"workspacePaths": true, "workspace_paths": true,
	"transcript_path": true, "transcriptPath": true,
	"agent_transcript_path": true,
}

// runClaudeHookRelay implements `cmux claude-hook <subcommand>`.
func runClaudeHookRelay(socketPath string, args []string, refreshAddr func() string, stdin io.Reader, stdout io.Writer) int {
	defer fmt.Fprintln(stdout, "{}")
	input, _ := io.ReadAll(io.LimitReader(stdin, claudeHookMaximumInputBytes))
	if len(args) != 1 || os.Getenv("CMUX_CLAUDE_HOOKS_DISABLED") == "1" || socketPath == "" {
		return 0
	}
	params, ok := claudeHookEnqueueParams(args[0], input, os.Getenv, claudeHookCallerTTY)
	if !ok {
		return 0
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := socketRoundTripV2(socketPath, "agent.hook.enqueue", params, refreshAddr); err != nil && os.Getenv("CMUX_CLAUDE_HOOK_DEBUG") == "1" {
			fmt.Fprintf(os.Stderr, "cmux claude-hook: %v\n", err)
		}
	}()
	select {
	case <-done:
	case <-time.After(claudeHookRoundTripTimeout):
	}
	return 0
}

// claudeHookEnqueueParams builds the relay admission request. It returns false
// when the hook has no cmux surface to route to.
func claudeHookEnqueueParams(subcommand string, input []byte, getenv func(string) string, callerTTY func(string) string) (map[string]any, bool) {
	subcommand = strings.ToLower(strings.TrimSpace(subcommand))
	if !claudeRelayHookSubcommands[subcommand] {
		return nil, false
	}
	workspaceID := strings.TrimSpace(getenv("CMUX_WORKSPACE_ID"))
	surfaceID := strings.TrimSpace(getenv("CMUX_SURFACE_ID"))
	if workspaceID == "" || surfaceID == "" {
		return nil, false
	}
	params := map[string]any{
		"agent":        "claude",
		"subcommand":   subcommand,
		"payload":      compactClaudeHookPayload(input),
		"relay_backed": true,
		"workspace_id": workspaceID,
		"surface_id":   surfaceID,
	}
	if tty := callerTTY(getenv("CMUX_CLAUDE_PID")); tty != "" {
		params["caller_tty"] = tty
	}
	return params, true
}

// compactClaudeHookPayload strips host paths and bounds the payload to the
// relay's admission limit, keeping the fields that drive lifecycle state.
func compactClaudeHookPayload(input []byte) string {
	var object map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(input), &object); err != nil || object == nil {
		return "{}"
	}
	stripped, _ := stripClaudeHookFilesystemKeys(object).(map[string]any)
	if encoded, err := json.Marshal(stripped); err == nil && len(encoded) <= claudeHookMaximumPayloadBytes {
		return string(encoded)
	}
	fallback := map[string]any{}
	for _, key := range []string{"session_id", "turn_id"} {
		setBoundedClaudeHookString(fallback, key, stripped[key], 256)
	}
	for _, key := range []string{"hook_event_name", "tool_name", "permission_mode", "notification_type", "source", "reason", "agent_state", "turn_outcome"} {
		setBoundedClaudeHookString(fallback, key, stripped[key], 80)
	}
	for _, key := range []string{"message", "title", "last_assistant_message"} {
		setBoundedClaudeHookString(fallback, key, stripped[key], 240)
	}
	for _, key := range []string{"stop_hook_active", "fullyIdle"} {
		if value, ok := stripped[key].(bool); ok {
			fallback[key] = value
		}
	}
	encoded, err := json.Marshal(fallback)
	if err != nil || len(encoded) > claudeHookMaximumPayloadBytes {
		return "{}"
	}
	return string(encoded)
}

func setBoundedClaudeHookString(target map[string]any, key string, value any, maximumRunes int) {
	text, ok := value.(string)
	if !ok {
		return
	}
	if runes := []rune(text); len(runes) > maximumRunes {
		text = string(runes[:maximumRunes])
	}
	target[key] = text
}

func stripClaudeHookFilesystemKeys(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(typed))
		for key, child := range typed {
			if claudeHookFilesystemKeys[key] {
				continue
			}
			result[key] = stripClaudeHookFilesystemKeys(child)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, child := range typed {
			result[index] = stripClaudeHookFilesystemKeys(child)
		}
		return result
	default:
		return value
	}
}

// claudeHookCallerTTY reports the controlling terminal of the Claude process
// so the app can route a hook whose surface environment went stale.
func claudeHookCallerTTY(claudePID string) string {
	var pids []string
	if pid, err := strconv.Atoi(strings.TrimSpace(claudePID)); err == nil && pid > 0 {
		pids = append(pids, strconv.Itoa(pid))
	}
	pids = append(pids, strconv.Itoa(os.Getppid()))
	for _, pid := range pids {
		for _, fd := range []string{"0", "1", "2"} {
			target, err := os.Readlink(filepath.Join("/proc", pid, "fd", fd))
			if err == nil && (strings.HasPrefix(target, "/dev/pts/") || strings.HasPrefix(target, "/dev/tty")) {
				return target
			}
		}
	}
	return strings.TrimSpace(os.Getenv("CMUX_TTY_NAME"))
}

// --- Launch wrapper ---

// runClaudeWrapper implements `cmux claude-wrapper [claude args...]`. The
// remote shell integration's `claude` shim execs it, so launchers that resolve
// `claude` from PATH (for example `sr claude proxy`) are covered too. Hooks go
// through `--settings`, which works under any CLAUDE_CONFIG_DIR.
func runClaudeWrapper(socketPath string, args []string, refreshAddr func() string) int {
	cmuxBin := claudeWrapperCmuxBinary()
	realClaude := findRealClaude(os.Getenv("PATH"), cmuxBin)
	if realClaude == "" {
		fmt.Fprintln(os.Stderr, "cmux: claude not found in PATH")
		return 127
	}
	launchArgs := args
	if claudeWrapperShouldInject(args, socketPath, refreshAddr) {
		if injected, err := claudeArgsWithRelayHooks(args, cmuxBin, claudeSettingsCacheDir()); err == nil {
			launchArgs = injected
			_ = os.Setenv("CMUX_CLAUDE_PID", strconv.Itoa(os.Getpid()))
			_ = os.Setenv("CMUX_CLAUDE_HOOK_CMUX_BIN", cmuxBin)
		} else {
			fmt.Fprintf(os.Stderr, "cmux: launching claude without cmux hooks: %v\n", err)
		}
	}
	argv := append([]string{realClaude}, launchArgs...)
	if err := syscall.Exec(realClaude, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "cmux: failed to exec claude: %v\n", err)
		return 126
	}
	return 0
}

func claudeWrapperShouldInject(args []string, socketPath string, refreshAddr func() string) bool {
	if os.Getenv("CMUX_CLAUDE_HOOKS_DISABLED") == "1" || socketPath == "" ||
		os.Getenv("CMUX_SURFACE_ID") == "" || os.Getenv("CMUX_WORKSPACE_ID") == "" ||
		claudeTeamsLaunchIsNonLaunch(args) {
		return false
	}
	// Without a live relay the hooks cannot deliver, and the injected settings
	// would disable Claude's own notifications.
	done := make(chan error, 1)
	go func() {
		_, err := socketRoundTripV2(socketPath, "system.ping", nil, refreshAddr)
		done <- err
	}()
	select {
	case err := <-done:
		return err == nil
	case <-time.After(time.Second):
		return false
	}
}

// claudeWrapperCmuxBinary prefers the relay's stable CLI entrypoint, which
// follows daemon upgrades, over this process's versioned daemon path.
func claudeWrapperCmuxBinary() string {
	candidates := []string{os.Getenv("CMUX_BUNDLED_CLI_PATH")}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".cmux", "bin", "cmux"))
	}
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	if executable, err := os.Executable(); err == nil {
		return executable
	}
	return "cmux"
}

// findRealClaude resolves `claude` from PATH, skipping cmux shim directories
// and anything that resolves back to this wrapper.
func findRealClaude(pathEnv string, cmuxBin string) string {
	skip := map[string]bool{}
	if cmuxBin != "" {
		skip[filepath.Dir(cmuxBin)] = true
	}
	if root := os.Getenv("CMUX_CLAUDE_WRAPPER_SHIM_ROOT"); root != "" {
		skip[root] = true
	}
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" || skip[dir] || strings.Contains(dir, "/cmux-cli-shims") {
			continue
		}
		candidate := filepath.Join(dir, "claude")
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		if resolved, err := filepath.EvalSymlinks(candidate); err == nil && filepath.Base(resolved) == "cmux-claude-wrapper" {
			continue
		}
		return candidate
	}
	return ""
}

func claudeSettingsCacheDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".cmux", "claude-settings")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("cmux-claude-settings-%d", os.Getuid()))
}

// claudeArgsWithRelayHooks folds every `--settings` argument into one settings
// file that also carries the cmux relay hooks. A launcher such as `sr` passes
// its own `--settings`; merging keeps both instead of relying on Claude's
// handling of repeated flags.
func claudeArgsWithRelayHooks(args []string, cmuxBin string, cacheDir string) ([]string, error) {
	merged := map[string]any{}
	var remaining []string
	for index := 0; index < len(args); index++ {
		argument := args[index]
		if argument == "--" {
			remaining = append(remaining, args[index:]...)
			break
		}
		var value string
		switch {
		case argument == "--settings" && index+1 < len(args):
			value = args[index+1]
			index++
		case strings.HasPrefix(argument, "--settings="):
			value = strings.TrimPrefix(argument, "--settings=")
		default:
			remaining = append(remaining, argument)
			continue
		}
		settings, err := readClaudeSettingsArgument(value)
		if err != nil {
			return nil, err
		}
		mergeClaudeSettings(merged, settings)
	}
	mergeClaudeSettings(merged, claudeRelayHookSettings(cmuxBin))
	data, err := json.Marshal(merged)
	if err != nil {
		return nil, err
	}
	path, err := writeClaudeSettingsFile(cacheDir, data)
	if err != nil {
		return nil, err
	}
	return append([]string{"--settings", path}, remaining...), nil
}

func readClaudeSettingsArgument(value string) (map[string]any, error) {
	data := []byte(value)
	if trimmed := strings.TrimSpace(value); !strings.HasPrefix(trimmed, "{") {
		fileData, err := os.ReadFile(value)
		if err != nil {
			return nil, fmt.Errorf("read --settings %s: %w", value, err)
		}
		data = fileData
	}
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, fmt.Errorf("parse --settings: %w", err)
	}
	return settings, nil
}

// mergeClaudeSettings merges objects recursively and concatenates arrays, so
// hook groups from every source run.
func mergeClaudeSettings(target map[string]any, source map[string]any) {
	for key, value := range source {
		existing, present := target[key]
		if !present {
			target[key] = value
			continue
		}
		switch typed := value.(type) {
		case map[string]any:
			if existingMap, ok := existing.(map[string]any); ok {
				mergeClaudeSettings(existingMap, typed)
				continue
			}
		case []any:
			if existingArray, ok := existing.([]any); ok {
				target[key] = append(existingArray, typed...)
				continue
			}
		}
		target[key] = value
	}
}

func claudeRelayHookSettings(cmuxBin string) map[string]any {
	hooks := map[string]any{}
	for _, definition := range claudeRelayHookEvents {
		command := fmt.Sprintf("%s claude-hook %s", shellQuoteClaudeHookPath(cmuxBin), definition.subcommand)
		group := map[string]any{
			"matcher": definition.matcher,
			"hooks": []any{map[string]any{
				"type":    "command",
				"command": command,
				"timeout": claudeHookDeclaredTimeout,
			}},
		}
		existing, _ := hooks[definition.event].([]any)
		hooks[definition.event] = append(existing, group)
	}
	return map[string]any{
		"hooks":                 hooks,
		"preferredNotifChannel": "notifications_disabled",
	}
}

func shellQuoteClaudeHookPath(path string) string {
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}

// Merged settings can carry a launcher's credentials (sr's `env`), so copies
// that no launch has reused for this long are removed.
const claudeSettingsRetention = 7 * 24 * time.Hour

// writeClaudeSettingsFile stores settings under a content hash so repeated
// launches reuse one private file instead of leaking temp files.
func writeClaudeSettingsFile(dir string, data []byte) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	path := filepath.Join(dir, hex.EncodeToString(sum[:16])+".json")
	pruneClaudeSettingsFiles(dir, path, time.Now())
	if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, data) {
		now := time.Now()
		_ = os.Chtimes(path, now, now)
		return path, nil
	}
	file, err := os.CreateTemp(dir, ".settings-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return "", err
	}
	return path, nil
}

func pruneClaudeSettingsFiles(dir string, keep string, now time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		if path == keep || entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		if info, err := entry.Info(); err == nil && now.Sub(info.ModTime()) > claudeSettingsRetention {
			_ = os.Remove(path)
		}
	}
}
