package compat

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
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
