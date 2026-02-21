package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunVersion(t *testing.T) {
	var out bytes.Buffer
	code := run([]string{"version"}, strings.NewReader(""), &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run version exit code = %d, want 0", code)
	}
	if strings.TrimSpace(out.String()) == "" {
		t.Fatalf("version output should not be empty")
	}
}

func TestRunStdioHelloAndPing(t *testing.T) {
	input := strings.NewReader(
		`{"id":1,"method":"hello","params":{}}` + "\n" +
			`{"id":2,"method":"ping","params":{}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d response lines, want 2: %q", len(lines), out.String())
	}

	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("failed to decode first response: %v", err)
	}
	if ok, _ := first["ok"].(bool); !ok {
		t.Fatalf("first response should be ok=true: %v", first)
	}
	firstResult, _ := first["result"].(map[string]any)
	if firstResult == nil {
		t.Fatalf("first response missing result object: %v", first)
	}
	capabilities, _ := firstResult["capabilities"].([]any)
	if len(capabilities) < 2 {
		t.Fatalf("hello should return capabilities: %v", firstResult)
	}

	var second map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("failed to decode second response: %v", err)
	}
	if ok, _ := second["ok"].(bool); !ok {
		t.Fatalf("second response should be ok=true: %v", second)
	}
}
