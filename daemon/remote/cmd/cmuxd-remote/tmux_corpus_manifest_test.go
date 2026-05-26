package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestTmuxCorpusPRLaneSourcesExerciseRuntimeBehavior(t *testing.T) {
	cases := []struct {
		source string
		run    func(*testing.T)
	}{
		{"regress/command-order.sh", assertTmuxCorpusCommandOrder},
		{"regress/control-client-sanity.sh", assertTmuxCorpusHasSession},
		{"regress/control-client-size.sh", assertTmuxCorpusResizePane},
		{"regress/format-strings.sh", assertTmuxCorpusFormatStrings},
		{"regress/has-session-return.sh", assertTmuxCorpusHasSession},
		{"regress/input-keys.sh", assertTmuxCorpusSendKeys},
		{"regress/new-session-command.sh", assertTmuxCorpusCommandOrder},
		{"regress/new-session-environment.sh", assertTmuxCorpusPTYEnvironment},
		{"regress/new-session-no-client.sh", assertTmuxCorpusDetachedWorkspaceCreation},
		{"regress/new-session-size.sh", assertTmuxCorpusPTYSizeNormalization},
		{"regress/new-window-command.sh", assertTmuxCorpusCommandOrder},
		{"regress/session-group-resize.sh", assertTmuxCorpusResizePane},
	}

	for _, tc := range cases {
		t.Run(tc.source, tc.run)
	}
}

func assertTmuxCorpusCommandOrder(t *testing.T) {
	t.Helper()

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "new-session", []string{"-d", "-s", "build", "-c", "/tmp", "echo one"}); err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "new-window", []string{"-d", "-n", "test", "echo two"}); err != nil {
		t.Fatalf("new-window: %v", err)
	}

	wantOrder := []string{
		"workspace.create",
		"workspace.rename",
		"surface.list",
		"surface.send_text",
		"workspace.create",
		"workspace.rename",
		"surface.list",
		"surface.send_text",
	}
	if methods := recorder.methods(); !reflect.DeepEqual(methods, wantOrder) {
		t.Fatalf("RPC methods = %v, want %v", methods, wantOrder)
	}

	sendRequests := recorder.requestsFor("surface.send_text")
	if len(sendRequests) != 2 {
		t.Fatalf("surface.send_text requests = %d, want 2", len(sendRequests))
	}
	if got := sendRequests[0].Params["text"]; got != "cd -- '/tmp' && echo one\r" {
		t.Fatalf("new-session send text = %q", got)
	}
	if got := sendRequests[1].Params["text"]; got != "echo two\r" {
		t.Fatalf("new-window send text = %q", got)
	}
}

func assertTmuxCorpusDetachedWorkspaceCreation(t *testing.T) {
	t.Helper()

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "new-session", []string{"-d", "-s", "detached", "echo detached"}); err != nil {
		t.Fatalf("new-session -d: %v", err)
	}

	createRequests := recorder.requestsFor("workspace.create")
	if len(createRequests) != 1 {
		t.Fatalf("workspace.create requests = %d, want 1", len(createRequests))
	}
	if got := createRequests[0].Params["focus"]; got != false {
		t.Fatalf("detached new-session focus = %v, want false", got)
	}
}

func assertTmuxCorpusHasSession(t *testing.T) {
	t.Helper()

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "has-session", []string{"-t", "main"}); err != nil {
		t.Fatalf("has-session existing workspace: %v", err)
	}
	err := dispatchTmuxCommand(rc, "has-session", []string{"-t", "missing"})
	if err == nil {
		t.Fatal("has-session should fail for a missing workspace")
	}
	if !strings.Contains(err.Error(), "workspace not found") {
		t.Fatalf("has-session error = %q, want workspace not found", err.Error())
	}
}

func assertTmuxCorpusSendKeys(t *testing.T) {
	t.Helper()

	tests := []struct {
		tokens  []string
		literal bool
		want    string
	}{
		{tokens: []string{"printf", "ok", "Enter"}, want: "printf ok\r"},
		{tokens: []string{"C-c", "C-d", "C-z", "C-l"}, want: "\x03\x04\x1a\x0c"},
		{tokens: []string{"Escape", "Tab", "BSpace"}, want: "\x1b\t\x7f"},
		{tokens: []string{"Enter", "C-c", "plain"}, literal: true, want: "Enter C-c plain"},
	}
	for _, tt := range tests {
		if got := tmuxSendKeysText(tt.tokens, tt.literal); got != tt.want {
			t.Fatalf("tmuxSendKeysText(%v, literal=%v) = %q, want %q", tt.tokens, tt.literal, got, tt.want)
		}
	}
}

func assertTmuxCorpusFormatStrings(t *testing.T) {
	t.Helper()

	ctx := map[string]string{
		"session_name": "cmux",
		"window_id":    "@workspace",
		"window_name":  "Build",
		"pane_id":      "%pane",
		"pane_width":   "120",
		"pane_height":  "40",
	}

	tests := []struct {
		format   string
		fallback string
		want     string
	}{
		{format: "#{session_name}:#{window_name}:#{pane_id}", want: "cmux:Build:%pane"},
		{format: "#{window_id} #{pane_width}x#{pane_height}", want: "@workspace 120x40"},
		{format: "#{unknown}#{also_unknown}", fallback: "fallback", want: "fallback"},
	}
	for _, tt := range tests {
		if got := tmuxRenderFormat(tt.format, ctx, tt.fallback); got != tt.want {
			t.Fatalf("tmuxRenderFormat(%q) = %q, want %q", tt.format, got, tt.want)
		}
	}
}

func assertTmuxCorpusResizePane(t *testing.T) {
	t.Helper()

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "100"}); err != nil {
		t.Fatalf("resize-pane absolute width: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-L", "-x", "7"}); err != nil {
		t.Fatalf("resize-pane directional: %v", err)
	}

	resizeRequests := recorder.requestsFor("pane.resize")
	if len(resizeRequests) != 2 {
		t.Fatalf("pane.resize requests = %d, want 2", len(resizeRequests))
	}
	if got := resizeRequests[0].Params["direction"]; got != "right" {
		t.Fatalf("absolute resize direction = %v, want right", got)
	}
	if got := asInt(t, resizeRequests[0].Params["amount"], "absolute resize amount"); got != 160 {
		t.Fatalf("absolute resize amount = %v, want 160", got)
	}
	if got := resizeRequests[1].Params["direction"]; got != "left" {
		t.Fatalf("directional resize direction = %v, want left", got)
	}
	if got := asInt(t, resizeRequests[1].Params["amount"], "directional resize amount"); got != 7 {
		t.Fatalf("directional resize amount = %v, want 7", got)
	}
}

func assertTmuxCorpusPTYEnvironment(t *testing.T) {
	t.Helper()

	for _, key := range []string{"SHELL", "COLORTERM", "TERM_PROGRAM", "LANG", "LC_CTYPE", "LC_ALL"} {
		t.Setenv(key, "")
	}

	env := strings.Join(defaultWebSocketPTYEnv("/bin/sh"), "\n")
	for _, want := range []string{
		"SHELL=/bin/sh",
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"LANG=C.UTF-8",
		"CMUX_REMOTE_TRANSPORT=ws",
	} {
		if !strings.Contains(env, want) {
			t.Fatalf("PTY environment missing %q in %q", want, env)
		}
	}
}

func assertTmuxCorpusPTYSizeNormalization(t *testing.T) {
	t.Helper()

	cols, rows := normalizePTYSize(0, 0)
	if cols != defaultPTYCols || rows != defaultPTYRows {
		t.Fatalf("default PTY size = %dx%d, want %dx%d", cols, rows, defaultPTYCols, defaultPTYRows)
	}
	cols, rows = normalizePTYSize(maxPTYDimension+1, maxPTYDimension+1)
	if cols != maxPTYDimension || rows != maxPTYDimension {
		t.Fatalf("clamped PTY size = %dx%d, want %dx%d", cols, rows, maxPTYDimension, maxPTYDimension)
	}
}
