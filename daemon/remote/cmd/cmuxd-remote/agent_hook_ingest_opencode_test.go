package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Frames are routed by their own (provider, session_id): the emit verb passes
// ready-made frames through untouched, and nothing in the ingest path is
// limited to claude|codex. An opencode plugin can therefore push frames for a
// subscription opened with provider "opencode" — there is no opencode
// transcript parser, so the open names the session id explicitly and the
// stream is hook-fed.
func TestHookIngestRoutesOpencodeProviderFrames(t *testing.T) {
	socketDir, err := os.MkdirTemp("", "hko")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(socketDir)
	socketPath := filepath.Join(socketDir, "i.sock")
	t.Setenv(agentHookSocketEnv, socketPath)

	transcript := filepath.Join(t.TempDir(), "opencode-session.log")
	if err := os.WriteFile(transcript, nil, 0o644); err != nil {
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

	openRequest, _ := json.Marshal(map[string]any{
		"id":     1,
		"method": "agent.session.open",
		"params": map[string]any{
			"provider":        "opencode",
			"session_id":      "oc-sess-1",
			"transcript_path": transcript,
		},
	})
	if _, err := io.WriteString(stdinWriter, string(openRequest)+"\n"); err != nil {
		t.Fatal(err)
	}
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

	awaitSocket(t, socketPath)
	// Routing is provider-scoped: a claude frame for the same session id must
	// not reach the opencode subscription.
	if code := runAgentHookEmit(
		[]string{"--socket", socketPath, `{"provider":"claude","session_id":"oc-sess-1","hook":"UserPromptSubmit","prompt":"wrong provider"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Fatalf("emit exit = %d", code)
	}
	if code := runAgentHookEmit(
		[]string{"--socket", socketPath, `{"provider":"opencode","session_id":"oc-sess-1","hook":"PreToolUse","tool_name":"bash","tool_use_id":"oc-call-1","detail":"bun test"}`},
		strings.NewReader(""),
	); code != 0 {
		t.Fatalf("emit exit = %d", code)
	}

	// A routed claude frame would surface as turn.started on this stream;
	// flag it whenever it shows up while waiting for the legitimate events.
	flagWrongProvider := func(frame map[string]any) {
		if payloadOfType(frame, "turn.started") != nil {
			t.Error("claude-provider frame leaked into the opencode subscription")
		}
	}
	started := awaitFrame(func(frame map[string]any) bool {
		flagWrongProvider(frame)
		return payloadOfType(frame, "item.started") != nil
	}, "item.started from opencode frame")
	item, _ := payloadOfType(started, "item.started")["item"].(map[string]any)
	if item["tool_use_id"] != "oc-call-1" || item["type"] != "command_execution" || item["title"] != "bun test" {
		t.Errorf("opencode item = %v", item)
	}

	closeRequest, _ := json.Marshal(map[string]any{
		"id":     2,
		"method": "agent.session.close",
		"params": map[string]any{"subscription_id": subscriptionID},
	})
	if _, err := io.WriteString(stdinWriter, string(closeRequest)+"\n"); err != nil {
		t.Fatal(err)
	}
	awaitFrame(func(frame map[string]any) bool {
		flagWrongProvider(frame)
		return frame["id"] == float64(2)
	}, "close response")
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
