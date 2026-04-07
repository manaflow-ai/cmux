package compat

import (
	"bufio"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
)

func TestHelloFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	client := newUnixJSONRPCClient(t, socketPath)
	resp := client.Call(t, map[string]any{
		"id":     "1",
		"method": "hello",
		"params": map[string]any{},
	})

	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", resp)
	}
}

func TestTerminalEchoFixtureAgainstUnixSocketBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write := client.Call(t, map[string]any{
		"id":     "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": "dev",
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}
}

func TestUnixSocketAttachReportsNormalizedTinyTerminalWidth(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write1 := client.Call(t, map[string]any{
		"id":     "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": "dev",
			"data":       "aGVsbG8K",
		},
	})
	if ok, _ := write1["ok"].(bool); !ok {
		t.Fatalf("initial terminal.write should succeed: %+v", write1)
	}

	read1 := client.Call(t, map[string]any{
		"id":     "3",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": "dev",
			"offset":     0,
			"max_bytes":  1024,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := read1["ok"].(bool); !ok {
		t.Fatalf("initial terminal.read should succeed: %+v", read1)
	}

	attach := client.Call(t, map[string]any{
		"id":     "4",
		"method": "session.attach",
		"params": map[string]any{
			"session_id":    "dev",
			"attachment_id": "cli-1",
			"cols":          1,
			"rows":          1,
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", attach)
	}

	result, _ := attach["result"].(map[string]any)
	if got := int(result["effective_cols"].(float64)); got != 2 {
		t.Fatalf("effective_cols = %d, want 2 after clamping: %+v", got, attach)
	}
}

func TestUnixSocketTerminalReadReportsTruncationAfterBufferOverflow(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "overflow-dev",
			"command":    "printf READY; stty raw -echo -onlcr; exec cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	initial := client.Call(t, map[string]any{
		"id":     "2",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": "overflow-dev",
			"offset":     0,
			"max_bytes":  1024,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := initial["ok"].(bool); !ok {
		t.Fatalf("initial terminal.read should succeed: %+v", initial)
	}
	initialResult := initial["result"].(map[string]any)
	initialData, err := base64.StdEncoding.DecodeString(initialResult["data"].(string))
	if err != nil {
		t.Fatalf("decode initial terminal.read data: %v", err)
	}
	if string(initialData) != "READY" {
		t.Fatalf("initial terminal.read data = %q, want %q", initialData, "READY")
	}
	initialOffset := int(initialResult["offset"].(float64))

	chunk := strings.Repeat("abcdefghij", 2000)
	for i := 0; i < 80; i++ {
		write := client.Call(t, map[string]any{
			"id":     strconv.Itoa(i + 3),
			"method": "terminal.write",
			"params": map[string]any{
				"session_id": "overflow-dev",
				"data":       base64.StdEncoding.EncodeToString([]byte(chunk)),
			},
		})
		if ok, _ := write["ok"].(bool); !ok {
			t.Fatalf("terminal.write chunk %d should succeed: %+v", i, write)
		}
	}

	read := client.Call(t, map[string]any{
		"id":     "overflow-read",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": "overflow-dev",
			"offset":     initialOffset,
			"max_bytes":  32,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := read["ok"].(bool); !ok {
		t.Fatalf("terminal.read should succeed: %+v", read)
	}

	result := read["result"].(map[string]any)
	if truncated, _ := result["truncated"].(bool); !truncated {
		t.Fatalf("terminal.read should report truncation after buffer overflow: %+v", read)
	}
	baseOffset := int(result["base_offset"].(float64))
	offset := int(result["offset"].(float64))
	if baseOffset <= 0 {
		t.Fatalf("terminal.read base_offset = %d, want > 0 after truncation: %+v", baseOffset, read)
	}
	if offset <= baseOffset {
		t.Fatalf("terminal.read offset = %d, want > base_offset %d: %+v", offset, baseOffset, read)
	}
}

func TestUnixSocketAcceptsFragmentedJSONRequestLines(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial unix socket %s: %v", socketPath, err)
	}
	defer conn.Close()
	reader := bufio.NewReader(conn)

	if _, err := conn.Write([]byte(`{"id":"1","me`)); err != nil {
		t.Fatalf("write fragmented prefix: %v", err)
	}
	if _, err := conn.Write([]byte(`thod":"hello","params":{}}`)); err != nil {
		t.Fatalf("write fragmented suffix: %v", err)
	}
	if _, err := conn.Write([]byte("\n")); err != nil {
		t.Fatalf("write newline: %v", err)
	}

	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read fragmented hello response: %v", err)
	}
	var firstResp map[string]any
	if err := json.Unmarshal([]byte(line), &firstResp); err != nil {
		t.Fatalf("decode fragmented hello response %q: %v", strings.TrimSpace(line), err)
	}
	if ok, _ := firstResp["ok"].(bool); !ok {
		t.Fatalf("fragmented hello should succeed: %+v", firstResp)
	}

	resp := writeAndReadJSONWithReader(t, conn, reader, map[string]any{
		"id":     "2",
		"method": "ping",
		"params": map[string]any{},
	})
	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("ping after fragmented request should succeed: %+v", resp)
	}
}

func TestUnixServeStartsWebSocketListenerWhenConfigured(t *testing.T) {
	bin := daemonBinary(t)
	const wsSecret = "compat-ws-secret"
	_, wsAddr := startUnixDaemonWithWS(t, bin, wsSecret)

	conn, err := net.Dial("tcp", wsAddr)
	if err != nil {
		t.Fatalf("dial websocket listener %s: %v", wsAddr, err)
	}
	defer conn.Close()

	reader := bufio.NewReader(conn)
	request := fmt.Sprintf(
		"GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: Y211eC13cy1jb21wYXQ=\r\nSec-WebSocket-Version: 13\r\n\r\n",
		wsAddr,
	)
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatalf("write websocket upgrade request: %v", err)
	}

	statusLine, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read websocket status line: %v", err)
	}
	if !strings.Contains(statusLine, "101 Switching Protocols") {
		t.Fatalf("websocket upgrade status = %q, want 101 Switching Protocols", strings.TrimSpace(statusLine))
	}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read websocket response headers: %v", err)
		}
		if line == "\r\n" {
			break
		}
	}

	writeMaskedWebSocketTextFrame(t, conn, fmt.Sprintf(`{"secret":"%s"}`, wsSecret))
	auth := readWebSocketJSONFrame(t, reader)
	if ok, _ := auth["ok"].(bool); !ok {
		t.Fatalf("websocket auth should succeed: %+v", auth)
	}

	writeMaskedWebSocketTextFrame(t, conn, `{"id":1,"method":"hello","params":{}}`)
	hello := readWebSocketJSONFrame(t, reader)
	if ok, _ := hello["ok"].(bool); !ok {
		t.Fatalf("websocket hello should succeed: %+v", hello)
	}
	result, _ := hello["result"].(map[string]any)
	if name, _ := result["name"].(string); name != "cmuxd-remote" {
		t.Fatalf("websocket hello name = %q, want %q", name, "cmuxd-remote")
	}

	writeMaskedWebSocketTextFrame(t, conn, `{"id":2,"method":"session.open","params":{"session_id":"ws-compat"}}`)
	open := readWebSocketJSONFrame(t, reader)
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("websocket session.open should succeed: %+v", open)
	}

	writeMaskedWebSocketTextFrame(t, conn, `{"id":3,"method":"session.close","params":{"session_id":"ws-compat"}}`)
	closeResp := readWebSocketJSONFrame(t, reader)
	if ok, _ := closeResp["ok"].(bool); !ok {
		t.Fatalf("websocket session.close should succeed: %+v", closeResp)
	}
}

func writeMaskedWebSocketTextFrame(t *testing.T, conn net.Conn, text string) {
	t.Helper()

	payload := []byte(text)
	frame := make([]byte, 0, len(payload)+14)
	frame = append(frame, 0x81)
	switch {
	case len(payload) <= 125:
		frame = append(frame, byte(0x80|len(payload)))
	case len(payload) <= 0xFFFF:
		frame = append(frame, 0x80|126)
		extended := make([]byte, 2)
		binary.BigEndian.PutUint16(extended, uint16(len(payload)))
		frame = append(frame, extended...)
	default:
		frame = append(frame, 0x80|127)
		extended := make([]byte, 8)
		binary.BigEndian.PutUint64(extended, uint64(len(payload)))
		frame = append(frame, extended...)
	}

	mask := []byte{0x10, 0x32, 0x54, 0x76}
	frame = append(frame, mask...)
	for index, b := range payload {
		frame = append(frame, b^mask[index%len(mask)])
	}

	if _, err := conn.Write(frame); err != nil {
		t.Fatalf("write websocket frame: %v", err)
	}
}

func readWebSocketJSONFrame(t *testing.T, reader *bufio.Reader) map[string]any {
	t.Helper()

	payload := readWebSocketTextFrame(t, reader)
	var response map[string]any
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatalf("decode websocket payload %q: %v", payload, err)
	}
	return response
}

func readWebSocketTextFrame(t *testing.T, reader *bufio.Reader) string {
	t.Helper()

	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		t.Fatalf("read websocket header: %v", err)
	}
	if opcode := header[0] & 0x0F; opcode == 0x08 {
		t.Fatal("websocket closed unexpectedly")
	}

	payloadLen := int(header[1] & 0x7F)
	switch payloadLen {
	case 126:
		extended := make([]byte, 2)
		if _, err := io.ReadFull(reader, extended); err != nil {
			t.Fatalf("read websocket extended length: %v", err)
		}
		payloadLen = int(binary.BigEndian.Uint16(extended))
	case 127:
		extended := make([]byte, 8)
		if _, err := io.ReadFull(reader, extended); err != nil {
			t.Fatalf("read websocket extended length: %v", err)
		}
		payloadLen = int(binary.BigEndian.Uint64(extended))
	}

	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(reader, payload); err != nil {
		t.Fatalf("read websocket payload: %v", err)
	}
	return string(payload)
}

func TestUnixSocketTerminalWriteRejectsInvalidBase64(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "invalid-b64-dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	write := client.Call(t, map[string]any{
		"id":     "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": "invalid-b64-dev",
			"data":       "%%%not-base64%%%",
		},
	})
	if ok, _ := write["ok"].(bool); ok {
		t.Fatalf("terminal.write with invalid base64 should fail: %+v", write)
	}
	errObj := write["error"].(map[string]any)
	if got := errObj["message"].(string); got != "terminal.write data must be base64" {
		t.Fatalf("terminal.write invalid base64 message = %q, want %q", got, "terminal.write data must be base64")
	}
}
