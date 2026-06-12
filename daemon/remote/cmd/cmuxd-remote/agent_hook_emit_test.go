package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/agentconv"
)

// fakeHookSocket listens on a short-path unix socket and returns each
// received line. Unix socket paths are length-limited (~104 bytes on macOS),
// so the socket lives in a dedicated short MkdirTemp dir, not t.TempDir.
func fakeHookSocket(t *testing.T) (string, <-chan string) {
	t.Helper()
	dir, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "i.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	lines := make(chan string, 16)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				scanner := bufio.NewScanner(conn)
				for scanner.Scan() {
					lines <- scanner.Text()
				}
			}(conn)
		}
	}()
	return socketPath, lines
}

func awaitHookLine(t *testing.T, lines <-chan string) agentconv.HookFrame {
	t.Helper()
	select {
	case line := <-lines:
		var frame agentconv.HookFrame
		if err := json.Unmarshal([]byte(line), &frame); err != nil {
			t.Fatalf("received non-JSON hook line %q: %v", line, err)
		}
		return frame
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for hook frame")
		return agentconv.HookFrame{}
	}
}

func TestAgentHookEmitDeliversFrameFromArgv(t *testing.T) {
	socketPath, lines := fakeHookSocket(t)
	frameJSON := `{"provider":"claude","session_id":"sess-1","hook":"UserPromptSubmit","prompt":"hello"}`
	if code := runAgentHookEmit([]string{"--socket", socketPath, frameJSON}, strings.NewReader("")); code != 0 {
		t.Fatalf("exit code = %d", code)
	}
	frame := awaitHookLine(t, lines)
	if frame.Provider != "claude" || frame.SessionID != "sess-1" || frame.Hook != "UserPromptSubmit" || frame.Prompt != "hello" {
		t.Errorf("frame = %+v", frame)
	}
	if frame.TS == "" {
		t.Error("emit should stamp ts when missing")
	}
}

func TestAgentHookEmitTranslatesClaudeNativePayloadFromStdin(t *testing.T) {
	socketPath, lines := fakeHookSocket(t)
	native := `{"session_id":"sess-2","transcript_path":"/tmp/x.jsonl","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_9","tool_input":{"command":"bun test"}}`
	if code := runAgentHookEmit([]string{"--socket", socketPath}, strings.NewReader(native)); code != 0 {
		t.Fatalf("exit code = %d", code)
	}
	frame := awaitHookLine(t, lines)
	if frame.Provider != "claude" || frame.SessionID != "sess-2" {
		t.Errorf("identity = %+v", frame)
	}
	if frame.Hook != "PreToolUse" || frame.ToolName != "Bash" || frame.ToolUseID != "toolu_9" {
		t.Errorf("tool fields = %+v", frame)
	}
	if frame.Detail != "bun test" {
		t.Errorf("detail = %q, want tool title from tool_input", frame.Detail)
	}
}

func TestAgentHookEmitNeverFails(t *testing.T) {
	// Connect failure: no listener at the path.
	missing := filepath.Join(t.TempDir(), "missing.sock")
	if code := runAgentHookEmit(
		[]string{"--socket", missing, `{"provider":"claude","session_id":"s","hook":"Stop"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Errorf("connect failure exit code = %d, want 0", code)
	}
	// Garbage input.
	if code := runAgentHookEmit([]string{"--socket", missing}, strings.NewReader("not json")); code != 0 {
		t.Errorf("bad input exit code = %d, want 0", code)
	}
	// Empty input.
	if code := runAgentHookEmit([]string{"--socket", missing}, strings.NewReader("")); code != 0 {
		t.Errorf("empty input exit code = %d, want 0", code)
	}
}

func TestRunDispatchesAgentHookEmit(t *testing.T) {
	socketPath, lines := fakeHookSocket(t)
	code := run(
		[]string{"agent-hook-emit", "--socket", socketPath, `{"session_id":"sess-3","hook":"Stop"}`},
		strings.NewReader(""), os.Stdout, os.Stderr,
	)
	if code != 0 {
		t.Fatalf("exit code = %d", code)
	}
	frame := awaitHookLine(t, lines)
	if frame.SessionID != "sess-3" || frame.Hook != "Stop" || frame.Provider != "claude" {
		t.Errorf("frame = %+v", frame)
	}
}
