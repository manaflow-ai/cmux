package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func TestTmuxCorpusWebSocketPTYInitialSizeAndResizeControl(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, &bytes.Buffer{}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "size-token", "sess-size", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, conn, "size-token", "sess-size", 40, 10)

	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}

	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf 'SIZE1:'; stty size\r")); err != nil {
		t.Fatalf("write first size probe: %v", err)
	}
	output := readPTYBinaryUntil(t, ctx, conn, "SIZE1:10 40")

	resize, err := json.Marshal(wsPTYControlFrame{Type: "resize", Cols: 100, Rows: 31})
	if err != nil {
		t.Fatalf("marshal resize: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, resize); err != nil {
		t.Fatalf("write resize control frame: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf 'SIZE2:'; stty size; exit\r")); err != nil {
		t.Fatalf("write second size probe: %v", err)
	}
	output += readPTYBinaryUntil(t, ctx, conn, "SIZE2:31 100")

	if !strings.Contains(output, "SIZE1:10 40") {
		t.Fatalf("initial PTY size missing from output: %q", output)
	}
	if !strings.Contains(output, "SIZE2:31 100") {
		t.Fatalf("resized PTY size missing from output: %q", output)
	}
}

func readPTYBinaryUntil(t *testing.T, ctx context.Context, conn *websocket.Conn, needle string) string {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	var output strings.Builder
	for time.Now().Before(deadline) {
		readCtx, cancel := context.WithTimeout(ctx, time.Until(deadline))
		msgType, payload, err := conn.Read(readCtx)
		cancel()
		if err != nil {
			t.Fatalf("read PTY output looking for %q: %v output=%q", needle, err, output.String())
		}
		if msgType != websocket.MessageBinary {
			continue
		}
		output.Write(payload)
		if strings.Contains(output.String(), needle) {
			return output.String()
		}
	}
	t.Fatalf("timed out waiting for %q in PTY output %q", needle, output.String())
	return output.String()
}
