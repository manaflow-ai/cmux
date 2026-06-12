package main

import (
	"strings"
	"testing"
)

// The payload below is the exact wire shape from
// codex-rs/hooks/src/legacy_notify.rs (kebab-case, appended as the final argv
// argument to the configured notify program).
const codexNotifyFixture = `{
  "type": "agent-turn-complete",
  "thread-id": "b5f6c1c2-1111-2222-3333-444455556666",
  "turn-id": "12345",
  "cwd": "/Users/example/project",
  "client": "codex-tui",
  "input-messages": ["Rename ` + "`foo`" + ` to ` + "`bar`" + ` and update the callsites."],
  "last-assistant-message": "Rename complete and verified ` + "`cargo build`" + ` succeeds."
}`

func TestAgentHookEmitTranslatesCodexNotifyPayloadFromArgv(t *testing.T) {
	socketPath, lines := fakeHookSocket(t)
	if code := runAgentHookEmit([]string{"--socket", socketPath, codexNotifyFixture}, strings.NewReader("")); code != 0 {
		t.Fatalf("exit code = %d", code)
	}
	frame := awaitHookLine(t, lines)
	if frame.Provider != "codex" || frame.SessionID != "b5f6c1c2-1111-2222-3333-444455556666" {
		t.Errorf("identity = %+v", frame)
	}
	if frame.Hook != "Stop" || frame.TurnID != "12345" {
		t.Errorf("turn mapping = %+v", frame)
	}
	if frame.Detail != "Rename complete and verified `cargo build` succeeds." {
		t.Errorf("detail = %q, want last-assistant-message", frame.Detail)
	}
	if frame.TS == "" {
		t.Error("emit should stamp ts")
	}
}

func TestAgentHookEmitDropsUnroutableCodexNotify(t *testing.T) {
	socketPath, lines := fakeHookSocket(t)
	// Ancient Codex shape without thread-id: cannot be routed to a session.
	old := `{"type":"agent-turn-complete","turn-id":"1","input-messages":["x"],"last-assistant-message":"y"}`
	if code := runAgentHookEmit([]string{"--socket", socketPath, old}, strings.NewReader("")); code != 0 {
		t.Errorf("old payload exit code = %d, want 0", code)
	}
	// Unknown notification types are not guessed at.
	unknown := `{"type":"agent-turn-started","thread-id":"t1","turn-id":"2"}`
	if code := runAgentHookEmit([]string{"--socket", socketPath, unknown}, strings.NewReader("")); code != 0 {
		t.Errorf("unknown type exit code = %d, want 0", code)
	}
	// Neither dropped payload may reach the socket: the next valid frame must
	// be the first line received.
	if code := runAgentHookEmit([]string{"--socket", socketPath, codexNotifyFixture}, strings.NewReader("")); code != 0 {
		t.Fatalf("exit code = %d", code)
	}
	frame := awaitHookLine(t, lines)
	if frame.SessionID != "b5f6c1c2-1111-2222-3333-444455556666" || frame.TurnID != "12345" {
		t.Errorf("dropped payload leaked; first delivered frame = %+v", frame)
	}
}
