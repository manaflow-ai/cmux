package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSplitTmuxCmd(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		wantCmd string
		wantN   int // expected number of remaining args
	}{
		{"simple", []string{"list-panes", "-t", "%abc"}, "list-panes", 2},
		{"version flag", []string{"-V"}, "-V", 0},
		{"with global flags", []string{"-L", "foo", "split-window", "-h"}, "split-window", 1},
		{"case insensitive", []string{"Display-Message", "-p"}, "display-message", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd, args, err := splitTmuxCmd(tt.args)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if cmd != tt.wantCmd {
				t.Errorf("command = %q, want %q", cmd, tt.wantCmd)
			}
			if len(args) != tt.wantN {
				t.Errorf("args count = %d, want %d", len(args), tt.wantN)
			}
		})
	}
}

func TestParseTmuxArgs(t *testing.T) {
	p := parseTmuxArgs(
		[]string{"-dP", "-t", "%abc", "-F", "#{pane_id}", "shell", "cmd"},
		[]string{"-t", "-F"},
		[]string{"-d", "-P"},
	)
	if !p.hasFlag("-d") {
		t.Error("expected -d flag")
	}
	if !p.hasFlag("-P") {
		t.Error("expected -P flag")
	}
	if p.value("-t") != "%abc" {
		t.Errorf("target = %q, want %%abc", p.value("-t"))
	}
	if p.value("-F") != "#{pane_id}" {
		t.Errorf("format = %q, want #{pane_id}", p.value("-F"))
	}
	if len(p.positional) != 2 || p.positional[0] != "shell" {
		t.Errorf("positional = %v, want [shell cmd]", p.positional)
	}
}

func TestParseTmuxArgsClusteredValueFlag(t *testing.T) {
	// -t%abc should parse -t with value "%abc"
	p := parseTmuxArgs([]string{"-t%abc"}, []string{"-t"}, nil)
	if p.value("-t") != "%abc" {
		t.Errorf("target = %q, want %%abc", p.value("-t"))
	}
}

func TestTmuxRenderFormat(t *testing.T) {
	ctx := map[string]string{
		"pane_id":    "%abc123",
		"pane_width": "80",
		"window_id":  "@ws1",
	}

	tests := []struct {
		format   string
		fallback string
		want     string
	}{
		{"#{pane_id}", "fallback", "%abc123"},
		{"#{pane_id}:#{pane_width}", "", "%abc123:80"},
		{"#{unknown_var}", "fallback", "fallback"},
		{"", "fallback", "fallback"},
		{"#{pane_id} #{pane_width} #{window_id}", "", "%abc123 80 @ws1"},
	}
	for _, tt := range tests {
		got := tmuxRenderFormat(tt.format, ctx, tt.fallback)
		if got != tt.want {
			t.Errorf("tmuxRenderFormat(%q) = %q, want %q", tt.format, got, tt.want)
		}
	}
}

func TestTmuxSendKeysText(t *testing.T) {
	tests := []struct {
		name    string
		tokens  []string
		literal bool
		want    string
	}{
		{"literal", []string{"hello", "world"}, true, "hello world"},
		{"special enter", []string{"echo", "hello", "Enter"}, false, "echo hello\r"},
		{"special ctrl-c", []string{"C-c"}, false, "\x03"},
		{"mixed", []string{"ls", "-la", "Enter"}, false, "ls -la\r"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tmuxSendKeysText(tt.tokens, tt.literal)
			if got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestTmuxShellCommandText(t *testing.T) {
	tests := []struct {
		positional []string
		cwd        string
		want       string
	}{
		{[]string{"echo hi"}, "", "echo hi\r"},
		{nil, "/tmp", "cd -- '/tmp'\r"},
		{[]string{"make"}, "/home/user", "cd -- '/home/user' && make\r"},
		{nil, "", ""},
	}
	for _, tt := range tests {
		got := tmuxShellCommandText(tt.positional, tt.cwd)
		if got != tt.want {
			t.Errorf("tmuxShellCommandText(%v, %q) = %q, want %q", tt.positional, tt.cwd, got, tt.want)
		}
	}
}

func TestTmuxWaitForSignalPath(t *testing.T) {
	path := tmuxWaitForSignalPath("test-signal")
	if !strings.HasPrefix(path, "/tmp/cmux-wait-for-") {
		t.Errorf("unexpected path prefix: %s", path)
	}
	if !strings.HasSuffix(path, ".sig") {
		t.Errorf("unexpected path suffix: %s", path)
	}
}

func TestTmuxCompatStoreRoundTrip(t *testing.T) {
	// Use a temp dir for the store
	tmpDir := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)
	defer os.Setenv("HOME", origHome)

	store := loadTmuxCompatStore()
	store.Buffers["test"] = "captured text"
	store.MainVerticalLayouts["ws1"] = mainVerticalState{
		MainSurfaceId:       "surface-main",
		LastColumnSurfaceId: "surface-col",
	}
	if err := saveTmuxCompatStore(store); err != nil {
		t.Fatalf("save: %v", err)
	}

	loaded := loadTmuxCompatStore()
	if loaded.Buffers["test"] != "captured text" {
		t.Errorf("buffer = %q, want %q", loaded.Buffers["test"], "captured text")
	}
	if mvs, ok := loaded.MainVerticalLayouts["ws1"]; !ok {
		t.Error("missing main vertical layout for ws1")
	} else if mvs.LastColumnSurfaceId != "surface-col" {
		t.Errorf("lastColumnSurfaceId = %q, want %q", mvs.LastColumnSurfaceId, "surface-col")
	}
}

func TestTmuxVersion(t *testing.T) {
	output := captureStdout(t, func() {
		dispatchTmuxCommand(nil, "-v", nil)
	})
	if strings.TrimSpace(output) != "tmux 3.4" {
		t.Errorf("version = %q, want %q", strings.TrimSpace(output), "tmux 3.4")
	}
}

func TestTmuxNoOps(t *testing.T) {
	noOps := []string{
		"set-option", "set", "set-window-option", "setw",
		"source-file", "refresh-client", "attach-session", "detach-client",
		"last-window", "next-window", "previous-window",
		"set-hook", "set-buffer", "list-buffers",
	}
	for _, cmd := range noOps {
		t.Run(cmd, func(t *testing.T) {
			if err := dispatchTmuxCommand(nil, cmd, nil); err != nil {
				t.Errorf("no-op %q returned error: %v", cmd, err)
			}
		})
	}
}

func TestTmuxUnsupportedCommand(t *testing.T) {
	err := dispatchTmuxCommand(nil, "some-unknown-cmd", nil)
	if err == nil {
		t.Error("expected error for unknown command")
	}
	if !strings.Contains(err.Error(), "unsupported") {
		t.Errorf("error = %q, want to contain 'unsupported'", err.Error())
	}
}

func TestIsUUIDish(t *testing.T) {
	if !isUUIDish("D88CE676-0A95-4DDA-AD94-E535B0D966DF") {
		t.Error("expected UUID to be detected")
	}
	if !isUUIDish("d88ce676-0a95-4dda-ad94-e535b0d966df") {
		t.Error("expected lowercase UUID to be detected")
	}
	if isUUIDish("not-a-uuid") {
		t.Error("expected non-UUID to be rejected")
	}
}

func TestTmuxPaneSelector(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"%abc123", "abc123"},
		{"pane:test", "pane:test"},
		{"@ws1.%pane2", "%pane2"},
		{"@ws1", ""},
		{"", ""},
	}
	for _, tt := range tests {
		got := tmuxPaneSelector(tt.input)
		if got != tt.want {
			t.Errorf("tmuxPaneSelector(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestTmuxWindowSelector(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"%abc123", ""},
		{"pane:test", ""},
		{"@ws1.%pane2", "@ws1"},
		{"@ws1", "@ws1"},
		{"", ""},
	}
	for _, tt := range tests {
		got := tmuxWindowSelector(tt.input)
		if got != tt.want {
			t.Errorf("tmuxWindowSelector(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestCreateTmuxShimDir(t *testing.T) {
	tmpDir := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)
	defer os.Setenv("HOME", origHome)

	dir, err := createTmuxShimDir("test-shim-bin", claudeTeamsShimScript)
	if err != nil {
		t.Fatalf("createTmuxShimDir: %v", err)
	}
	tmuxPath := filepath.Join(dir, "tmux")
	info, err := os.Stat(tmuxPath)
	if err != nil {
		t.Fatalf("tmux shim not found: %v", err)
	}
	if info.Mode()&0111 == 0 {
		t.Error("tmux shim is not executable")
	}
	content, _ := os.ReadFile(tmuxPath)
	if !strings.Contains(string(content), "__tmux-compat") {
		t.Error("shim script should reference __tmux-compat")
	}
}

func TestCreateOMOShimDir(t *testing.T) {
	tmpDir := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)
	defer os.Setenv("HOME", origHome)

	dir, err := createOMOShimDir()
	if err != nil {
		t.Fatalf("createOMOShimDir: %v", err)
	}
	// Check tmux shim exists
	tmuxPath := filepath.Join(dir, "tmux")
	if _, err := os.Stat(tmuxPath); err != nil {
		t.Fatalf("tmux shim not found: %v", err)
	}
	// Check terminal-notifier shim exists
	notifierPath := filepath.Join(dir, "terminal-notifier")
	if _, err := os.Stat(notifierPath); err != nil {
		t.Fatalf("terminal-notifier shim not found: %v", err)
	}
}

func TestConfigureAgentEnvironment(t *testing.T) {
	// Save and restore env vars
	envKeys := []string{
		"CMUX_CLAUDE_TEAMS_CMUX_BIN", "PATH", "TMUX", "TMUX_PANE",
		"TERM", "CMUX_SOCKET_PATH", "CMUX_SOCKET", "TERM_PROGRAM",
		"CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
		"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
	}
	saved := make(map[string]string)
	for _, k := range envKeys {
		saved[k] = os.Getenv(k)
	}
	defer func() {
		for k, v := range saved {
			if v != "" {
				os.Setenv(k, v)
			} else {
				os.Unsetenv(k)
			}
		}
	}()

	os.Setenv("TERM_PROGRAM", "should-be-removed")

	configureAgentEnvironment(agentConfig{
		shimDir:        "/tmp/test-shim",
		socketPath:     "127.0.0.1:54321",
		focused: &focusedContext{
			workspaceId: "ws-abc",
			windowId:    "win-123",
			paneHandle:  "pane-456",
			surfaceId:   "surf-789",
		},
		tmuxPathPrefix: "cmux-claude-teams",
		cmuxBinEnvVar:  "CMUX_CLAUDE_TEAMS_CMUX_BIN",
		termEnvVar:     "CMUX_CLAUDE_TEAMS_TERM",
		extraEnv: map[string]string{
			"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
		},
	})

	// Verify PATH was prepended
	if !strings.HasPrefix(os.Getenv("PATH"), "/tmp/test-shim:") {
		t.Error("PATH should start with shim dir")
	}
	// Verify TMUX is set with focused context
	tmux := os.Getenv("TMUX")
	if !strings.Contains(tmux, "ws-abc") {
		t.Errorf("TMUX = %q, should contain workspace ID", tmux)
	}
	// Verify TMUX_PANE
	if os.Getenv("TMUX_PANE") != "%pane-456" {
		t.Errorf("TMUX_PANE = %q, want %%pane-456", os.Getenv("TMUX_PANE"))
	}
	// Verify socket path
	if os.Getenv("CMUX_SOCKET_PATH") != "127.0.0.1:54321" {
		t.Errorf("CMUX_SOCKET_PATH = %q", os.Getenv("CMUX_SOCKET_PATH"))
	}
	// Verify COLORTERM is set for truecolor support
	if os.Getenv("COLORTERM") != "truecolor" {
		t.Errorf("COLORTERM = %q, want truecolor", os.Getenv("COLORTERM"))
	}
	// Verify workspace/surface IDs
	if os.Getenv("CMUX_WORKSPACE_ID") != "ws-abc" {
		t.Errorf("CMUX_WORKSPACE_ID = %q", os.Getenv("CMUX_WORKSPACE_ID"))
	}
	if os.Getenv("CMUX_SURFACE_ID") != "surf-789" {
		t.Errorf("CMUX_SURFACE_ID = %q", os.Getenv("CMUX_SURFACE_ID"))
	}
	// Verify extra env
	if os.Getenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS") != "1" {
		t.Error("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS should be 1")
	}
}

func TestClaudeTeamsLaunchArgs(t *testing.T) {
	// Should prepend --teammate-mode auto
	args := claudeTeamsLaunchArgs([]string{"--verbose"})
	if args[0] != "--teammate-mode" || args[1] != "auto" || args[2] != "--verbose" {
		t.Errorf("args = %v, want [--teammate-mode auto --verbose]", args)
	}

	// Should not duplicate if already present
	args = claudeTeamsLaunchArgs([]string{"--teammate-mode", "off"})
	if args[0] != "--teammate-mode" || args[1] != "off" {
		t.Errorf("args = %v, should not prepend when already present", args)
	}
}

func TestTmuxWaitForSignalRoundTrip(t *testing.T) {
	name := "test-roundtrip-" + randomHex(4)
	path := tmuxWaitForSignalPath(name)
	defer os.Remove(path)

	// Signal creates the file
	dispatchTmuxCommand(nil, "wait-for", []string{"-S", name})
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("signal file not created: %v", err)
	}

	// Wait consumes the file
	err := dispatchTmuxCommand(nil, "wait-for", []string{name})
	if err != nil {
		t.Fatalf("wait-for should succeed: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("signal file should be removed after wait")
	}
}

func TestTmuxShowBuffer(t *testing.T) {
	tmpDir := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmpDir)
	defer os.Setenv("HOME", origHome)

	store := loadTmuxCompatStore()
	store.Buffers["default"] = "hello world"
	saveTmuxCompatStore(store)

	output := captureStdout(t, func() {
		tmuxShowBuffer(nil)
	})
	if strings.TrimSpace(output) != "hello world" {
		t.Errorf("output = %q, want %q", output, "hello world")
	}
}
