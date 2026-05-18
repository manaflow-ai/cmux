package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func TestServeWSRequiresExplicitLeaseFile(t *testing.T) {
	var stderr bytes.Buffer
	code := run([]string{"serve", "--ws", "--listen", "127.0.0.1:0"}, strings.NewReader(""), &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("serve --ws without lease file exit = %d, want 2 stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "requires --auth-lease-file") {
		t.Fatalf("stderr should explain missing lease file: %q", stderr.String())
	}
}

func TestWebSocketPTYHealthIsAvailableWhenLocked(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/healthz status = %d, want 200", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode health body: %v", err)
	}
	if body["ok"] != true || body["locked"] != true {
		t.Fatalf("unexpected health body: %v", body)
	}
}

func TestWebSocketPTYRejectsMissingAndWrongLease(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "missing", "sess-missing", 80, 24)
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("missing lease should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}

	writeTestLease(t, leasePath, "correct-token", "sess-wrong", true, time.Now().Add(time.Minute))
	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "wrong-token", "sess-wrong", 80, 24)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong token should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
	if _, statErr := os.Stat(leasePath); statErr != nil {
		t.Fatalf("wrong-token attempt should not consume lease: %v", statErr)
	}

	writeTestLease(t, leasePath, "expired-token", "sess-expired", true, time.Now().Add(-time.Minute))
	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "expired-token", "sess-expired", 80, 24)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("expired token should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYRequiresSessionMatchAndConsumesLeaseOnce(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "cmux-secret", "sess-good", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-other", 80, 24)
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong session should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
	if _, statErr := os.Stat(leasePath); statErr != nil {
		t.Fatalf("wrong-session attempt should not consume lease: %v", statErr)
	}

	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-good", 100, 30)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}
	if _, statErr := os.Stat(leasePath); !os.IsNotExist(statErr) {
		t.Fatalf("successful auth should consume lease, stat err=%v", statErr)
	}
	_ = conn.Close(websocket.StatusNormalClosure, "done")

	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-good", 100, 30)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("replay should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYRunsShellOverBinaryFrames(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "terminal-token", "sess-shell", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, conn, "terminal-token", "sess-shell", 80, 24)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}

	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf '%b\\n' '\\103\\115\\125\\130\\137\\127\\123\\137\\117\\113'; exit\r")); err != nil {
		t.Fatalf("write terminal command: %v", err)
	}

	var output strings.Builder
	deadline := time.Now().Add(5 * time.Second)
	sawExpectedOutput := false
	for time.Now().Before(deadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(deadline))
		msgType, payload, err = conn.Read(readCtx)
		cancelRead()
		if err != nil {
			t.Fatalf("read terminal output: %v output=%q", err, output.String())
		}
		if msgType == websocket.MessageBinary {
			output.Write(payload)
			if strings.Contains(output.String(), "CMUX_WS_OK") {
				sawExpectedOutput = true
				break
			}
		}
	}
	if !sawExpectedOutput {
		t.Fatalf("timed out waiting for terminal output, got %q", output.String())
	}

	closeDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(closeDeadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(closeDeadline))
		_, _, err = conn.Read(readCtx)
		cancelRead()
		if err == nil {
			continue
		}
		if websocket.CloseStatus(err) != websocket.StatusNormalClosure {
			t.Fatalf("shell exit should close websocket normally, got err=%v status=%v output=%q", err, websocket.CloseStatus(err), output.String())
		}
		return
	}
	t.Fatalf("websocket stayed open after shell exit, output=%q", output.String())
}

func TestWebSocketPTYSeedsUTF8LocaleAndTerminalEnv(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "env-token", "sess-env", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, conn, "env-token", "sess-env", 80, 24)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}

	command := "printf '%s\\n' \"$LANG|$LC_CTYPE|$LC_ALL|$TERM|$COLORTERM|$TERM_PROGRAM|$CMUX_REMOTE_TRANSPORT\"; locale charmap; exit\r"
	if err := conn.Write(ctx, websocket.MessageBinary, []byte(command)); err != nil {
		t.Fatalf("write terminal command: %v", err)
	}

	var output strings.Builder
	wantTerminalEnv := "|xterm-256color|truecolor|ghostty|ws"
	wantCharmap := "UTF-8"
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(deadline))
		msgType, payload, err = conn.Read(readCtx)
		cancelRead()
		if err != nil {
			t.Fatalf("read terminal env: %v output=%q", err, output.String())
		}
		if msgType != websocket.MessageBinary {
			continue
		}
		output.Write(payload)
		if strings.Contains(output.String(), wantTerminalEnv) && strings.Contains(output.String(), wantCharmap) {
			return
		}
	}
	t.Fatalf("timed out waiting for terminal env, got %q", output.String())
}

func dialPTY(t *testing.T, ctx context.Context, serverURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/terminal"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	return conn
}

func sendAuth(t *testing.T, ctx context.Context, conn *websocket.Conn, token, sessionID string, cols, rows int) {
	t.Helper()
	payload, err := json.Marshal(wsPTYAuthFrame{
		Type:      "auth",
		Token:     token,
		SessionID: sessionID,
		Cols:      cols,
		Rows:      rows,
	})
	if err != nil {
		t.Fatalf("marshal auth: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write auth: %v", err)
	}
}

func writeTestLease(t *testing.T, path, token, sessionID string, singleUse bool, expiresAt time.Time) {
	t.Helper()
	sum := sha256.Sum256([]byte(token))
	lease := wsPTYLease{
		Version:       1,
		TokenSHA256:   hex.EncodeToString(sum[:]),
		ExpiresAtUnix: expiresAt.Unix(),
		SessionID:     sessionID,
		SingleUse:     singleUse,
	}
	data, err := json.Marshal(lease)
	if err != nil {
		t.Fatalf("marshal lease: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write lease: %v", err)
	}
}
