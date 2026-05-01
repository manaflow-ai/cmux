package main

import (
	"bufio"
	"encoding/json"
	"io"
	"testing"
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
