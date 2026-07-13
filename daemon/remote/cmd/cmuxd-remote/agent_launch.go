package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const claudeNodeOptionsRestoreModuleScript = `const hadOriginalNodeOptions = process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
if (hadOriginalNodeOptions) {
  process.env.NODE_OPTIONS = process.env.CMUX_ORIGINAL_NODE_OPTIONS ?? "";
} else {
  delete process.env.NODE_OPTIONS;
}
delete process.env.CMUX_ORIGINAL_NODE_OPTIONS;
delete process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT;
`

// runClaudeTeamsRelay implements `cmux claude-teams` on the remote side.
// It creates tmux shim scripts, sets up environment variables, gets the
// focused context via system.identify, and exec's into `claude`.
func runClaudeTeamsRelay(socketPath string, args []string, refreshAddr func() string) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createTmuxShimDir("claude-teams-bin", claudeTeamsShimScript)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux claude-teams: failed to create shim directory: %v\n", err)
		return 1
	}

	// Resolve the agent executable BEFORE modifying PATH (so the shim
	// directory doesn't shadow anything). Matches the Swift CLI behavior.
	originalPath := os.Getenv("PATH")
	claudePath := findExecutableInPath("claude", originalPath, shimDir)

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: "cmux-claude-teams",
		cmuxBinEnvVar:  "CMUX_CLAUDE_TEAMS_CMUX_BIN",
		termEnvVar:     "CMUX_CLAUDE_TEAMS_TERM",
		extraEnv: map[string]string{
			"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
		},
	})
	if restoreModulePath, err := ensureClaudeNodeOptionsRestoreModule(); err == nil {
		configureClaudeNodeOptions(restoreModulePath)
	}

	launchArgs := claudeTeamsLaunchArgs(args)

	if claudePath == "" {
		fmt.Fprintf(os.Stderr, "cmux claude-teams: claude not found in PATH\n")
		return 1
	}
	argv := append([]string{claudePath}, launchArgs...)
	execErr := syscall.Exec(claudePath, argv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux claude-teams: exec failed: %v\n", execErr)
	return 1
}

// runOMORelay implements `cmux omo` on the remote side.
func runOMORelay(socketPath string, args []string, refreshAddr func() string) int {
	return runOpenCodeRelay(socketPath, args, refreshAddr, opencodeRelayConfig{
		commandName:    "cmux omo",
		createShimDir:  createOMOShimDir,
		pluginSetup:    omoEnsurePlugin,
		defaultPort:    "4096",
		tmuxPathPrefix: "cmux-omo",
		cmuxBinEnvVar:  "CMUX_OMO_CMUX_BIN",
		termEnvVar:     "CMUX_OMO_TERM",
		extraEnv:       map[string]string{},
	})
}

// runOMOSlimRelay implements `cmux omo-slim` on the remote side.
func runOMOSlimRelay(socketPath string, args []string, refreshAddr func() string) int {
	return runOpenCodeRelay(socketPath, args, refreshAddr, opencodeRelayConfig{
		commandName:    "cmux omo-slim",
		createShimDir:  createOMOSlimShimDir,
		pluginSetup:    omoSlimEnsurePlugin,
		defaultPort:    "4097",
		tmuxPathPrefix: "cmux-omo-slim",
		cmuxBinEnvVar:  "CMUX_OMO_SLIM_CMUX_BIN",
		termEnvVar:     "CMUX_OMO_SLIM_TERM",
		extraEnv: map[string]string{
			"OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS": "true",
		},
	})
}

type opencodeRelayConfig struct {
	commandName    string
	createShimDir  func() (string, error)
	pluginSetup    func(searchPath string) error
	defaultPort    string
	tmuxPathPrefix string
	cmuxBinEnvVar  string
	termEnvVar     string
	extraEnv       map[string]string
}

func runOpenCodeRelay(socketPath string, args []string, refreshAddr func() string, cfg opencodeRelayConfig) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := cfg.createShimDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: failed to create launcher shim: %v\n", cfg.commandName, err)
		return 1
	}

	// Resolve the agent executable BEFORE modifying PATH.
	originalPath := os.Getenv("PATH")
	opencodePath := findExecutableInPath("opencode", originalPath, shimDir)
	if opencodePath == "" {
		fmt.Fprintf(os.Stderr, "%s: required agent executable not found. Install the agent CLI and retry.\n", cfg.commandName)
		return 1
	}

	if err := cfg.pluginSetup(originalPath); err != nil {
		fmt.Fprintf(os.Stderr, "%s: launcher plugin setup failed. Check the plugin installation and retry.\n", cfg.commandName)
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: cfg.tmuxPathPrefix,
		cmuxBinEnvVar:  cfg.cmuxBinEnvVar,
		termEnvVar:     cfg.termEnvVar,
		extraEnv:       cfg.extraEnv,
	})

	os.Setenv("OPENCODE_PORT", openCodeRelayEffectivePort(args, cfg.defaultPort))
	launchArgs := openCodeRelayLaunchArgs(args, cfg.defaultPort)

	launchPath, launchArgv := resolveNodeScriptExec(opencodePath, launchArgs, originalPath, shimDir)
	execErr := syscall.Exec(launchPath, launchArgv, os.Environ())
	fmt.Fprintf(os.Stderr, "%s: exec failed: %v\n", cfg.commandName, execErr)
	return 1
}

func openCodeRelayLaunchArgs(args []string, defaultPort string) []string {
	launchArgs := args
	for _, arg := range launchArgs {
		if arg == "--port" || strings.HasPrefix(arg, "--port=") {
			return launchArgs
		}
	}
	port := os.Getenv("OPENCODE_PORT")
	if port == "" {
		port = openCodeRelayDefaultPort(defaultPort)
	}
	return append([]string{"--port", port}, launchArgs...)
}

func openCodeRelayEffectivePort(args []string, defaultPort string) string {
	for i, arg := range args {
		if arg == "--port" && i+1 < len(args) && strings.TrimSpace(args[i+1]) != "" {
			return args[i+1]
		}
		if strings.HasPrefix(arg, "--port=") {
			port := strings.TrimSpace(strings.TrimPrefix(arg, "--port="))
			if port != "" {
				return port
			}
		}
	}
	if port := strings.TrimSpace(os.Getenv("OPENCODE_PORT")); port != "" {
		return port
	}
	return openCodeRelayDefaultPort(defaultPort)
}

func openCodeRelayDefaultPort(defaultPort string) string {
	if strings.TrimSpace(defaultPort) == "" {
		return "4096"
	}
	return defaultPort
}

// runOMXRelay implements `cmux omx` on the remote side.
func runOMXRelay(socketPath string, args []string, refreshAddr func() string) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createTmuxShimDir("omx-bin", omxShimScript)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux omx: failed to create shim directory: %v\n", err)
		return 1
	}

	originalPath := os.Getenv("PATH")
	omxPath := findExecutableInPath("omx", originalPath, shimDir)
	if omxPath == "" {
		fmt.Fprintf(os.Stderr, "cmux omx: omx not found in PATH\n"+
			"Install it first:\n  npm install -g oh-my-codex\n")
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: "cmux-omx",
		cmuxBinEnvVar:  "CMUX_OMX_CMUX_BIN",
		termEnvVar:     "CMUX_OMX_TERM",
		extraEnv:       map[string]string{},
	})

	launchPath, launchArgv := resolveNodeScriptExec(omxPath, args, originalPath, shimDir)
	execErr := syscall.Exec(launchPath, launchArgv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux omx: exec failed: %v\n", execErr)
	return 1
}

// runOMCRelay implements `cmux omc` on the remote side.
func runOMCRelay(socketPath string, args []string, refreshAddr func() string) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createTmuxShimDir("omc-bin", omcShimScript)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux omc: failed to create shim directory: %v\n", err)
		return 1
	}

	originalPath := os.Getenv("PATH")
	omcPath := findExecutableInPath("omc", originalPath, shimDir)
	if omcPath == "" {
		fmt.Fprintf(os.Stderr, "cmux omc: omc not found in PATH\n"+
			"Install it first:\n  npm install -g oh-my-claude-sisyphus\n")
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: "cmux-omc",
		cmuxBinEnvVar:  "CMUX_OMC_CMUX_BIN",
		termEnvVar:     "CMUX_OMC_TERM",
		extraEnv:       map[string]string{},
	})

	// omc wraps Claude Code, so configure NODE_OPTIONS restore module
	if restoreModulePath, err := ensureClaudeNodeOptionsRestoreModule(); err == nil {
		configureClaudeNodeOptions(restoreModulePath)
	} else {
		fmt.Fprintf(os.Stderr, "cmux omc: warning: failed to create NODE_OPTIONS restore module: %v\n", err)
	}

	launchPath, launchArgv := resolveNodeScriptExec(omcPath, args, originalPath, shimDir)
	execErr := syscall.Exec(launchPath, launchArgv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux omc: exec failed: %v\n", execErr)
	return 1
}

// --- Shim creation ---

const claudeTeamsShimScript = `#!/usr/bin/env bash
set -euo pipefail
exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omoTmuxShimScript = `#!/usr/bin/env bash
set -euo pipefail
# Only match -V/-v as the first arg (top-level tmux flag).
# -v inside subcommands (e.g. split-window -v) is a vertical split flag.
case "${1:-}" in
  -V|-v) echo "tmux 3.4"; exit 0 ;;
esac
exec "${CMUX_OMO_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omoSlimTmuxShimScript = `#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -V|-v) echo "tmux 3.4"; exit 0 ;;
esac
exec "${CMUX_OMO_SLIM_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omxShimScript = `#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -V|-v) echo "tmux 3.4"; exit 0 ;;
esac
exec "${CMUX_OMX_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omcShimScript = `#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -V|-v) echo "tmux 3.4"; exit 0 ;;
esac
exec "${CMUX_OMC_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omoNotifierShimScript = `#!/usr/bin/env bash
# Intercept terminal-notifier calls and route through cmux notify.
TITLE="" BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -title)   TITLE="$2"; shift 2 ;;
    -message) BODY="$2"; shift 2 ;;
    *)        shift ;;
  esac
done
exec "${CMUX_OMO_CMUX_BIN:-cmux}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
`

const omoSlimNotifierShimScript = `#!/usr/bin/env bash
# Intercept terminal-notifier calls and route through cmux notify.
TITLE="" BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -title)   TITLE="$2"; shift 2 ;;
    -message) BODY="$2"; shift 2 ;;
    *)        shift ;;
  esac
done
exec "${CMUX_OMO_SLIM_CMUX_BIN:-cmux}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
`

func createTmuxShimDir(dirName string, tmuxScript string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".cmuxterm", dirName)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	tmuxPath := filepath.Join(dir, "tmux")
	if err := writeShimIfChanged(tmuxPath, tmuxScript); err != nil {
		return "", err
	}
	return dir, nil
}

func createOMOShimDir() (string, error) {
	dir, err := createTmuxShimDir("omo-bin", omoTmuxShimScript)
	if err != nil {
		return "", err
	}
	notifierPath := filepath.Join(dir, "terminal-notifier")
	if err := writeShimIfChanged(notifierPath, omoNotifierShimScript); err != nil {
		return "", err
	}
	return dir, nil
}

func createOMOSlimShimDir() (string, error) {
	dir, err := createTmuxShimDir("omo-slim-bin", omoSlimTmuxShimScript)
	if err != nil {
		return "", err
	}
	notifierPath := filepath.Join(dir, "terminal-notifier")
	if err := writeShimIfChanged(notifierPath, omoSlimNotifierShimScript); err != nil {
		return "", err
	}
	return dir, nil
}

func writeShimIfChanged(path string, content string) error {
	existing, err := os.ReadFile(path)
	if err == nil && string(existing) == content {
		return nil
	}
	dir := filepath.Dir(path)
	tempFile, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)
	if _, err := tempFile.WriteString(content); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tempPath, 0755); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	return nil
}

func ensureClaudeNodeOptionsRestoreModule() (string, error) {
	dir := filepath.Join(os.TempDir(), "cmux-claude-node-options")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	restoreModulePath := filepath.Join(dir, "restore-node-options.cjs")
	if err := writeShimIfChanged(restoreModulePath, claudeNodeOptionsRestoreModuleScript); err != nil {
		return "", err
	}
	return restoreModulePath, nil
}

// --- Focused context ---

type focusedContext struct {
	workspaceId string
	windowId    string
	paneHandle  string
	paneId      string
	surfaceId   string
}

func getFocusedContext(rc *rpcContext) *focusedContext {
	return getFocusedContextWithTimeout(rc, 5*time.Second)
}

func getFocusedContextWithTimeout(rc *rpcContext, timeout time.Duration) *focusedContext {
	// Use a goroutine with timeout so a slow/stale relay doesn't block agent launch.
	type result struct {
		payload map[string]any
	}
	ch := make(chan result, 1)
	started := time.Now()
	go func() {
		payload, err := rc.call("system.identify", nil)
		if err != nil {
			ch <- result{}
			return
		}
		ch <- result{payload: payload}
	}()

	var payload map[string]any
	select {
	case r := <-ch:
		payload = r.payload
	case <-time.After(timeout):
		return nil
	}

	focused, _ := payload["focused"].(map[string]any)
	if focused == nil {
		return nil
	}
	ctx := focusedContextFromIdentify(focused)
	if ctx == nil {
		return nil
	}

	remaining := timeout - time.Since(started)
	if remaining <= 0 {
		return ctx
	}
	return canonicalizeFocusedContextWithTimeout(rc, focused, ctx, remaining)
}

func focusedContextFromIdentify(focused map[string]any) *focusedContext {
	wsId := stringFromAny(focused["workspace_id"], focused["workspace_ref"])
	paneHandle := stringFromAny(focused["pane_id"], focused["pane_ref"])
	if wsId == "" || paneHandle == "" {
		return nil
	}
	return &focusedContext{
		workspaceId: wsId,
		windowId:    stringFromAny(focused["window_id"], focused["window_ref"]),
		paneHandle:  strings.TrimSpace(paneHandle),
		paneId:      strings.TrimSpace(stringFromAny(focused["pane_uuid"], focused["pane_id"])),
		surfaceId:   stringFromAny(focused["surface_id"], focused["surface_ref"]),
	}
}

func canonicalizeFocusedContextWithTimeout(
	rc *rpcContext,
	focused map[string]any,
	base *focusedContext,
	timeout time.Duration,
) *focusedContext {
	type result struct {
		focused *focusedContext
	}
	ch := make(chan result, 1)
	go func() {
		enriched := *base
		canonicalizeFocusedContext(rc, focused, &enriched)
		ch <- result{focused: &enriched}
	}()
	select {
	case r := <-ch:
		return r.focused
	case <-time.After(timeout):
		return base
	}
}

func canonicalizeFocusedContext(rc *rpcContext, focused map[string]any, ctx *focusedContext) {
	canonicalPaneId := strings.TrimSpace(stringFromAny(focused["pane_uuid"]))
	if canonicalWsId, err := tmuxResolveWorkspaceId(rc, ctx.workspaceId); err == nil {
		if canonicalPaneId == "" {
			if pid := strings.TrimSpace(stringFromAny(focused["pane_id"])); pid != "" {
				if resolved, err := tmuxCanonicalPaneId(rc, pid, canonicalWsId); err == nil {
					canonicalPaneId = resolved
				}
			}
		}
		if canonicalPaneId == "" {
			if pid, err := tmuxCanonicalPaneId(rc, ctx.paneHandle, canonicalWsId); err == nil {
				canonicalPaneId = pid
			}
		}
	}
	if canonicalPaneId == "" {
		canonicalPaneId = strings.TrimSpace(stringFromAny(focused["pane_id"]))
	}
	if canonicalPaneId != "" {
		ctx.paneId = strings.TrimSpace(canonicalPaneId)
	}
}

func configureClaudeNodeOptions(restoreModulePath string) {
	existing, hadExisting := os.LookupEnv("NODE_OPTIONS")
	if hadExisting {
		os.Setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "1")
		os.Setenv("CMUX_ORIGINAL_NODE_OPTIONS", existing)
	} else {
		os.Setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "0")
		os.Unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
	}
	os.Setenv("NODE_OPTIONS", mergeNodeOptions(existing, restoreModulePath))
}

func mergeNodeOptions(existing string, restoreModulePath string) string {
	requireFlag := "--require=" + restoreModulePath
	const memoryFlag = "--max-old-space-size=4096"
	cleaned := cleanedNodeOptions(existing)
	if cleaned == "" {
		return requireFlag + " " + memoryFlag
	}
	return requireFlag + " " + memoryFlag + " " + cleaned
}

func cleanedNodeOptions(existing string) string {
	tokens := strings.Fields(existing)
	if len(tokens) == 0 {
		return ""
	}

	filtered := make([]string, 0, len(tokens))
	for i := 0; i < len(tokens); i++ {
		token := tokens[i]
		if token == "--max-old-space-size" {
			if i+1 < len(tokens) {
				i++
			}
			continue
		}
		if strings.HasPrefix(token, "--max-old-space-size=") {
			continue
		}
		filtered = append(filtered, token)
	}
	return strings.Join(filtered, " ")
}

func stringFromAny(values ...any) string {
	for _, v := range values {
		if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}

// --- Environment configuration ---

type agentConfig struct {
	shimDir        string
	socketPath     string
	focused        *focusedContext
	tmuxPathPrefix string
	cmuxBinEnvVar  string
	termEnvVar     string
	extraEnv       map[string]string
}

func configureAgentEnvironment(cfg agentConfig) {
	// Find our own executable path for the shim to call back
	selfPath, _ := os.Executable()
	if selfPath == "" {
		selfPath = "cmux"
	}
	os.Setenv(cfg.cmuxBinEnvVar, selfPath)

	// Prepend shim directory to PATH
	currentPath := os.Getenv("PATH")
	os.Setenv("PATH", cfg.shimDir+":"+currentPath)

	// Set fake TMUX/TMUX_PANE
	fakeTmux := fmt.Sprintf("/tmp/%s/default,0,0", cfg.tmuxPathPrefix)
	fakeTmuxPane := "%1"
	if cfg.focused != nil {
		windowToken := cfg.focused.windowId
		if windowToken == "" {
			windowToken = cfg.focused.workspaceId
		}
		paneIdForToken := cfg.focused.paneId
		if paneIdForToken == "" {
			paneIdForToken = cfg.focused.paneHandle
		}
		paneToken := tmuxStableNumericId(paneIdForToken)
		fakeTmux = fmt.Sprintf("/tmp/%s/%s,%s,%s",
			cfg.tmuxPathPrefix, cfg.focused.workspaceId, windowToken, paneToken)
		fakeTmuxPane = "%" + paneToken
	}
	os.Setenv("TMUX", fakeTmux)
	os.Setenv("TMUX_PANE", fakeTmuxPane)

	// Terminal settings
	fakeTerm := os.Getenv(cfg.termEnvVar)
	if fakeTerm == "" {
		fakeTerm = "screen-256color"
	}
	os.Setenv("TERM", fakeTerm)

	// Socket path
	os.Setenv("CMUX_SOCKET_PATH", cfg.socketPath)
	os.Unsetenv("CMUX_SOCKET")

	// Unset TERM_PROGRAM so apps don't detect the host terminal and
	// override tmux-compatible behavior (e.g. opencode switches to
	// light theme when it sees TERM_PROGRAM=ghostty).
	os.Unsetenv("TERM_PROGRAM")

	// Preserve COLORTERM for truecolor support in subagent panes.
	if os.Getenv("COLORTERM") == "" {
		os.Setenv("COLORTERM", "truecolor")
	}

	// Set workspace/surface IDs from focused context
	if cfg.focused != nil {
		os.Setenv("CMUX_WORKSPACE_ID", cfg.focused.workspaceId)
		if cfg.focused.surfaceId != "" {
			os.Setenv("CMUX_SURFACE_ID", cfg.focused.surfaceId)
		}
	}

	// Extra environment variables
	for k, v := range cfg.extraEnv {
		os.Setenv(k, v)
	}
}

// --- oh-my-opencode plugin setup ---

const omoPluginName = "oh-my-opencode"
const omoSlimPluginName = "oh-my-opencode-slim"

func omoUserConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "opencode")
}

func omoShadowConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cmuxterm", "omo-config")
}

func omoSlimShadowConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cmuxterm", "omo-slim-config")
}

type opencodePluginSetup struct {
	pluginName                  string
	shadowDir                   string
	configFilenames             []string
	removePluginPackages        []string
	isolatedPackageManifestName string
	configurePlugin             func(shadowDir string) error
	installHint                 string
	installingLabel             string
	installedLabel              string
	installFailLabel            string
}

func ensureOpencodePlugin(searchPath string, setup opencodePluginSetup) error {
	userDir := omoUserConfigDir()
	shadowDir := setup.shadowDir

	if err := os.MkdirAll(shadowDir, 0755); err != nil {
		return fmt.Errorf("create shadow config dir: %w", err)
	}

	// Read user's opencode.json, add the plugin, write to shadow dir
	userJsonPath := filepath.Join(userDir, "opencode.json")
	shadowJsonPath := filepath.Join(shadowDir, "opencode.json")

	var config map[string]any
	if data, err := os.ReadFile(userJsonPath); err == nil {
		if err := json.Unmarshal(data, &config); err != nil {
			return fmt.Errorf("invalid opencode.json: fix the JSON syntax and retry")
		}
	} else {
		config = map[string]any{}
	}

	// Add the requested OpenCode plugin to the plugins list.
	var plugins []string
	if raw, ok := config["plugin"].([]any); ok {
		for _, p := range raw {
			if s, ok := p.(string); ok {
				if !openCodePluginSpecMatchesAnyPackage(s, setup.removePluginPackages) {
					plugins = append(plugins, s)
				}
			}
		}
	}
	alreadyPresent := false
	for _, p := range plugins {
		if p == setup.pluginName || strings.HasPrefix(p, setup.pluginName+"@") {
			alreadyPresent = true
			break
		}
	}
	if !alreadyPresent {
		plugins = append(plugins, setup.pluginName)
	}
	config["plugin"] = plugins

	output, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(shadowJsonPath, output, 0644); err != nil {
		return err
	}

	// Symlink node_modules from user config dir
	shadowNodeModules := filepath.Join(shadowDir, "node_modules")
	userNodeModules := filepath.Join(userDir, "node_modules")
	if dirExists(userNodeModules) {
		target, _ := os.Readlink(shadowNodeModules)
		if target != userNodeModules {
			os.Remove(shadowNodeModules)
			os.Symlink(userNodeModules, shadowNodeModules)
		}
	}

	if setup.isolatedPackageManifestName != "" {
		if err := ensureOpencodeShadowPackageManifest(shadowDir, setup.pluginName, setup.isolatedPackageManifestName); err != nil {
			return err
		}
		bunLockPath := filepath.Join(shadowDir, "bun.lock")
		if target, err := os.Readlink(bunLockPath); err == nil && target != "" {
			if err := os.Remove(bunLockPath); err != nil {
				return fmt.Errorf("remove shadow bun.lock symlink: %w", err)
			}
		}
	} else {
		// Symlink package.json and bun.lock
		for _, filename := range []string{"package.json", "bun.lock"} {
			userFile := filepath.Join(userDir, filename)
			shadowFile := filepath.Join(shadowDir, filename)
			if fileExists(userFile) && !fileExists(shadowFile) {
				os.Symlink(userFile, shadowFile)
			}
		}
	}

	// Symlink plugin config files.
	for _, filename := range setup.configFilenames {
		userFile := filepath.Join(userDir, filename)
		shadowFile := filepath.Join(shadowDir, filename)
		if fileExists(userFile) && !fileExists(shadowFile) {
			os.Symlink(userFile, shadowFile)
		}
	}

	// Install the plugin if not available
	pluginPackageDir := filepath.Join(shadowNodeModules, setup.pluginName)
	if !dirExists(pluginPackageDir) {
		installDir := userDir
		if setup.isolatedPackageManifestName != "" {
			installDir = shadowDir
			os.Remove(shadowNodeModules)
		} else if !dirExists(userNodeModules) {
			installDir = shadowDir
			os.Remove(shadowNodeModules) // Remove symlink so we can install directly
		}
		os.MkdirAll(installDir, 0755)

		bunPath := findExecutableInPath("bun", searchPath, "")
		npmPath := findExecutableInPath("npm", searchPath, "")
		if bunPath == "" && npmPath == "" {
			return fmt.Errorf("neither bun nor npm found in PATH. %s", setup.installHint)
		}

		fmt.Fprintf(os.Stderr, "%s\n", setup.installingLabel)
		var cmd *exec.Cmd
		if bunPath != "" {
			cmd = exec.Command(bunPath, "add", setup.pluginName)
		} else {
			cmd = exec.Command(npmPath, "install", setup.pluginName)
		}
		cmd.Dir = installDir
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("%s: %v\n%s", setup.installFailLabel, err, setup.installHint)
		}
		fmt.Fprintf(os.Stderr, "%s\n", setup.installedLabel)

		// Re-create symlink if we installed into user dir
		if installDir == userDir && !fileExists(shadowNodeModules) {
			os.Symlink(userNodeModules, shadowNodeModules)
		}
	}

	if setup.configurePlugin != nil {
		if err := setup.configurePlugin(shadowDir); err != nil {
			return err
		}
	}

	os.Setenv("OPENCODE_CONFIG_DIR", shadowDir)
	return nil
}

func ensureOpencodeShadowPackageManifest(shadowDir string, pluginName string, manifestName string) error {
	packagePath := filepath.Join(shadowDir, "package.json")
	if target, err := os.Readlink(packagePath); err == nil && target != "" {
		if err := os.Remove(packagePath); err != nil {
			return fmt.Errorf("remove shadow package.json symlink: %w", err)
		}
	}
	manifest := map[string]any{
		"name":    manifestName,
		"private": true,
		"dependencies": map[string]string{
			pluginName: "latest",
		},
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal shadow package.json: %w", err)
	}
	existing, _ := os.ReadFile(packagePath)
	if string(existing) == string(data) {
		return nil
	}
	if err := os.WriteFile(packagePath, data, 0644); err != nil {
		return fmt.Errorf("write shadow package.json: %w", err)
	}
	return nil
}

func openCodePluginSpecMatchesAnyPackage(spec string, packageNames []string) bool {
	for _, packageName := range packageNames {
		if spec == packageName || strings.HasPrefix(spec, packageName+"@") {
			return true
		}
	}
	return false
}

// omoEnsurePlugin creates a shadow config directory that layers the
// oh-my-opencode plugin on top of the user's opencode config, installs
// the plugin if needed, and sets OPENCODE_CONFIG_DIR.
func omoEnsurePlugin(searchPath string) error {
	return ensureOpencodePlugin(searchPath, opencodePluginSetup{
		pluginName:      omoPluginName,
		shadowDir:       omoShadowConfigDir(),
		configFilenames: []string{"oh-my-opencode.json", "oh-my-opencode.jsonc"},
		removePluginPackages: []string{
			omoSlimPluginName,
		},
		configurePlugin:  configureOMOPlugin,
		installHint:      "Install oh-my-opencode manually: bunx oh-my-opencode install",
		installingLabel:  "Installing oh-my-opencode plugin...",
		installedLabel:   "oh-my-opencode plugin installed",
		installFailLabel: "failed to install oh-my-opencode",
	})
}

func omoSlimEnsurePlugin(searchPath string) error {
	if err := ensureOpencodePlugin(searchPath, opencodePluginSetup{
		pluginName:      omoSlimPluginName,
		shadowDir:       omoSlimShadowConfigDir(),
		configFilenames: []string{"oh-my-opencode-slim.json", "oh-my-opencode-slim.jsonc"},
		removePluginPackages: []string{
			omoPluginName,
			"oh-my-openagent",
		},
		isolatedPackageManifestName: "cmux-omo-slim-shadow",
		configurePlugin:             configureOMOSlimPlugin,
		installHint:                 "Install oh-my-opencode-slim manually: bunx oh-my-opencode-slim@latest install",
		installingLabel:             "Installing oh-my-opencode-slim plugin...",
		installedLabel:              "oh-my-opencode-slim plugin installed",
		installFailLabel:            "failed to install oh-my-opencode-slim",
	}); err != nil {
		return err
	}
	return writeRemoteOpenCodeSessionPlugin(omoSlimShadowConfigDir())
}

func configureOMOPlugin(shadowDir string) error {
	omoConfigPath := filepath.Join(shadowDir, "oh-my-opencode.json")
	var omoConfig map[string]any
	omoConfig, _ = readJSONConfigFile(omoConfigPath, false)
	if omoConfig == nil {
		omoConfig, _ = readJSONConfigFile(filepath.Join(omoUserConfigDir(), "oh-my-opencode.json"), false)
	}
	if omoConfig == nil {
		omoConfig, _ = readJSONConfigFile(filepath.Join(omoUserConfigDir(), "oh-my-opencode.jsonc"), true)
	}
	if omoConfig == nil {
		omoConfig = map[string]any{}
	}

	tmuxConfig, _ := omoConfig["tmux"].(map[string]any)
	if tmuxConfig == nil {
		tmuxConfig = map[string]any{}
	}
	needsWrite := false
	if enabled, _ := tmuxConfig["enabled"].(bool); !enabled {
		tmuxConfig["enabled"] = true
		needsWrite = true
	}
	if tmuxConfig["main_pane_min_width"] == nil {
		tmuxConfig["main_pane_min_width"] = 60
		needsWrite = true
	}
	if tmuxConfig["agent_pane_min_width"] == nil {
		tmuxConfig["agent_pane_min_width"] = 30
		needsWrite = true
	}
	if tmuxConfig["main_pane_size"] == nil {
		tmuxConfig["main_pane_size"] = 50
		needsWrite = true
	}
	if needsWrite {
		omoConfig["tmux"] = tmuxConfig
		// Remove symlink if it exists
		if target, err := os.Readlink(omoConfigPath); err == nil && target != "" {
			if err := os.Remove(omoConfigPath); err != nil {
				return fmt.Errorf("replace symlinked omo config: %w", err)
			}
		}
		data, err := json.MarshalIndent(omoConfig, "", "  ")
		if err != nil {
			return fmt.Errorf("marshal omo config: %w", err)
		}
		if err := os.WriteFile(omoConfigPath, data, 0644); err != nil {
			return fmt.Errorf("write omo config: %w", err)
		}
	}

	return nil
}

func configureOMOSlimPlugin(shadowDir string) error {
	configPath := filepath.Join(shadowDir, "oh-my-opencode-slim.json")
	var slimConfig map[string]any
	slimConfig, _ = readJSONConfigFile(configPath, false)
	if slimConfig == nil {
		userDir := omoUserConfigDir()
		candidates := []struct {
			path          string
			allowComments bool
		}{
			{filepath.Join(userDir, "oh-my-opencode-slim.json"), false},
			{filepath.Join(shadowDir, "oh-my-opencode-slim.jsonc"), true},
			{filepath.Join(userDir, "oh-my-opencode-slim.jsonc"), true},
		}
		for _, candidate := range candidates {
			if existing, _ := readJSONConfigFile(candidate.path, candidate.allowComments); existing != nil {
				slimConfig = existing
				break
			}
		}
	}
	if slimConfig == nil {
		slimConfig = map[string]any{}
	}

	muxConfig, _ := slimConfig["multiplexer"].(map[string]any)
	if muxConfig == nil {
		muxConfig = map[string]any{}
	}
	needsWrite := false
	if muxConfig["type"] != "tmux" {
		muxConfig["type"] = "tmux"
		needsWrite = true
	}
	if muxConfig["layout"] == nil {
		muxConfig["layout"] = "main-vertical"
		needsWrite = true
	}
	if muxConfig["main_pane_size"] == nil {
		muxConfig["main_pane_size"] = 60
		needsWrite = true
	}
	if needsWrite {
		slimConfig["multiplexer"] = muxConfig
		if target, err := os.Readlink(configPath); err == nil && target != "" {
			if err := os.Remove(configPath); err != nil {
				return fmt.Errorf("replace symlinked omo-slim config: %w", err)
			}
		}
		data, err := json.MarshalIndent(slimConfig, "", "  ")
		if err != nil {
			return fmt.Errorf("marshal omo-slim config: %w", err)
		}
		if err := os.WriteFile(configPath, data, 0644); err != nil {
			return fmt.Errorf("write omo-slim config: %w", err)
		}
	}

	return nil
}

func readJSONConfigFile(path string, allowComments bool) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := string(data)
	if allowComments {
		text = stripJSONComments(text)
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(text), &config); err != nil {
		return nil, err
	}
	return config, nil
}

func stripJSONComments(input string) string {
	var b strings.Builder
	inString := false
	escaping := false
	for i := 0; i < len(input); i++ {
		ch := input[i]
		if inString {
			b.WriteByte(ch)
			if escaping {
				escaping = false
			} else if ch == '\\' {
				escaping = true
			} else if ch == '"' {
				inString = false
			}
			continue
		}
		if ch == '"' {
			inString = true
			b.WriteByte(ch)
			continue
		}
		if ch == '/' && i+1 < len(input) {
			next := input[i+1]
			if next == '/' {
				i += 2
				for i < len(input) && input[i] != '\n' {
					i++
				}
				if i < len(input) {
					b.WriteByte(input[i])
				}
				continue
			}
			if next == '*' {
				i += 2
				for i+1 < len(input) && !(input[i] == '*' && input[i+1] == '/') {
					i++
				}
				if i+1 < len(input) {
					i++
				}
				continue
			}
		}
		b.WriteByte(ch)
	}
	return b.String()
}

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// --- Node script resolution ---

// resolveNodeScriptExec checks if the target binary is a #!/usr/bin/env node
// script. If node isn't in PATH but bun is, it rewrites the exec to use bun
// as the runtime (bun is node-compatible).
func resolveNodeScriptExec(binPath string, args []string, searchPath string, skipDir string) (string, []string) {
	if !isNodeScript(binPath) {
		return binPath, append([]string{binPath}, args...)
	}

	// node in PATH? Use the script directly.
	if findExecutableInPath("node", searchPath, skipDir) != "" {
		return binPath, append([]string{binPath}, args...)
	}

	// Fall back to bun as a node-compatible runtime.
	bunPath := findExecutableInPath("bun", searchPath, skipDir)
	if bunPath != "" {
		return bunPath, append([]string{bunPath, binPath}, args...)
	}

	// No node or bun; exec the script directly and let the OS error.
	return binPath, append([]string{binPath}, args...)
}

func isNodeScript(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 64)
	n, _ := f.Read(buf)
	line := string(buf[:n])
	return strings.Contains(line, "/env node") || strings.Contains(line, "/bin/node")
}

// --- Executable resolution ---

// findExecutableInPath searches the given PATH string for an executable,
// skipping skipDir (the shim directory). Takes an explicit PATH to ensure
// we search the original PATH before environment modifications.
func findExecutableInPath(name string, pathEnv string, skipDir string) string {
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" || dir == skipDir {
			continue
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return candidate
		}
	}
	return ""
}

// --- Claude Teams launch args ---

func claudeTeamsLaunchArgs(args []string) []string {
	// Check if --teammate-mode is already specified
	for _, arg := range args {
		if arg == "--teammate-mode" || strings.HasPrefix(arg, "--teammate-mode=") {
			return args
		}
	}
	return append([]string{"--teammate-mode", "auto"}, args...)
}
