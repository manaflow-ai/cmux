package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// End to end over the real stdio server: open a subscription, emit a hook
// frame through the real ingest socket via the emit verb, and observe the
// canonical turn/request events on the same agent.session.event stream the
// transcript feeds. Frames for unknown sessions are dropped.
func TestHookIngestRoutesFramesToSubscription(t *testing.T) {
	// Unix socket paths are length-limited; keep it short.
	socketDir, err := os.MkdirTemp("", "hki")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketDir)
	socketPath := filepath.Join(socketDir, "i.sock")
	t.Setenv(agentHookSocketEnv, socketPath)

	transcript := filepath.Join(t.TempDir(), "session.jsonl")
	line1 := `{"type":"user","uuid":"u1","timestamp":"2026-06-10T10:00:00.000Z","sessionId":"sess-ingest","cwd":"/tmp/project","message":{"role":"user","content":"hello"}}` + "\n"
	if err := os.WriteFile(transcript, []byte(line1), 0o644); err != nil {
		t.Fatal(err)
	}

	stdinReader, stdinWriter := io.Pipe()
	stdoutReader, stdoutWriter := io.Pipe()
	serverDone := make(chan int, 1)
	go func() {
		serverDone <- run([]string{"serve", "--stdio"}, stdinReader, stdoutWriter, io.Discard)
		stdoutWriter.Close()
	}()

	frames := make(chan map[string]any, 64)
	go func() {
		scanner := bufio.NewScanner(stdoutReader)
		scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
		for scanner.Scan() {
			var frame map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &frame); err == nil {
				frames <- frame
			}
		}
		close(frames)
	}()
	awaitFrame := func(match func(map[string]any) bool, what string) map[string]any {
		t.Helper()
		deadline := time.After(10 * time.Second)
		for {
			select {
			case frame, ok := <-frames:
				if !ok {
					t.Fatalf("stream closed while waiting for %s", what)
				}
				if match(frame) {
					return frame
				}
			case <-deadline:
				t.Fatalf("timed out waiting for %s", what)
			}
		}
	}
	send := func(payload string) {
		t.Helper()
		if _, err := io.WriteString(stdinWriter, payload+"\n"); err != nil {
			t.Fatalf("write request: %v", err)
		}
	}

	openRequest, _ := json.Marshal(map[string]any{
		"id":     1,
		"method": "agent.session.open",
		"params": map[string]any{"provider": "claude", "transcript_path": transcript},
	})
	send(string(openRequest))
	opened := awaitFrame(func(frame map[string]any) bool { return frame["id"] == float64(1) }, "open response")
	result, _ := opened["result"].(map[string]any)
	subscriptionID, _ := result["subscription_id"].(string)
	if subscriptionID == "" {
		t.Fatalf("open failed: %v", opened)
	}

	payloadOfType := func(frame map[string]any, eventType string) map[string]any {
		if frame["event"] != "agent.session.event" || frame["subscription_id"] != subscriptionID {
			return nil
		}
		payload, _ := frame["payload"].(map[string]any)
		if payload == nil || payload["type"] != eventType {
			return nil
		}
		return payload
	}
	awaitFrame(func(frame map[string]any) bool { return payloadOfType(frame, "snapshot") != nil }, "snapshot")

	// The listener is up only while the subscription is open. Emit through
	// the real verb; a frame for an unknown session must not produce events.
	awaitSocket(t, socketPath)
	if code := runAgentHookEmit(
		[]string{"--socket", socketPath, `{"provider":"claude","session_id":"no-such-session","hook":"UserPromptSubmit","prompt":"ignored"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Fatalf("emit exit = %d", code)
	}
	if code := runAgentHookEmit(
		[]string{"--socket", socketPath, `{"provider":"claude","session_id":"sess-ingest","hook":"UserPromptSubmit","prompt":"run the tests"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Fatalf("emit exit = %d", code)
	}
	turnStarted := awaitFrame(func(frame map[string]any) bool {
		return payloadOfType(frame, "turn.started") != nil
	}, "turn.started event")
	payload := payloadOfType(turnStarted, "turn.started")
	if payload["prompt"] != "run the tests" || payload["turn_id"] == "" {
		t.Errorf("turn.started payload = %v", payload)
	}

	if code := runAgentHookEmit(
		[]string{"--socket", socketPath, `{"provider":"claude","session_id":"sess-ingest","hook":"Notification","tool_use_id":"toolu_req","detail":"Claude needs your permission to use Bash"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Fatalf("emit exit = %d", code)
	}
	openedRequest := awaitFrame(func(frame map[string]any) bool {
		return payloadOfType(frame, "request.opened") != nil
	}, "request.opened event")
	requestPayload := payloadOfType(openedRequest, "request.opened")
	if requestPayload["request_id"] != "toolu_req" || requestPayload["request_type"] != "tool_approval" {
		t.Errorf("request.opened payload = %v", requestPayload)
	}

	// Closing the last subscription tears the ingest socket down.
	closeRequest, _ := json.Marshal(map[string]any{
		"id":     2,
		"method": "agent.session.close",
		"params": map[string]any{"subscription_id": subscriptionID},
	})
	send(string(closeRequest))
	awaitFrame(func(frame map[string]any) bool { return frame["id"] == float64(2) }, "close response")
	awaitSocketGone(t, socketPath)

	stdinWriter.Close()
	select {
	case code := <-serverDone:
		if code != 0 {
			t.Errorf("server exit code = %d", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("server did not exit after stdin close")
	}
}

func awaitSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if conn, err := net.Dial("unix", path); err == nil {
			conn.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("ingest socket %s never came up", path)
}

func awaitSocketGone(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err != nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("ingest socket %s was not removed after last close", path)
}

// The ingest socket's parent lives at a well-known /tmp name: a pre-created
// symlink there must disable the listener instead of redirecting the socket.
func TestHookIngestRefusesSymlinkedSocketDir(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "elsewhere")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "linked")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(link, "ingest.sock")
	t.Setenv(agentHookSocketEnv, socketPath)

	registry := &hookIngestRegistry{logf: func(string, ...any) {}}
	registry.mu.Lock()
	registry.startListenerLocked()
	listening := registry.listener != nil
	registry.mu.Unlock()
	if listening {
		registry.mu.Lock()
		registry.stopListenerLocked()
		registry.mu.Unlock()
		t.Fatal("listener started behind a symlinked socket directory")
	}
	if _, err := os.Lstat(filepath.Join(target, "ingest.sock")); err == nil {
		t.Fatal("socket was created through the symlink")
	}
}
