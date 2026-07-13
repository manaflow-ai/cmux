package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
)

type tmuxCorpusRPCRequest struct {
	Method string
	Params map[string]any
}

type tmuxCorpusRPCRecorder struct {
	socketPath            string
	mu                    sync.Mutex
	requests              []tmuxCorpusRPCRequest
	workspaces            []map[string]any
	readText              string
	includePaneMetrics    bool
	includePointMetrics   bool
	includeContainerFrame bool
}

func startTmuxCorpusRPCRecorder(t *testing.T) *tmuxCorpusRPCRecorder {
	return startTmuxCorpusRPCRecorderWithMetricAvailability(t, true, true, true)
}

func startTmuxCorpusRPCRecorderWithPaneMetrics(t *testing.T, includePaneMetrics bool) *tmuxCorpusRPCRecorder {
	return startTmuxCorpusRPCRecorderWithMetricAvailability(
		t,
		includePaneMetrics,
		includePaneMetrics,
		includePaneMetrics,
	)
}

func startTmuxCorpusRPCRecorderWithMetricAvailability(
	t *testing.T,
	includePaneMetrics bool,
	includePointMetrics bool,
	includeContainerFrame bool,
) *tmuxCorpusRPCRecorder {
	t.Helper()

	recorder := &tmuxCorpusRPCRecorder{
		socketPath:            makeShortUnixSocketPath(t),
		includePaneMetrics:    includePaneMetrics,
		includePointMetrics:   includePointMetrics,
		includeContainerFrame: includeContainerFrame,
		workspaces: []map[string]any{{
			"id":    "11111111-1111-4111-8111-111111111111",
			"ref":   "workspace:1",
			"index": 1,
			"title": "main",
		}},
	}

	ln, err := net.Listen("unix", recorder.socketPath)
	if err != nil {
		t.Fatalf("listen tmux corpus rpc socket: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go recorder.serveConn(conn)
		}
	}()

	return recorder
}

func (r *tmuxCorpusRPCRecorder) serveConn(conn net.Conn) {
	defer conn.Close()

	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return
	}

	var req map[string]any
	if err := json.Unmarshal(line, &req); err != nil {
		_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
		return
	}

	method, _ := req["method"].(string)
	params, _ := req["params"].(map[string]any)

	r.mu.Lock()
	r.requests = append(r.requests, tmuxCorpusRPCRequest{Method: method, Params: cloneMap(params)})
	resp := map[string]any{
		"id": req["id"],
		"ok": true,
	}

	switch method {
	case "workspace.create":
		next := len(r.workspaces) + 1
		wsID := "22222222-2222-4222-8222-22222222222" + string(rune('0'+next))
		workspace := map[string]any{
			"id":    wsID,
			"ref":   "workspace:" + string(rune('0'+next)),
			"index": next,
			"title": "created",
		}
		r.workspaces = append(r.workspaces, workspace)
		resp["result"] = map[string]any{"workspace_id": wsID}
	case "workspace.rename":
		wsID, _ := params["workspace_id"].(string)
		title, _ := params["title"].(string)
		for _, workspace := range r.workspaces {
			if workspace["id"] == wsID {
				workspace["title"] = title
				break
			}
		}
		resp["result"] = map[string]any{"ok": true}
	case "workspace.current":
		resp["result"] = map[string]any{"workspace_id": r.workspaces[0]["id"]}
	case "workspace.list":
		resp["result"] = map[string]any{"workspaces": cloneSliceOfMaps(r.workspaces)}
	case "surface.list":
		resp["result"] = map[string]any{"surfaces": []map[string]any{{
			"id":      "44444444-4444-4444-8444-444444444444",
			"ref":     "surface:1",
			"focused": true,
			"pane_id": "33333333-3333-4333-8333-333333333333",
			"title":   "shell",
		}}}
	case "surface.current":
		resp["result"] = map[string]any{
			"workspace_id": r.workspaces[0]["id"],
			"pane_id":      "33333333-3333-4333-8333-333333333333",
			"pane_ref":     "pane:1",
			"surface_id":   "44444444-4444-4444-8444-444444444444",
			"surface_ref":  "surface:1",
		}
	case "surface.read_text":
		text := r.readText
		if text == "" {
			text = "\x1b[31mRED\x1b[0m\nplain\n"
		}
		resp["result"] = map[string]any{"text": text}
	case "surface.send_text":
		resp["result"] = map[string]any{"ok": true}
	case "pane.list":
		pane := map[string]any{
			"id":      "33333333-3333-4333-8333-333333333333",
			"ref":     "pane:1",
			"index":   1,
			"focused": true,
			"columns": 80,
			"rows":    24,
		}
		result := map[string]any{"panes": []map[string]any{pane}}
		if r.includePaneMetrics {
			pane["cell_width_px"] = 8
			pane["cell_height_px"] = 16
			if r.includePointMetrics {
				pane["cell_width_points"] = 4
				pane["cell_height_points"] = 8
			}
			pane["pixel_frame"] = map[string]any{"x": 0, "y": 0, "width": 332, "height": 222}
			if r.includeContainerFrame {
				result["container_frame"] = map[string]any{"width": 640, "height": 384}
			}
		}
		resp["result"] = result
	case "pane.surfaces":
		resp["result"] = map[string]any{"surfaces": []map[string]any{{
			"id":       "44444444-4444-4444-8444-444444444444",
			"ref":      "surface:1",
			"selected": true,
		}}}
	case "pane.resize":
		resp["result"] = map[string]any{"ok": true}
	default:
		resp["ok"] = false
		resp["error"] = map[string]any{"code": "unsupported", "message": method}
	}
	r.mu.Unlock()

	payload, _ := json.Marshal(resp)
	_, _ = conn.Write(append(payload, '\n'))
}

func (r *tmuxCorpusRPCRecorder) methods() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	methods := make([]string, len(r.requests))
	for i, req := range r.requests {
		methods[i] = req.Method
	}
	return methods
}

func (r *tmuxCorpusRPCRecorder) requestsFor(method string) []tmuxCorpusRPCRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []tmuxCorpusRPCRequest
	for _, req := range r.requests {
		if req.Method == method {
			out = append(out, tmuxCorpusRPCRequest{
				Method: req.Method,
				Params: cloneMap(req.Params),
			})
		}
	}
	return out
}

func (r *tmuxCorpusRPCRecorder) setReadText(text string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.readText = text
}

func cloneMap(input map[string]any) map[string]any {
	out := make(map[string]any, len(input))
	for k, v := range input {
		out[k] = v
	}
	return out
}

func cloneSliceOfMaps(input []map[string]any) []map[string]any {
	out := make([]map[string]any, 0, len(input))
	for _, item := range input {
		out = append(out, cloneMap(item))
	}
	return out
}

func TestTmuxCorpusNewSessionAndNewWindowCommandsDispatchShellText(t *testing.T) {
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", t.TempDir())
	defer os.Setenv("HOME", origHome)

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "new-session", []string{"-d", "-s", "build", "-c", "/tmp", "echo one"}); err != nil {
		t.Fatalf("new-session: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "new-window", []string{"-d", "-n", "test", "echo two"}); err != nil {
		t.Fatalf("new-window: %v", err)
	}

	methods := recorder.methods()
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
	if !reflect.DeepEqual(methods, wantOrder) {
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

	createRequests := recorder.requestsFor("workspace.create")
	if len(createRequests) != 2 {
		t.Fatalf("workspace.create requests = %d, want 2", len(createRequests))
	}
	for _, req := range createRequests {
		if got := req.Params["focus"]; got != false {
			t.Fatalf("tmux detached/no-client creation should use focus=false, got %v in %+v", got, req.Params)
		}
	}
}

func TestTmuxCorpusHasSessionReturnSemantics(t *testing.T) {
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

func TestTmuxCorpusSendKeysAndTTYKeyTokens(t *testing.T) {
	tests := []struct {
		name    string
		tokens  []string
		literal bool
		want    string
	}{
		{name: "tmux input keys enter", tokens: []string{"printf", "ok", "Enter"}, want: "printf ok\r"},
		{name: "tmux input keys controls", tokens: []string{"C-c", "C-d", "C-z", "C-l"}, want: "\x03\x04\x1a\x0c"},
		{name: "tmux tty keys navigation bytes", tokens: []string{"Escape", "Tab", "BSpace"}, want: "\x1b\t\x7f"},
		{name: "literal mode", tokens: []string{"Enter", "C-c", "plain"}, literal: true, want: "Enter C-c plain"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tmuxSendKeysText(tt.tokens, tt.literal)
			if got != tt.want {
				t.Fatalf("tmuxSendKeysText(%v, literal=%v) = %q, want %q", tt.tokens, tt.literal, got, tt.want)
			}
		})
	}
}

func TestTmuxCorpusFormatStringsSupportedSubset(t *testing.T) {
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

func TestTmuxCorpusCapturePanePreservesTruecolorEscapeBytesInBuffers(t *testing.T) {
	origHome := os.Getenv("HOME")
	home := t.TempDir()
	os.Setenv("HOME", home)
	defer os.Setenv("HOME", origHome)

	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	printed := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "capture-pane", []string{"-p"}); err != nil {
			t.Fatalf("capture-pane -p: %v", err)
		}
	})
	if printed != "\x1b[31mRED\x1b[0m\nplain\n" {
		t.Fatalf("capture-pane -p output = %q", printed)
	}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "capture-pane", nil); err != nil {
			t.Fatalf("capture-pane buffer: %v", err)
		}
		if err := dispatchTmuxCommand(nil, "show-buffer", nil); err != nil {
			t.Fatalf("show-buffer: %v", err)
		}
	})
	if output != "\x1b[31mRED\x1b[0m\nplain\n" {
		t.Fatalf("captured buffer = %q", output)
	}
}

func TestTmuxCorpusCapturePanePreservesTerminalByteFixtures(t *testing.T) {
	origHome := os.Getenv("HOME")
	home := t.TempDir()
	os.Setenv("HOME", home)
	defer os.Setenv("HOME", origHome)

	tests := []struct {
		name string
		text string
	}{
		{
			name: "capture-pane-sgr0",
			text: "\x1b[38;2;255;0;0mred\x1b[0mplain\n",
		},
		{
			name: "capture-pane-hyperlink",
			text: "\x1b]8;;https://example.test\x1b\\linked\x1b]8;;\x1b\\\n",
		},
		{
			name: "osc-11colours-truecolor",
			text: "\x1b]11;rgb:12/34/56\x1b\\background\n\x1b]111\x1b\\reset\n",
		},
		{
			name: "utf8-combining-and-width-bytes",
			text: "e\u0301 cafe\u0301 \u26A1\uFE0F\n",
		},
		{
			name: "decrqm-sync-response-bytes",
			text: "\x1b[?2026;1$ysync-enabled\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			recorder := startTmuxCorpusRPCRecorder(t)
			recorder.setReadText(tt.text)
			rc := &rpcContext{socketPath: recorder.socketPath}

			printed := captureStdout(t, func() {
				if err := dispatchTmuxCommand(rc, "capture-pane", []string{"-p"}); err != nil {
					t.Fatalf("capture-pane -p: %v", err)
				}
			})
			if printed != tt.text {
				t.Fatalf("capture-pane -p output = %q, want %q", printed, tt.text)
			}

			buffered := captureStdout(t, func() {
				if err := dispatchTmuxCommand(rc, "capture-pane", nil); err != nil {
					t.Fatalf("capture-pane buffer: %v", err)
				}
				if err := dispatchTmuxCommand(nil, "show-buffer", nil); err != nil {
					t.Fatalf("show-buffer: %v", err)
				}
			})
			if buffered != tt.text {
				t.Fatalf("show-buffer output = %q, want %q", buffered, tt.text)
			}
		})
	}
}

func TestTmuxCorpusResizePaneDispatchesAbsoluteAndDirectionalResize(t *testing.T) {
	recorder := startTmuxCorpusRPCRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "100"}); err != nil {
		t.Fatalf("resize-pane absolute width: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "50%"}); err != nil {
		t.Fatalf("resize-pane percentage width: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-y", "20"}); err != nil {
		t.Fatalf("resize-pane compatibility height no-op: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-L", "7"}); err != nil {
		t.Fatalf("resize-pane directional: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-R"}); err != nil {
		t.Fatalf("resize-pane default directional: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-L7"}); err != nil {
		t.Fatalf("resize-pane attached directional: %v", err)
	}

	resizeRequests := recorder.requestsFor("pane.resize")
	if len(resizeRequests) != 5 {
		t.Fatalf("pane.resize requests = %d, want 5", len(resizeRequests))
	}
	if got := resizeRequests[0].Params["absolute_axis"]; got != "horizontal" {
		t.Fatalf("absolute resize axis = %v, want horizontal", got)
	}
	if got := asInt(t, resizeRequests[0].Params["target_pixels"], "absolute resize pixels"); got != 412 {
		t.Fatalf("absolute resize pixels = %v, want 412", got)
	}
	if got := asInt(t, resizeRequests[0].Params["target_cells"], "absolute resize cells"); got != 100 {
		t.Fatalf("absolute resize cells = %v, want 100", got)
	}
	if got := resizeRequests[0].Params["tmux_compat"]; got != true {
		t.Fatalf("absolute resize tmux_compat = %v, want true", got)
	}
	if got := resizeRequests[1].Params["absolute_axis"]; got != "horizontal" {
		t.Fatalf("percentage resize axis = %v, want horizontal", got)
	}
	if got := asInt(t, resizeRequests[1].Params["target_percentage"], "percentage resize target"); got != 50 {
		t.Fatalf("percentage resize target = %v, want 50", got)
	}
	if got := asInt(t, resizeRequests[1].Params["target_pixels"], "percentage resize pixels"); got != 320 {
		t.Fatalf("percentage resize pixels = %v, want 320", got)
	}
	if _, ok := resizeRequests[1].Params["target_cells"]; ok {
		t.Fatalf("percentage resize unexpectedly sent target_cells")
	}
	if got := resizeRequests[2].Params["direction"]; got != "left" {
		t.Fatalf("directional resize direction = %v, want left", got)
	}
	if got := asInt(t, resizeRequests[2].Params["amount"], "directional resize amount"); got != 28 {
		t.Fatalf("directional resize amount = %v, want 28", got)
	}
	if got := asInt(t, resizeRequests[2].Params["amount_cells"], "directional resize cells"); got != 7 {
		t.Fatalf("directional resize cells = %v, want 7", got)
	}
	if got := resizeRequests[2].Params["tmux_compat"]; got != true {
		t.Fatalf("directional resize tmux_compat = %v, want true", got)
	}
	if got := resizeRequests[3].Params["direction"]; got != "right" {
		t.Fatalf("default directional resize direction = %v, want right", got)
	}
	if got := asInt(t, resizeRequests[3].Params["amount_cells"], "default directional resize cells"); got != 1 {
		t.Fatalf("default directional resize cells = %v, want 1", got)
	}
	if got := asInt(t, resizeRequests[3].Params["amount"], "default directional resize amount"); got != 4 {
		t.Fatalf("default directional resize amount = %v, want 4", got)
	}
	if got := resizeRequests[4].Params["direction"]; got != "left" {
		t.Fatalf("attached directional resize direction = %v, want left", got)
	}
	if got := asInt(t, resizeRequests[4].Params["amount_cells"], "attached directional resize cells"); got != 7 {
		t.Fatalf("attached directional resize cells = %v, want 7", got)
	}
	if got := asInt(t, resizeRequests[4].Params["amount"], "attached directional resize amount"); got != 28 {
		t.Fatalf("attached directional resize amount = %v, want 28", got)
	}
}

func TestTmuxCorpusExactAbsoluteResizeDoesNotRequirePaneMetrics(t *testing.T) {
	recorder := startTmuxCorpusRPCRecorderWithPaneMetrics(t, false)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "3"}); err != nil {
		t.Fatalf("resize-pane cells without metrics: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "50%"}); err != nil {
		t.Fatalf("resize-pane percentage without metrics: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-L7"}); err != nil {
		t.Fatalf("resize-pane relative without metrics: %v", err)
	}

	requests := recorder.requestsFor("pane.resize")
	if len(requests) != 3 {
		t.Fatalf("pane.resize requests = %d, want 3", len(requests))
	}
	if got := asInt(t, requests[0].Params["target_cells"], "cell target"); got != 3 {
		t.Fatalf("target_cells = %v, want 3", got)
	}
	if _, ok := requests[0].Params["target_pixels"]; ok {
		t.Fatalf("cell resize unexpectedly sent target_pixels")
	}
	if got := asInt(t, requests[1].Params["target_percentage"], "percentage target"); got != 50 {
		t.Fatalf("target_percentage = %v, want 50", got)
	}
	if _, ok := requests[1].Params["target_pixels"]; ok {
		t.Fatalf("percentage resize unexpectedly sent target_pixels")
	}
	if got := asInt(t, requests[2].Params["amount_cells"], "relative cells"); got != 7 {
		t.Fatalf("amount_cells = %v, want 7", got)
	}
	if _, ok := requests[2].Params["amount"]; ok {
		t.Fatalf("relative resize unexpectedly sent amount")
	}
}

func TestTmuxCorpusPixelMetricsDoNotBecomePointFallbacks(t *testing.T) {
	recorder := startTmuxCorpusRPCRecorderWithMetricAvailability(t, true, false, true)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "3"}); err != nil {
		t.Fatalf("resize-pane cells with pixel-only metrics: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "50%"}); err != nil {
		t.Fatalf("resize-pane percentage with pixel-only metrics: %v", err)
	}
	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-L7"}); err != nil {
		t.Fatalf("resize-pane relative with pixel-only metrics: %v", err)
	}

	requests := recorder.requestsFor("pane.resize")
	if len(requests) != 3 {
		t.Fatalf("pane.resize requests = %d, want 3", len(requests))
	}
	if got := asInt(t, requests[0].Params["target_cells"], "cell target"); got != 3 {
		t.Fatalf("target_cells = %v, want 3", got)
	}
	if _, ok := requests[0].Params["target_pixels"]; ok {
		t.Fatalf("cell resize used pixel metrics as point fallback")
	}
	if got := asInt(t, requests[1].Params["target_percentage"], "percentage target"); got != 50 {
		t.Fatalf("target_percentage = %v, want 50", got)
	}
	if got := asInt(t, requests[1].Params["target_pixels"], "percentage points"); got != 320 {
		t.Fatalf("target_pixels = %v, want 320", got)
	}
	if got := asInt(t, requests[2].Params["amount_cells"], "relative cells"); got != 7 {
		t.Fatalf("amount_cells = %v, want 7", got)
	}
	if _, ok := requests[2].Params["amount"]; ok {
		t.Fatalf("relative resize used pixel metrics as point fallback")
	}
}

func TestTmuxCorpusPercentageWithoutContainerFrameOmitsPointFallback(t *testing.T) {
	recorder := startTmuxCorpusRPCRecorderWithMetricAvailability(t, true, true, false)
	rc := &rpcContext{socketPath: recorder.socketPath}

	if err := dispatchTmuxCommand(rc, "resize-pane", []string{"-t", "pane:1", "-x", "50%"}); err != nil {
		t.Fatalf("resize-pane percentage without container frame: %v", err)
	}

	requests := recorder.requestsFor("pane.resize")
	if len(requests) != 1 {
		t.Fatalf("pane.resize requests = %d, want 1", len(requests))
	}
	if got := asInt(t, requests[0].Params["target_percentage"], "percentage target"); got != 50 {
		t.Fatalf("target_percentage = %v, want 50", got)
	}
	if _, ok := requests[0].Params["target_pixels"]; ok {
		t.Fatalf("percentage resize without container frame sent target_pixels")
	}
}

func TestTmuxCorpusTmuxOnlyFeaturesFailExplicitlyOrNoOpDeliberately(t *testing.T) {
	unsupported := []string{
		"copy-mode",
		"if-shell",
		"run-shell",
		"choose-tree",
		"display-popup",
	}
	for _, command := range unsupported {
		t.Run(command, func(t *testing.T) {
			err := dispatchTmuxCommand(nil, command, nil)
			if err == nil {
				t.Fatalf("%s should not be silently treated as supported", command)
			}
			if !strings.Contains(err.Error(), "unsupported") {
				t.Fatalf("%s error = %q, want unsupported", command, err.Error())
			}
		})
	}

	deliberateNoOps := []string{"source-file", "set-option", "set-window-option", "refresh-client"}
	for _, command := range deliberateNoOps {
		t.Run(command, func(t *testing.T) {
			if err := dispatchTmuxCommand(nil, command, []string{"ignored"}); err != nil {
				t.Fatalf("%s should remain a deliberate compatibility no-op: %v", command, err)
			}
		})
	}
}
