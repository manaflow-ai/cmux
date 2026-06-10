package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Drives the real stdio server end to end: open a transcript subscription,
// receive the snapshot frame, append to the file, receive the tail frame.
func TestAgentSessionOpenStreamsSnapshotAndTail(t *testing.T) {
	transcript := filepath.Join(t.TempDir(), "session.jsonl")
	line1 := `{"type":"user","uuid":"u1","timestamp":"2026-06-09T10:00:00.000Z","sessionId":"sess-rpc","cwd":"/tmp/project","message":{"role":"user","content":"hello daemon"}}` + "\n"
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

	send(`{"id":1,"method":"hello","params":{}}`)
	hello := awaitFrame(func(frame map[string]any) bool {
		return frame["id"] == float64(1)
	}, "hello response")
	capabilities, _ := hello["result"].(map[string]any)["capabilities"].([]any)
	sawAgentCapability := false
	for _, capability := range capabilities {
		if capability == "agent.conversation" {
			sawAgentCapability = true
		}
	}
	if !sawAgentCapability {
		t.Errorf("hello capabilities missing agent.conversation: %v", capabilities)
	}

	openRequest, _ := json.Marshal(map[string]any{
		"id":     2,
		"method": "agent.session.open",
		"params": map[string]any{"provider": "claude", "transcript_path": transcript},
	})
	send(string(openRequest))
	opened := awaitFrame(func(frame map[string]any) bool {
		return frame["id"] == float64(2)
	}, "open response")
	if ok, _ := opened["ok"].(bool); !ok {
		t.Fatalf("open failed: %v", opened)
	}
	result, _ := opened["result"].(map[string]any)
	subscriptionID, _ := result["subscription_id"].(string)
	if subscriptionID == "" {
		t.Fatalf("missing subscription_id: %v", result)
	}
	session, _ := result["session"].(map[string]any)
	if session["session_id"] != "sess-rpc" {
		t.Errorf("open session = %v", session)
	}

	isAgentEvent := func(frame map[string]any, eventType string) bool {
		if frame["event"] != "agent.session.event" || frame["subscription_id"] != subscriptionID {
			return false
		}
		payload, _ := frame["payload"].(map[string]any)
		return payload != nil && payload["type"] == eventType
	}

	snapshot := awaitFrame(func(frame map[string]any) bool {
		return isAgentEvent(frame, "snapshot")
	}, "snapshot frame")
	items, _ := snapshot["payload"].(map[string]any)["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("snapshot items = %v", items)
	}

	line2 := `{"type":"user","uuid":"u2","timestamp":"2026-06-09T10:00:01.000Z","sessionId":"sess-rpc","cwd":"/tmp/project","message":{"role":"user","content":"second message"}}` + "\n"
	file, err := os.OpenFile(transcript, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(line2); err != nil {
		t.Fatal(err)
	}
	file.Close()

	tail := awaitFrame(func(frame map[string]any) bool {
		return isAgentEvent(frame, "item.completed")
	}, "tail item frame")
	item, _ := tail["payload"].(map[string]any)["item"].(map[string]any)
	if item["text"] != "second message" {
		t.Errorf("tail item = %v", item)
	}

	closeRequest, _ := json.Marshal(map[string]any{
		"id":     3,
		"method": "agent.session.close",
		"params": map[string]any{"subscription_id": subscriptionID},
	})
	send(string(closeRequest))
	awaitFrame(func(frame map[string]any) bool {
		return frame["id"] == float64(3)
	}, "close response")

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

func TestAgentSessionOpenRejectsMissingParams(t *testing.T) {
	server := &rpcServer{frameWriter: &stdioFrameWriter{writer: bufio.NewWriter(io.Discard)}}
	response := server.handleAgentSessionOpen(rpcRequest{ID: 1, Method: "agent.session.open", Params: map[string]any{}})
	if response.OK || response.Error == nil || response.Error.Code != "invalid_request" {
		t.Errorf("missing provider should be invalid_request: %+v", response)
	}
	response = server.handleAgentSessionOpen(rpcRequest{ID: 2, Method: "agent.session.open", Params: map[string]any{"provider": "claude"}})
	if response.OK || response.Error == nil || response.Error.Code != "invalid_request" {
		t.Errorf("missing session ref should be invalid_request: %+v", response)
	}
}
