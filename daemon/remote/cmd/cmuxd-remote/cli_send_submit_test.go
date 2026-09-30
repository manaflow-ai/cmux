package main

import (
	"encoding/json"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type sendSubmitMock struct {
	mu       sync.Mutex
	requests []map[string]any
	state    []map[string]any
	screen   []string
	keys     []string
	listener net.Listener
}

func startSendSubmitMock(t *testing.T, state []map[string]any, screen []string) (*sendSubmitMock, string) {
	t.Helper()
	m := &sendSubmitMock{state: state, screen: screen}
	socket := makeShortUnixSocketPath(t)
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	m.listener = ln
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go m.handle(conn)
		}
	}()
	return m, socket
}

func (m *sendSubmitMock) handle(conn net.Conn) {
	defer conn.Close()
	var req map[string]any
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		return
	}
	m.mu.Lock()
	m.requests = append(m.requests, req)
	method, _ := req["method"].(string)
	var result any = map[string]any{}
	switch method {
	case "surface.input_state":
		if len(m.state) > 0 {
			result = m.state[0]
			m.state = m.state[1:]
		}
	case "surface.read_text":
		if len(m.screen) > 0 {
			result = map[string]any{"text": m.screen[0]}
			m.screen = m.screen[1:]
		}
	case "surface.send_key":
		if p, ok := req["params"].(map[string]any); ok {
			if key, ok := p["key"].(string); ok {
				m.keys = append(m.keys, key)
			}
		}
	}
	m.mu.Unlock()
	resp := map[string]any{"id": req["id"], "ok": true, "result": result}
	payload, _ := json.Marshal(resp)
	_, _ = conn.Write(append(payload, '\n'))
}

func (m *sendSubmitMock) methods() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	methods := make([]string, 0, len(m.requests))
	for _, req := range m.requests {
		methods = append(methods, req["method"].(string))
	}
	return methods
}

func (m *sendSubmitMock) request(method string) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, req := range m.requests {
		if req["method"] == method {
			return req
		}
	}
	return nil
}

func TestSendSubmitUsesSeparatePasteAndSubmitKey(t *testing.T) {
	longText := strings.Repeat("long message ", 1024)
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, nil)
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", longText}); code != 0 {
			t.Fatalf("send --submit: exit %d", code)
		}
	})
	if output != "submitted\n" {
		t.Fatalf("output = %q, want submitted", output)
	}
	methods := mock.methods()
	if len(methods) < 5 || methods[0] != "surface.input_state" || methods[1] != "surface.read_text" || methods[2] != "terminal.paste" || methods[3] != "surface.input_state" || methods[4] != "surface.send_key" {
		t.Fatalf("method sequence = %v", methods)
	}
	paste := mock.request("terminal.paste")
	if params(paste)["text"] != longText || params(paste)["submit_key"] != "none" {
		t.Fatalf("paste params = %v", params(paste))
	}
	if params(mock.request("surface.send_key"))["key"] != "return" {
		t.Fatalf("submit key params = %v", params(mock.request("surface.send_key")))
	}
}

func TestSendSubmitBusyCodexQueuesWithTab(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "lifecycle": "running", "agent_kind": "codex"},
		{"agent": true, "state": "empty", "lifecycle": "running", "agent_kind": "codex"},
		{"agent": true, "state": "queued", "queued": true, "lifecycle": "running", "agent_kind": "codex"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
		t.Fatalf("send --submit: exit %d", code)
	}
	if params(mock.request("surface.send_key"))["key"] != "tab" {
		t.Fatalf("submit key params = %v, want tab", params(mock.request("surface.send_key")))
	}
}

func TestSendSubmitRefusesDraftAndDialog(t *testing.T) {
	for _, tc := range []struct {
		name  string
		state map[string]any
	}{
		{"draft", map[string]any{"agent": true, "state": "draft", "blocks_typing": true}},
		{"dialog", map[string]any{"agent": true, "state": "dialog", "blocks_typing": true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mock, socket := startSendSubmitMock(t, []map[string]any{tc.state}, nil)
			if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
				t.Fatal("expected refusal")
			}
			if mock.request("terminal.paste") != nil {
				t.Fatal("paste was sent despite guard")
			}
		})
	}
}

func TestSendSubmitRetriesAndFailsWhenComposerNeverSubmits(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "blocks_typing": true, "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("expected bounded retry failure")
	}
	if len(mock.methods()) != 10 { // preflight + paste + refresh + 3*(key,state)
		t.Fatalf("method sequence = %v", mock.methods())
	}
}

func TestSendSubmitShellUsesReturnWithoutComposerCheck(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "unknown"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "echo hi"}); code != 0 {
		t.Fatalf("shell send --submit: exit %d", code)
	}
	if params(mock.request("surface.send_key"))["key"] != "return" {
		t.Fatalf("submit key params = %v", params(mock.request("surface.send_key")))
	}
	for _, method := range mock.methods() {
		if method == "surface.read_text" {
			t.Fatal("shell submit unexpectedly probed composer screen")
		}
	}
}

func TestSendSubmitSlashPopupSendsExtraSubmit(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, []string{"❯ /goal\n/goal resume\n"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
		t.Fatalf("send --submit: exit %d", code)
	}
	deadline := time.Now().Add(time.Second)
	for {
		mock.mu.Lock()
		keys := len(mock.keys)
		mock.mu.Unlock()
		if keys == 2 || time.Now().After(deadline) {
			if keys != 2 {
				t.Fatalf("sent %d submit keys, want 2", keys)
			}
			break
		}
		time.Sleep(time.Millisecond)
	}
}

func TestSendSubmitForceBypassesDraftGuard(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "draft", "blocks_typing": true},
		{"agent": true, "state": "empty"},
		{"agent": true, "state": "empty"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "--force", "hello"}); code != 0 {
		t.Fatalf("forced send --submit: exit %d", code)
	}
	if mock.request("terminal.paste") == nil {
		t.Fatal("forced send did not paste")
	}
}

func TestSendSubmitFlagsMayFollowTargetOptions(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "unknown"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--surface", "surface-7", "--submit", "--force", "hello"}); code != 0 {
		t.Fatalf("send --submit after target: exit %d", code)
	}
	if params(mock.request("terminal.paste"))["surface_id"] != "surface-7" {
		t.Fatalf("target params = %v", params(mock.request("terminal.paste")))
	}
}

func TestSendSubmitMultilineClaudeUsesCtrlEnter(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "line one\nline two"}); code != 0 {
		t.Fatalf("multiline send --submit: exit %d", code)
	}
	if params(mock.request("surface.send_key"))["key"] != "ctrl+enter" {
		t.Fatalf("submit key params = %v, want ctrl+enter", params(mock.request("surface.send_key")))
	}
}

func TestSendSubmitStopsOnNewDialog(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "dialog", "blocks_typing": true, "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("expected dialog failure")
	}
	mock.mu.Lock()
	keys := len(mock.keys)
	mock.mu.Unlock()
	if keys != 1 {
		t.Fatalf("sent %d submit keys after dialog, want 1", keys)
	}
}

func TestSendSubmitRejectsOversizedText(t *testing.T) {
	mock, socket := startSendSubmitMock(t, nil, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", strings.Repeat("x", sendMaximumEncodedTextBytes)}); code == 0 {
		t.Fatal("expected oversized text failure")
	}
	mock.mu.Lock()
	defer mock.mu.Unlock()
	if len(mock.requests) != 0 {
		t.Fatalf("oversized text sent requests: %v", mock.requests)
	}
}

func TestSendSubmitRejectsStaleEmptyAfterPaste(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("stale empty composer was reported submitted")
	}
	if mock.request("surface.send_key") != nil {
		t.Fatal("submit key was sent before paste became visible")
	}
}

func TestSendSubmitHooklessDraftRefusal(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{{"agent": false, "state": "unknown"}}, []string{"Claude Code\n❯ human draft\n"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("hookless draft was not refused")
	}
	if mock.request("terminal.paste") != nil {
		t.Fatal("pasted over hookless human draft")
	}
}

func TestSendSubmitScreenClassifier(t *testing.T) {
	for _, tc := range []struct {
		name, screen, kind, state string
		busy                      bool
	}{
		{"claude boxed placeholder", "Claude Code\n│\x1b[2m❯ Try asking for a change\x1b[0m│\n", "claude", "empty", false},
		{"claude multiline draft", "Claude Code\n│❯ │\n│ human draft │\n╰────╯\n", "claude", "draft", false},
		{"codex busy", "OpenAI Codex\nWorking (esc to interrupt)\n› hello\n", "codex", "draft", true},
		{"codex queued", "OpenAI Codex\nQueued messages: 1\n›\n", "codex", "queued", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := sendStateFromScreen(tc.screen)
			if stateString(state, "agent_kind") != tc.kind || stateString(state, "state") != tc.state || boolValue(state, "busy") != tc.busy {
				t.Fatalf("screen state = %v", state)
			}
		})
	}
}

func TestSendSubmitBusyFlagChoosesTab(t *testing.T) {
	if !sendStateLooksLikeBusyCodex(map[string]any{"agent": true, "agent_kind": "codex", "busy": true}, "") {
		t.Fatal("busy:true Codex ignored")
	}
}
