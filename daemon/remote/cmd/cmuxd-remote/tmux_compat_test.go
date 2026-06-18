package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
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

func TestTmuxDisplayReporterFormatFields(t *testing.T) {
	origHome := os.Getenv("HOME")
	origWorkspace := os.Getenv("CMUX_WORKSPACE_ID")
	origSurface := os.Getenv("CMUX_SURFACE_ID")
	origPane := os.Getenv("TMUX_PANE")
	os.Setenv("HOME", t.TempDir())
	os.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	os.Setenv("CMUX_SURFACE_ID", "surface:1")
	leaderPaneToken := "%" + tmuxStableNumericId("33333333-3333-4333-8333-333333333333")
	os.Setenv("TMUX_PANE", leaderPaneToken)
	defer func() {
		os.Setenv("HOME", origHome)
		if origWorkspace != "" {
			os.Setenv("CMUX_WORKSPACE_ID", origWorkspace)
		} else {
			os.Unsetenv("CMUX_WORKSPACE_ID")
		}
		if origSurface != "" {
			os.Setenv("CMUX_SURFACE_ID", origSurface)
		} else {
			os.Unsetenv("CMUX_SURFACE_ID")
		}
		if origPane != "" {
			os.Setenv("TMUX_PANE", origPane)
		} else {
			os.Unsetenv("TMUX_PANE")
		}
	}()

	sockPath := startMockTmuxCompatSocket(t)
	rc := &rpcContext{socketPath: sockPath}
	fields := []string{
		"session_id",
		"session_name",
		"window_index",
		"window_id",
		"pane_id",
		"pane_width",
		"pane_height",
		"window_width",
		"window_height",
		"pane_current_path",
		"pane_active",
		"window_active",
		"session_attached",
	}
	parts := make([]string, 0, len(fields))
	for _, field := range fields {
		parts = append(parts, field+"=#{"+field+"}")
	}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "display-message", []string{
			"-p",
			"-F", strings.Join(parts, "\t"),
			"-t", leaderPaneToken,
		}); err != nil {
			t.Fatalf("display-message: %v", err)
		}
	})

	values := map[string]string{}
	for _, part := range strings.Split(strings.TrimSpace(output), "\t") {
		key, value, ok := strings.Cut(part, "=")
		if !ok {
			t.Fatalf("malformed field %q in output %q", part, output)
		}
		values[key] = value
	}
	for _, field := range fields {
		if _, ok := values[field]; !ok {
			t.Fatalf("missing field %q in output %q", field, output)
		}
	}

	assertTmuxFieldMatch(t, values["session_id"], `^\$[0-9]+$`, "session_id")
	if values["session_name"] != "cmux" {
		t.Fatalf("session_name = %q, want cmux", values["session_name"])
	}
	assertTmuxFieldMatch(t, values["window_index"], `^[0-9]+$`, "window_index")
	assertTmuxFieldMatch(t, values["window_id"], `^@[0-9]+$`, "window_id")
	assertTmuxFieldMatch(t, values["pane_id"], `^%[0-9]+$`, "pane_id")
	assertTmuxFieldMatch(t, values["pane_width"], `^[0-9]+$`, "pane_width")
	assertTmuxFieldMatch(t, values["pane_height"], `^[0-9]+$`, "pane_height")
	assertTmuxFieldMatch(t, values["window_width"], `^[0-9]+$`, "window_width")
	assertTmuxFieldMatch(t, values["window_height"], `^[0-9]+$`, "window_height")
	if !filepath.IsAbs(values["pane_current_path"]) {
		t.Fatalf("pane_current_path = %q, want an absolute path", values["pane_current_path"])
	}
	if values["pane_active"] != "1" {
		t.Fatalf("pane_active = %q, want 1 for stringy focused metadata", values["pane_active"])
	}
	assertTmuxFieldMatch(t, values["pane_active"], `^[01]$`, "pane_active")
	assertTmuxFieldMatch(t, values["window_active"], `^[01]$`, "window_active")
	assertTmuxFieldMatch(t, values["session_attached"], `^[01]$`, "session_attached")
}

func assertTmuxFieldMatch(t *testing.T, got string, pattern string, field string) {
	t.Helper()
	if !regexp.MustCompile(pattern).MatchString(got) {
		t.Fatalf("%s = %q, want match %s", field, got, pattern)
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
		{"%abc123", "%abc123"},
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
		"TERM", "CMUX_SOCKET_PATH", "TERM_PROGRAM",
		"CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
		"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "COLORTERM",
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
		shimDir:    "/tmp/test-shim",
		socketPath: "127.0.0.1:54321",
		focused: &focusedContext{
			workspaceId: "ws-abc",
			windowId:    "win-123",
			paneHandle:  "pane:456",
			paneId:      "pane-456",
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
	wantPane := "%" + tmuxStableNumericId("pane-456")
	if os.Getenv("TMUX_PANE") != wantPane {
		t.Errorf("TMUX_PANE = %q, want %s", os.Getenv("TMUX_PANE"), wantPane)
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

func TestGetFocusedContextCanonicalizesPaneRef(t *testing.T) {
	sockPath := startMockTmuxCompatSocket(t)
	rc := &rpcContext{socketPath: sockPath}

	focused := getFocusedContext(rc)
	if focused == nil {
		t.Fatal("getFocusedContext returned nil")
	}
	if focused.paneHandle != "pane:1" {
		t.Fatalf("paneHandle = %q, want pane:1", focused.paneHandle)
	}
	if focused.paneId != "33333333-3333-4333-8333-333333333333" {
		t.Fatalf("paneId = %q, want canonical pane UUID", focused.paneId)
	}
}

func TestGetFocusedContextKeepsBaseContextWhenCanonicalizationTimesOut(t *testing.T) {
	sockPath := startSlowFocusedCanonicalizationSocket(t, 200*time.Millisecond)
	rc := &rpcContext{socketPath: sockPath}

	focused := getFocusedContextWithTimeout(rc, 50*time.Millisecond)
	if focused == nil {
		t.Fatal("getFocusedContextWithTimeout returned nil")
	}
	if focused.workspaceId != "11111111-1111-4111-8111-111111111111" {
		t.Fatalf("workspaceId = %q", focused.workspaceId)
	}
	if focused.paneHandle != "pane:1" {
		t.Fatalf("paneHandle = %q, want pane:1", focused.paneHandle)
	}
	if focused.paneId != "pane:1" {
		t.Fatalf("paneId = %q, want base pane id when canonicalization times out", focused.paneId)
	}
}

func TestTmuxSigiledSelectorsSkipRefsAndIndexes(t *testing.T) {
	sockPath := startMockTmuxCompatSocket(t)
	rc := &rpcContext{socketPath: sockPath}
	workspaceId := "11111111-1111-4111-8111-111111111111"
	paneId := "33333333-3333-4333-8333-333333333333"

	if got, err := tmuxResolveWorkspaceId(rc, "1"); err != nil || got != workspaceId {
		t.Fatalf("unsigiled workspace index resolved to %q, %v; want %s", got, err, workspaceId)
	}
	if got, err := tmuxCanonicalPaneId(rc, "1", workspaceId); err != nil || got != paneId {
		t.Fatalf("unsigiled pane index resolved to %q, %v; want %s", got, err, paneId)
	}
	if _, err := tmuxResolveWorkspaceId(rc, "$1"); err == nil {
		t.Fatal("sigiled workspace selector $1 resolved by index; want no match")
	}
	if _, err := tmuxCanonicalPaneId(rc, "%1", workspaceId); err == nil {
		t.Fatal("sigiled pane selector %1 resolved by index; want no match")
	}
	if got, err := tmuxResolveWorkspaceId(rc, "$"+tmuxStableNumericId(workspaceId)); err != nil || got != workspaceId {
		t.Fatalf("sigiled workspace numeric id resolved to %q, %v; want %s", got, err, workspaceId)
	}
	if got, err := tmuxCanonicalPaneId(rc, "%"+tmuxStableNumericId(paneId), workspaceId); err != nil || got != paneId {
		t.Fatalf("sigiled pane numeric id resolved to %q, %v; want %s", got, err, paneId)
	}
}

func TestTmuxResolveWorkspaceIdAcceptsSigiledUUIDWithoutList(t *testing.T) {
	workspaceId := "11111111-1111-4111-8111-111111111111"
	rc := &rpcContext{socketPath: filepath.Join(t.TempDir(), "missing.sock")}

	for _, raw := range []string{"$" + workspaceId, "@" + workspaceId} {
		got, err := tmuxResolveWorkspaceId(rc, raw)
		if err != nil {
			t.Fatalf("tmuxResolveWorkspaceId(%q) returned error: %v", raw, err)
		}
		if got != workspaceId {
			t.Fatalf("tmuxResolveWorkspaceId(%q) = %q, want %s", raw, got, workspaceId)
		}
	}
}

func TestTmuxCanonicalSelectorsPreferRefsBeforeIndexFallback(t *testing.T) {
	sockPath := startMockTmuxSelectorPrioritySocket(t)
	rc := &rpcContext{socketPath: sockPath}
	workspaceId := "11111111-1111-4111-8111-111111111111"
	refPaneId := "33333333-3333-4333-8333-333333333333"
	refSurfaceId := "55555555-5555-4555-8555-555555555555"

	if got, err := tmuxCanonicalPaneId(rc, "1", workspaceId); err != nil || got != refPaneId {
		t.Fatalf("pane selector resolved to %q, %v; want ref match %s before index fallback", got, err, refPaneId)
	}
	if got, err := tmuxCanonicalSurfaceId(rc, "1", workspaceId); err != nil || got != refSurfaceId {
		t.Fatalf("surface selector resolved to %q, %v; want ref match %s before index fallback", got, err, refSurfaceId)
	}
}

func startMockTmuxSelectorPrioritySocket(t *testing.T) string {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				line, err := reader.ReadBytes('\n')
				if err != nil {
					return
				}

				var req map[string]any
				if err := json.Unmarshal(line, &req); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}

				method, _ := req["method"].(string)
				resp := map[string]any{
					"id": req["id"],
					"ok": true,
				}
				switch method {
				case "pane.list":
					resp["result"] = map[string]any{
						"panes": []map[string]any{
							{"id": "22222222-2222-4222-8222-222222222222", "ref": "pane:index", "index": 1},
							{"id": "33333333-3333-4333-8333-333333333333", "ref": "1", "index": 2},
						},
					}
				case "surface.list":
					resp["result"] = map[string]any{
						"surfaces": []map[string]any{
							{"id": "44444444-4444-4444-8444-444444444444", "ref": "surface:index", "index": 1},
							{"id": "55555555-5555-4555-8555-555555555555", "ref": "1", "index": 2},
						},
					}
				default:
					resp["result"] = map[string]any{}
				}

				data, _ := json.Marshal(resp)
				_, _ = conn.Write(append(data, '\n'))
			}(conn)
		}
	}()

	return sockPath
}

func startSlowFocusedCanonicalizationSocket(t *testing.T, delay time.Duration) string {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				line, err := reader.ReadBytes('\n')
				if err != nil {
					return
				}

				var req map[string]any
				if err := json.Unmarshal(line, &req); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}

				method, _ := req["method"].(string)
				resp := map[string]any{
					"id": req["id"],
					"ok": true,
				}
				switch method {
				case "system.identify":
					resp["result"] = map[string]any{
						"focused": map[string]any{
							"workspace_id": "11111111-1111-4111-8111-111111111111",
							"pane_id":      "pane:1",
							"pane_ref":     "pane:1",
							"surface_ref":  "surface:1",
						},
					}
				case "pane.list":
					time.Sleep(delay)
					resp["result"] = map[string]any{
						"panes": []map[string]any{{
							"id":    "33333333-3333-4333-8333-333333333333",
							"ref":   "pane:1",
							"index": 1,
						}},
					}
				default:
					resp["result"] = map[string]any{}
				}

				data, _ := json.Marshal(resp)
				_, _ = conn.Write(append(data, '\n'))
			}(conn)
		}
	}()

	return sockPath
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

func TestMergeNodeOptions(t *testing.T) {
	const restoreModulePath = "/tmp/restore-node-options.cjs"

	if got := mergeNodeOptions("", restoreModulePath); got != "--require=/tmp/restore-node-options.cjs --max-old-space-size=4096" {
		t.Fatalf("mergeNodeOptions(\"\") = %q", got)
	}

	if got := mergeNodeOptions("--trace-warnings", restoreModulePath); got != "--require=/tmp/restore-node-options.cjs --max-old-space-size=4096 --trace-warnings" {
		t.Fatalf("mergeNodeOptions preserves existing flags = %q", got)
	}

	existing := "--max-old-space-size=2048 --trace-warnings"
	if got := mergeNodeOptions(existing, restoreModulePath); got != "--require=/tmp/restore-node-options.cjs --max-old-space-size=4096 --trace-warnings" {
		t.Fatalf("mergeNodeOptions should replace existing size flag = %q", got)
	}

	spaceSeparated := "--max-old-space-size 2048 --trace-warnings"
	if got := mergeNodeOptions(spaceSeparated, restoreModulePath); got != "--require=/tmp/restore-node-options.cjs --max-old-space-size=4096 --trace-warnings" {
		t.Fatalf("mergeNodeOptions should replace space-separated size flag = %q", got)
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
