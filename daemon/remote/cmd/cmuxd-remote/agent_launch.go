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
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createOMOShimDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux omo: failed to create shim directory: %v\n", err)
		return 1
	}

	// Resolve the agent executable BEFORE modifying PATH.
	originalPath := os.Getenv("PATH")
	opencodePath := findExecutableInPath("opencode", originalPath, shimDir)
	if opencodePath == "" {
		fmt.Fprintf(os.Stderr, "cmux omo: opencode not found in PATH\n"+
			"Install it first:\n  npm install -g opencode-ai\n  # or\n  bun install -g opencode-ai\n")
		return 1
	}

	// Ensure oh-my-openagent plugin is set up
	if err := omoEnsurePlugin(originalPath); err != nil {
		fmt.Fprintf(os.Stderr, "cmux omo: plugin setup: %v\n", err)
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: "cmux-omo",
		cmuxBinEnvVar:  "CMUX_OMO_CMUX_BIN",
		termEnvVar:     "CMUX_OMO_TERM",
		extraEnv:       map[string]string{},
	})

	// Set OPENCODE_PORT if not already set
	if os.Getenv("OPENCODE_PORT") == "" {
		os.Setenv("OPENCODE_PORT", "4096")
	}

	// Build launch arguments
	launchArgs := args
	hasPort := false
	for _, arg := range launchArgs {
		if arg == "--port" || strings.HasPrefix(arg, "--port=") {
			hasPort = true
			break
		}
	}
	if !hasPort {
		port := os.Getenv("OPENCODE_PORT")
		if port == "" {
			port = "4096"
		}
		launchArgs = append([]string{"--port", port}, launchArgs...)
	}

	launchPath, launchArgv := resolveNodeScriptExec(opencodePath, launchArgs, originalPath, shimDir)
	execErr := syscall.Exec(launchPath, launchArgv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux omo: exec failed: %v\n", execErr)
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
	surfaceId   string
}

func getFocusedContext(rc *rpcContext) *focusedContext {
	// Use a goroutine with timeout so a slow/stale relay doesn't block agent launch.
	type result struct {
		payload map[string]any
		err     error
	}
	ch := make(chan result, 1)
	go func() {
		p, e := rc.call("system.identify", nil)
		ch <- result{p, e}
	}()
	var payload map[string]any
	select {
	case r := <-ch:
		if r.err != nil {
			return nil
		}
		payload = r.payload
	case <-time.After(5 * time.Second):
		return nil
	}
	focused, _ := payload["focused"].(map[string]any)
	if focused == nil {
		return nil
	}

	wsId := stringFromAny(focused["workspace_id"], focused["workspace_ref"])
	paneId := stringFromAny(focused["pane_id"], focused["pane_ref"])
	if wsId == "" || paneId == "" {
		return nil
	}

	return &focusedContext{
		workspaceId: wsId,
		windowId:    stringFromAny(focused["window_id"], focused["window_ref"]),
		paneHandle:  strings.TrimSpace(paneId),
		surfaceId:   stringFromAny(focused["surface_id"], focused["surface_ref"]),
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
		fakeTmux = fmt.Sprintf("/tmp/%s/%s,%s,%s",
			cfg.tmuxPathPrefix, cfg.focused.workspaceId, windowToken, cfg.focused.paneHandle)
		fakeTmuxPane = "%" + cfg.focused.paneHandle
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
	os.Setenv("CMUX_SOCKET", cfg.socketPath)

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

// --- oh-my-openagent plugin setup ---

const omoPluginName = "oh-my-openagent"

func omoUserConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "opencode")
}

func omoShadowConfigDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cmuxterm", "omo-config")
}

// omoEnsurePlugin creates a shadow config directory that layers the
// oh-my-openagent plugin on top of the user's opencode config, installs
// the plugin if needed, and sets OPENCODE_CONFIG_DIR.
func omoEnsurePlugin(searchPath string) error {
	userDir := omoUserConfigDir()
	shadowDir := omoShadowConfigDir()

	if err := os.MkdirAll(shadowDir, 0755); err != nil {
		return fmt.Errorf("create shadow config dir: %w", err)
	}

	// Read user's opencode.json, add the plugin, write to shadow dir
	userJsonPath := filepath.Join(userDir, "opencode.json")
	shadowJsonPath := filepath.Join(shadowDir, "opencode.json")

	var config map[string]any
	if data, err := os.ReadFile(userJsonPath); err == nil {
		if err := json.Unmarshal(data, &config); err != nil {
			return fmt.Errorf("failed to parse %s: fix the JSON syntax and retry", userJsonPath)
		}
	} else {
		config = map[string]any{}
	}

	// Add oh-my-openagent to the plugins list
	var plugins []string
	if raw, ok := config["plugin"].([]any); ok {
		for _, p := range raw {
			if s, ok := p.(string); ok {
				plugins = append(plugins, s)
			}
		}
	}
	// Remove legacy oh-my-opencode entries to avoid duplicate plugin registration
	var cleaned []string
	for _, p := range plugins {
		if p != "oh-my-opencode" && !strings.HasPrefix(p, "oh-my-opencode@") {
			cleaned = append(cleaned, p)
		}
	}
	plugins = cleaned
	alreadyPresent := false
	for _, p := range plugins {
		if p == omoPluginName || strings.HasPrefix(p, omoPluginName+"@") {
			alreadyPresent = true
			break
		}
	}
	if !alreadyPresent {
		plugins = append(plugins, omoPluginName)
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

	// Symlink package.json and bun.lock
	for _, filename := range []string{"package.json", "bun.lock"} {
		userFile := filepath.Join(userDir, filename)
		shadowFile := filepath.Join(shadowDir, filename)
		if fileExists(userFile) && !fileExists(shadowFile) {
			os.Symlink(userFile, shadowFile)
		}
	}

	// Symlink oh-my-openagent config files
	for _, filename := range []string{"oh-my-openagent.json", "oh-my-openagent.jsonc"} {
		userFile := filepath.Join(userDir, filename)
		shadowFile := filepath.Join(shadowDir, filename)
		if fileExists(userFile) && !fileExists(shadowFile) {
			os.Symlink(userFile, shadowFile)
		}
	}

	// Install the plugin if not available
	pluginPackageDir := filepath.Join(shadowNodeModules, omoPluginName)
	if !dirExists(pluginPackageDir) {
		installDir := userDir
		if !dirExists(userNodeModules) {
			installDir = shadowDir
			os.Remove(shadowNodeModules) // Remove symlink so we can install directly
		}
		os.MkdirAll(installDir, 0755)

		bunPath := findExecutableInPath("bun", searchPath, "")
		npmPath := findExecutableInPath("npm", searchPath, "")
		if bunPath == "" && npmPath == "" {
			return fmt.Errorf("neither bun nor npm found in PATH. Install oh-my-openagent manually: bunx oh-my-openagent install")
		}

		fmt.Fprintf(os.Stderr, "Installing oh-my-openagent plugin...\n")
		var cmd *exec.Cmd
		if bunPath != "" {
			cmd = exec.Command(bunPath, "add", omoPluginName)
		} else {
			cmd = exec.Command(npmPath, "install", omoPluginName)
		}
		cmd.Dir = installDir
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("failed to install oh-my-openagent: %v\nTry manually: npm install -g oh-my-openagent", err)
		}
		fmt.Fprintf(os.Stderr, "oh-my-openagent plugin installed\n")

		// Re-create symlink if we installed into user dir
		if installDir == userDir && !fileExists(shadowNodeModules) {
			os.Symlink(userNodeModules, shadowNodeModules)
		}
	}

	// Configure oh-my-openagent.json with tmux settings
	omoConfigPath := filepath.Join(shadowDir, "oh-my-openagent.json")
	var omoConfig map[string]any
	if data, err := os.ReadFile(omoConfigPath); err == nil {
		json.Unmarshal(data, &omoConfig)
	}
	if omoConfig == nil {
		// Check if user had one we symlinked
		userOmoConfig := filepath.Join(userDir, "oh-my-openagent.json")
		if data, err := os.ReadFile(userOmoConfig); err == nil {
			json.Unmarshal(data, &omoConfig)
			os.Remove(omoConfigPath) // Remove symlink so we can write our own copy
		}
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
			os.Remove(omoConfigPath)
		}
		data, _ := json.MarshalIndent(omoConfig, "", "  ")
		os.WriteFile(omoConfigPath, data, 0644)
	}

	os.Setenv("OPENCODE_CONFIG_DIR", shadowDir)
	return nil
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
