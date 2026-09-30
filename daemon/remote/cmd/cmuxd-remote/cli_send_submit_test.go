package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type sendSubmitMock struct {
	mu              sync.Mutex
	requests        []map[string]any
	state           []map[string]any
	screen          []string
	inputStateError bool
	keys            []string
	listener        net.Listener
}

func startSendSubmitInputStateErrorMock(t *testing.T) (*sendSubmitMock, string) {
	mock, socket := startSendSubmitMock(t, nil, nil)
	mock.inputStateError = true
	return mock, socket
}

func sendTestFingerprint(text string) string {
	digest := sha256.Sum256([]byte(strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n"))))
	return hex.EncodeToString(digest[:])
}

func TestSendSubmitSameLengthHumanEditPreventsRetry(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "draft_length": 5, "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "claude"},
		{"agent": true, "state": "draft", "draft_length": 5, "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "claude"},
		{"agent": true, "state": "draft", "draft_length": 5, "composer_fingerprint": sendTestFingerprint("human"), "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("human edit falsely confirmed")
	}
	if keys := mock.keysSnapshot(); len(keys) != 1 {
		t.Fatalf("keys = %v, want no retry over same-length human edit", keys)
	}
}

func TestSendSubmitPinsHostSurfaceForPasteAndKey(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "unknown", "surface_id": "resolved-surface"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "--workspace", "workspace-1", "hello"}); code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, method := range []string{"terminal.paste", "surface.send_key"} {
		if target := params(mock.request(method))["surface_id"]; target != "resolved-surface" {
			t.Fatalf("%s target = %v", method, target)
		}
	}
}

func TestSendSubmitNormalizesLoneCarriageReturn(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{{"agent": false, "state": "unknown"}}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "a\rb"}); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if text := params(mock.request("terminal.paste"))["text"]; text != "a\nb" {
		t.Fatalf("paste text = %q", text)
	}
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
		if m.inputStateError {
			m.mu.Unlock()
			resp := map[string]any{"id": req["id"], "ok": false, "error": map[string]any{"code": "method_not_found", "message": "Unknown method"}}
			payload, _ := json.Marshal(resp)
			_, _ = conn.Write(append(payload, '\n'))
			return
		}
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

func TestSendRelayPlainSendFallsBackWhenInputStateUnavailable(t *testing.T) {
	mock, socket := startSendSubmitInputStateErrorMock(t)
	if code := runCLI([]string{"--socket", socket, "send", "hello"}); code != 0 {
		t.Fatalf("send: exit %d", code)
	}
	if mock.request("surface.send_text") == nil {
		t.Fatal("plain send did not use its legacy fallback")
	}
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

func (m *sendSubmitMock) keysSnapshot() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]string(nil), m.keys...)
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
		{"agent": true, "state": "draft", "agent_kind": "claude"},
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
	pasteIndex, keyIndex := -1, -1
	for i, method := range methods {
		if method == "terminal.paste" {
			pasteIndex = i
		}
		if method == "surface.send_key" && keyIndex < 0 {
			keyIndex = i
		}
	}
	if pasteIndex < 0 || keyIndex <= pasteIndex {
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
		{"agent": true, "state": "draft", "lifecycle": "running", "agent_kind": "codex"},
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
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "blocks_typing": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "blocks_typing": true, "agent_kind": "claude"},
	}, []string{"Claude Code\n❯ ", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("expected bounded retry failure")
	}
	if len(mock.keysSnapshot()) != 3 {
		t.Fatalf("submit keys = %v", mock.keysSnapshot())
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
	reads := 0
	for _, method := range mock.methods() {
		if method == "surface.read_text" {
			reads++
		}
	}
	if reads != 0 {
		t.Fatalf("shell composer reads = %d, want no screen reads", reads)
	}
}

func TestSendSubmitSlashPopupSendsExtraSubmit(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("/goal resume"), "slash_command_popup": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("/goal resume"), "slash_command_popup": true, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("/goal resume"), "slash_command_popup": true, "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, []string{"❯\n", "❯ /goal\n/goal resume\n", "❯ /goal resume\n", "❯ /goal resume\n", "❯\n"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "/goal resume"}); code != 0 {
		t.Fatalf("send --submit: exit %d", code)
	}
	deadline := time.Now().Add(time.Second)
	for {
		keys := len(mock.keysSnapshot())
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
		{"agent": true, "state": "draft"},
		{"agent": true, "state": "empty"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "--force", "hello"}); code != 0 {
		t.Fatalf("forced send --submit: exit %d", code)
	}
	if mock.request("terminal.paste") == nil {
		t.Fatal("forced send did not paste")
	}
	methods := mock.methods()
	if len(methods) == 0 || methods[0] != "surface.input_state" {
		t.Fatalf("forced send methods = %v, want input_state first", methods)
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

func TestSendSubmitMultilineClaudeUsesEnter(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "line one\nline two"}); code != 0 {
		t.Fatalf("multiline send --submit: exit %d", code)
	}
	if params(mock.request("surface.send_key"))["key"] != "return" {
		t.Fatalf("submit key params = %v, want return", params(mock.request("surface.send_key")))
	}
}

func TestSendSubmitStopsOnNewDialog(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "agent_kind": "claude"},
		{"agent": true, "state": "dialog", "blocks_typing": true, "agent_kind": "claude"},
	}, nil)
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code == 0 {
		t.Fatal("expected dialog failure")
	}
	keys := len(mock.keysSnapshot())
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
	mock, socket := startSendSubmitMock(t, []map[string]any{{"agent": false, "state": "unknown"}}, []string{"✻ Welcome to Claude Code!\n❯\u00a0human draft\n"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
		t.Fatalf("host state unknown should still send: exit %d", code)
	}
	if mock.request("terminal.paste") == nil {
		t.Fatal("submit did not paste when host state was available but unknown")
	}
}

func TestSendSubmitOwnSlashPickerCountsAsSubmitted(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "slash_command_popup": true, "agent_kind": "claude"},
		{"agent": true, "state": "dialog", "slash_command_popup": true, "agent_kind": "claude"},
	}, []string{"❯\n", "❯ /model\nSelect a model\nEnter to select\n"})
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "/model"}); code != 0 {
			t.Fatalf("send --submit: exit %d", code)
		}
	})
	if output != "submitted\n" {
		t.Fatalf("output = %q, want submitted", output)
	}
	if len(mock.keysSnapshot()) != 1 {
		t.Fatalf("keys = %v, want one submit key", mock.keysSnapshot())
	}
}

func TestSendSubmitBusyFlagChoosesTab(t *testing.T) {
	if !sendStateLooksLikeBusyCodex(map[string]any{"agent": true, "agent_kind": "codex", "busy": true}) {
		t.Fatal("busy:true Codex ignored")
	}
}

func TestSendSubmitSlashClearDoesNotSendExtraKey(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, []string{"❯\n", "❯ /goal\n/goal resume\n", "❯\n"})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "/goal resume"}); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(mock.keysSnapshot()) != 1 {
		t.Fatalf("extra key after clear: %v", mock.keysSnapshot())
	}
}

func TestSendSubmitRetryRefreshesBusyCodex(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "codex"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "codex"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "codex", "busy": true},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "agent_kind": "codex", "busy": true},
		{"agent": true, "state": "queued", "agent_kind": "codex", "queued": true},
	}, []string{"OpenAI Codex\n› ", "OpenAI Codex\n› hello", "OpenAI Codex\n› hello", "OpenAI Codex\n› hello", "OpenAI Codex\nQueued messages: 1\n› "})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
		t.Fatalf("exit %d", code)
	}
	if len(mock.keysSnapshot()) != 2 || mock.keysSnapshot()[0] != "return" || mock.keysSnapshot()[1] != "tab" {
		t.Fatalf("keys = %v", mock.keysSnapshot())
	}
}

func TestSendSubmitHooklessBusyCodexQueues(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "unknown"},
		{"agent": false, "state": "unknown"},
		{"agent": false, "state": "unknown"},
	}, []string{"│ >_ OpenAI Codex (v0.154.0) │\n• Working (3s • esc to interrupt)\n› \n", "│ >_ OpenAI Codex (v0.154.0) │\n• Working (3s • esc to interrupt)\n› hello\n", "│ >_ OpenAI Codex (v0.154.0) │\nQueued messages: 1\n› \n"})
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("exit %d", code)
		}
	})
	if output != "submitted\n" || len(mock.keysSnapshot()) != 1 || mock.keysSnapshot()[0] != "return" {
		t.Fatalf("output=%q keys=%v", output, mock.keysSnapshot())
	}
}

func TestSendSubmitShellGlyphPromptDoesNotProbe(t *testing.T) {
	mock, socket := startSendSubmitMock(t, nil, []string{"❯ "})
	if code := runCLI([]string{"--socket", socket, "send", "--submit", "echo hi"}); code != 0 {
		t.Fatalf("bare shell prompt: exit %d", code)
	}
	if len(mock.keysSnapshot()) != 1 || mock.keysSnapshot()[0] != "return" {
		t.Fatalf("keys = %v, want one return", mock.keysSnapshot())
	}
}

func TestSendSubmitReviewKeys(t *testing.T) {
	claude := map[string]any{"agent": true, "agent_kind": "claude", "busy": true, "lifecycle": "running"}
	if key := sendSubmitKey(claude); key != "return" {
		t.Fatalf("Claude key = %q", key)
	}
}

func TestSendSubmitUnknownAgentReturnsSent(t *testing.T) {
	_, socket := startSendSubmitMock(t, []map[string]any{{"agent": true, "state": "unknown"}}, nil)
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "--json", "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("exit %d", code)
		}
	})
	if !strings.Contains(output, `"status":"sent"`) || !strings.Contains(output, `"submitted":false`) {
		t.Fatalf("output = %q", output)
	}
}

func TestSendSubmitHumanEditPreventsRetry(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "draft_length": 5, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "draft_length": 11, "agent_kind": "claude"},
	}, []string{"Claude Code\n❯ ", "Claude Code\n❯ hello", "Claude Code\n❯ hello", "Claude Code\n❯ hello human edit"})
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "--json", "send", "--submit", "hello"}); code == 0 {
			t.Fatal("human edit submitted")
		}
	})
	if len(mock.keysSnapshot()) != 1 {
		t.Fatalf("keys=%v", mock.keysSnapshot())
	}
	if !strings.Contains(output, `"status":"unconfirmed"`) {
		t.Fatalf("output=%q", output)
	}
}

func TestSendSubmitFinalReadConfirmsSlowRenderer(t *testing.T) {
	states := []map[string]any{{"agent": true, "agent_kind": "claude", "state": "empty"}}
	for i := 0; i < 6; i++ {
		states = append(states, map[string]any{"agent": true, "agent_kind": "claude", "state": "draft", "composer_fingerprint": sendTestFingerprint("hello")})
	}
	states = append(states, map[string]any{"agent": true, "agent_kind": "claude", "state": "empty"})
	screens := []string{"Claude Code\n❯ "}
	for i := 0; i < 6; i++ {
		screens = append(screens, "Claude Code\n❯ hello")
	}
	screens = append(screens, "Claude Code\n❯ ")
	mock, socket := startSendSubmitMock(t, states, screens)
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("exit %d", code)
		}
	})
	if output != "submitted\n" || len(mock.keysSnapshot()) != 3 {
		t.Fatalf("output=%q keys=%v", output, mock.keysSnapshot())
	}
}

func TestSendSubmitPopupNotConfirmedUntilClosed(t *testing.T) {
	if sendStateConfirmed(map[string]any{"agent": true, "state": "empty", "slash_popup": true}, false) {
		t.Fatal("popup falsely confirmed")
	}
}

func TestSendSubmitRequiresHostAgentFlagForCodexQueue(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "unknown", "agent_kind": "codex", "busy": true},
	}, nil)
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("exit %d", code)
		}
	})
	if output != "submitted\n" || len(mock.keysSnapshot()) != 1 || mock.keysSnapshot()[0] != "return" {
		t.Fatalf("output=%q keys=%v", output, mock.keysSnapshot())
	}
}

func TestSendSubmitUsesHostInputStateWithoutScreenHeuristics(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": true, "state": "empty", "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "draft_length": 5, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "draft_length": 5, "agent_kind": "claude"},
		{"agent": true, "state": "draft", "composer_fingerprint": sendTestFingerprint("hello"), "draft_length": 5, "agent_kind": "claude"},
		{"agent": true, "state": "empty", "agent_kind": "claude"},
	}, nil)
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("send --submit: exit %d", code)
		}
	})
	if output != "submitted\n" {
		t.Fatalf("output = %q, want submitted", output)
	}
	if keys := mock.keysSnapshot(); len(keys) != 2 {
		t.Fatalf("keys = %v, want one retry from host state", keys)
	}
	for _, method := range mock.methods() {
		if method == "surface.read_text" {
			t.Fatal("relay used screen text despite complete host input_state")
		}
	}
}

func TestSendSubmitUsesAgentKindOnlyWithHostAgentFlag(t *testing.T) {
	for _, kind := range []string{"claude", "codex"} {
		t.Run(kind, func(t *testing.T) {
			mock, socket := startSendSubmitMock(t, []map[string]any{
				{"agent": false, "state": "empty", "agent_kind": kind, "busy": true},
				{"agent": false, "state": "draft", "agent_kind": kind, "busy": true},
				{"agent": false, "state": "empty", "agent_kind": kind},
			}, nil)
			output := captureStdout(t, func() {
				if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
					t.Fatalf("exit %d", code)
				}
			})
			keys := mock.keysSnapshot()
			wantKey := "return"
			if kind == "codex" {
				wantKey = "return"
			}
			if len(keys) != 1 || keys[0] != wantKey {
				t.Fatalf("keys = %v, want [%s]", keys, wantKey)
			}
			if output != "submitted\n" {
				t.Fatalf("output = %q, want submitted", output)
			}
			if len(mock.methods()) != 3 {
				t.Fatalf("unexpected screen probes: %v", mock.methods())
			}
		})
	}
}

func TestSendSubmitHonorsHostShellClassification(t *testing.T) {
	mock, socket := startSendSubmitMock(t, []map[string]any{
		{"agent": false, "state": "empty"},
	}, []string{"│ >_ OpenAI Codex (v0.154.0) │\n• Working (3s • esc to interrupt)\n› hello"})
	output := captureStdout(t, func() {
		if code := runCLI([]string{"--socket", socket, "send", "--submit", "hello"}); code != 0 {
			t.Fatalf("exit %d", code)
		}
	})
	if output != "submitted\n" {
		t.Fatalf("output = %q", output)
	}
	keys := mock.keysSnapshot()
	if len(keys) != 1 || keys[0] != "return" {
		t.Fatalf("shell keys = %v", keys)
	}
}
