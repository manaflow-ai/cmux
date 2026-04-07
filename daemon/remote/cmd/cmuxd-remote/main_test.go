package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/rpc"
)

func TestServeStdioSupportsHelloAndSessionLifecycle(t *testing.T) {
	t.Parallel()

	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()

	done := make(chan int, 1)
	go func() {
		done <- run([]string{"serve", "--stdio"}, stdinR, stdoutW, io.Discard)
	}()

	reader := bufio.NewReader(stdoutR)
	send := func(line string) map[string]any {
		t.Helper()

		if _, err := io.WriteString(stdinW, line+"\n"); err != nil {
			t.Fatalf("write request: %v", err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response: %v", err)
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		return payload
	}

	hello := send(`{"id":1,"method":"hello","params":{}}`)
	if ok, _ := hello["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", hello)
	}

	open := send(`{"id":2,"method":"session.open","params":{"cols":120,"rows":40}}`)
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("session.open should succeed: %+v", open)
	}

	_ = stdinW.Close()
	if code := <-done; code != 0 {
		t.Fatalf("serve exit code = %d, want 0", code)
	}
}

func TestServeStdioSupportsTerminalOpenReadAndWrite(t *testing.T) {
	t.Parallel()

	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()

	done := make(chan int, 1)
	go func() {
		done <- run([]string{"serve", "--stdio"}, stdinR, stdoutW, io.Discard)
	}()

	reader := bufio.NewReader(stdoutR)
	send := func(line string) map[string]any {
		t.Helper()

		if _, err := io.WriteString(stdinW, line+"\n"); err != nil {
			t.Fatalf("write request: %v", err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response: %v", err)
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		return payload
	}

	open := send(`{"id":1,"method":"terminal.open","params":{"command":"printf READY; stty raw -echo -onlcr; exec cat","cols":120,"rows":40}}`)
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}
	openResult, ok := open["result"].(map[string]any)
	if !ok {
		t.Fatalf("terminal.open result missing: %+v", open)
	}
	sessionID, _ := openResult["session_id"].(string)
	if sessionID == "" {
		t.Fatalf("terminal.open missing session_id: %+v", openResult)
	}

	read := send(`{"id":2,"method":"terminal.read","params":{"session_id":"` + sessionID + `","offset":0,"max_bytes":1024,"timeout_ms":1000}}`)
	if ok, _ := read["ok"].(bool); !ok {
		t.Fatalf("terminal.read should succeed: %+v", read)
	}
	readResult, ok := read["result"].(map[string]any)
	if !ok {
		t.Fatalf("terminal.read result missing: %+v", read)
	}
	readyChunk := decodeBase64Field(t, readResult, "data")
	if string(readyChunk) != "READY" {
		t.Fatalf("terminal.read data = %q, want %q", string(readyChunk), "READY")
	}
	offsetValue, ok := readResult["offset"].(float64)
	if !ok {
		t.Fatalf("terminal.read missing offset: %+v", readResult)
	}

	write := send(`{"id":3,"method":"terminal.write","params":{"session_id":"` + sessionID + `","data":"aGVsbG8K"}}`)
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}

	readEcho := send(`{"id":4,"method":"terminal.read","params":{"session_id":"` + sessionID + `","offset":` + jsonNumber(offsetValue) + `,"max_bytes":1024,"timeout_ms":1000}}`)
	if ok, _ := readEcho["ok"].(bool); !ok {
		t.Fatalf("terminal.read echo should succeed: %+v", readEcho)
	}
	echoResult, ok := readEcho["result"].(map[string]any)
	if !ok {
		t.Fatalf("terminal.read echo result missing: %+v", readEcho)
	}
	echoChunk := decodeBase64Field(t, echoResult, "data")
	if string(echoChunk) != "hello\n" {
		t.Fatalf("echo chunk = %q, want %q", string(echoChunk), "hello\n")
	}

	_ = stdinW.Close()
	if code := <-done; code != 0 {
		t.Fatalf("serve exit code = %d, want 0", code)
	}
}

func TestServeStdioRejectsDuplicateTerminalOpenWithoutCorruptingExistingSession(t *testing.T) {
	t.Parallel()

	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()

	done := make(chan int, 1)
	go func() {
		done <- run([]string{"serve", "--stdio"}, stdinR, stdoutW, io.Discard)
	}()

	reader := bufio.NewReader(stdoutR)
	send := func(line string) map[string]any {
		t.Helper()

		if _, err := io.WriteString(stdinW, line+"\n"); err != nil {
			t.Fatalf("write request: %v", err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response: %v", err)
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		return payload
	}

	firstOpen := send(`{"id":1,"method":"terminal.open","params":{"session_id":"dup-demo","command":"printf READY; stty raw -echo -onlcr; exec cat","cols":120,"rows":40}}`)
	if ok, _ := firstOpen["ok"].(bool); !ok {
		t.Fatalf("first terminal.open should succeed: %+v", firstOpen)
	}

	secondOpen := send(`{"id":2,"method":"terminal.open","params":{"session_id":"dup-demo","command":"printf BAD; exec cat","cols":80,"rows":24}}`)
	if ok, _ := secondOpen["ok"].(bool); ok {
		t.Fatalf("second terminal.open should fail: %+v", secondOpen)
	}
	if got := nestedString(secondOpen, "error", "code"); got != "already_exists" {
		t.Fatalf("second terminal.open error code = %q, want %q", got, "already_exists")
	}

	read := send(`{"id":3,"method":"terminal.read","params":{"session_id":"dup-demo","offset":0,"max_bytes":1024,"timeout_ms":1000}}`)
	if ok, _ := read["ok"].(bool); !ok {
		t.Fatalf("terminal.read should still succeed for original session: %+v", read)
	}
	readResult, ok := read["result"].(map[string]any)
	if !ok {
		t.Fatalf("terminal.read result missing: %+v", read)
	}
	if string(decodeBase64Field(t, readResult, "data")) != "READY" {
		t.Fatalf("terminal.read data = %q, want %q", string(decodeBase64Field(t, readResult, "data")), "READY")
	}

	_ = stdinW.Close()
	if code := <-done; code != 0 {
		t.Fatalf("serve exit code = %d, want 0", code)
	}
}

func TestSessionAttachDetachesIfRawModeSetupFails(t *testing.T) {
	t.Parallel()

	socketPath := startTestUnixDaemon(t)
	open := callUnixRPC(t, socketPath, map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "attach-cleanup",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	if code := sessionAttach(socketPath, "attach-cleanup"); code != 1 {
		t.Fatalf("sessionAttach exit code = %d, want 1 when raw mode setup fails", code)
	}

	status := callUnixRPC(t, socketPath, map[string]any{
		"id":     2,
		"method": "session.status",
		"params": map[string]any{
			"session_id": "attach-cleanup",
		},
	})
	if ok, _ := status["ok"].(bool); !ok {
		t.Fatalf("session.status should succeed: %+v", status)
	}
	attachments := status["result"].(map[string]any)["attachments"].([]any)
	if len(attachments) != 1 {
		t.Fatalf("expected only the bootstrap attachment after failed attach, got %+v", attachments)
	}
	attachmentID := attachments[0].(map[string]any)["attachment_id"].(string)
	if strings.HasPrefix(attachmentID, "cli-") {
		t.Fatalf("failed attach left a cli attachment behind: %+v", attachments)
	}
}

func decodeBase64Field(t *testing.T, payload map[string]any, key string) []byte {
	t.Helper()

	encoded, _ := payload[key].(string)
	if encoded == "" {
		t.Fatalf("missing %s field in %+v", key, payload)
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode %s: %v", key, err)
	}
	return data
}

func jsonNumber(value float64) string {
	return fmt.Sprintf("%.0f", value)
}

func nestedString(payload map[string]any, keys ...string) string {
	current := payload
	for index, key := range keys {
		value, ok := current[key]
		if !ok {
			return ""
		}
		if index == len(keys)-1 {
			text, _ := value.(string)
			return text
		}
		next, _ := value.(map[string]any)
		if next == nil {
			return ""
		}
		current = next
	}
	return ""
}

func startTestUnixDaemon(t *testing.T) string {
	t.Helper()

	socketDir, err := os.MkdirTemp("", "cmuxd-test-")
	if err != nil {
		t.Fatalf("mkdir temp socket dir: %v", err)
	}
	shortDir := filepath.Join(os.TempDir(), filepath.Base(socketDir))
	if renameErr := os.Rename(socketDir, shortDir); renameErr == nil {
		socketDir = shortDir
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketDir)
	})

	socketPath := filepath.Join(socketDir, "daemon.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen on unix socket: %v", err)
	}

	server := newDaemonServer()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				if errors.Is(err, net.ErrClosed) {
					return
				}
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_ = rpc.NewServer(server.handleRequest).Serve(conn, conn)
			}(conn)
		}
	}()

	t.Cleanup(func() {
		_ = listener.Close()
		server.closeAll()
		<-done
	})
	return socketPath
}

func callUnixRPC(t *testing.T, socketPath string, payload map[string]any) map[string]any {
	t.Helper()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial unix socket %s: %v", socketPath, err)
	}
	defer conn.Close()

	reader := bufio.NewReader(conn)
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write payload: %v", err)
	}

	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read response: %v", err)
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatalf("decode response %q: %v", line, err)
	}
	return response
}
