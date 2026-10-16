package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestTmuxListWindowsUsesOneWorkspaceSnapshot(t *testing.T) {
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	recorder := startTmuxCorpusRPCRecorder(t)
	recorder.mu.Lock()
	recorder.workspaces = nil
	for i := 0; i < 1000; i++ {
		recorder.workspaces = append(recorder.workspaces, map[string]any{
			"id":    fmt.Sprintf("11111111-1111-4111-8111-%012d", i),
			"index": i, "title": fmt.Sprintf("workspace-%d", i),
		})
	}
	recorder.mu.Unlock()
	output, err := os.CreateTemp(t.TempDir(), "windows-*")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	original := os.Stdout
	os.Stdout = output
	defer func() { os.Stdout = original }()
	if err := tmuxListWindows(&rpcContext{socketPath: recorder.socketPath}, []string{"-F", "#{window_name}"}); err != nil {
		t.Fatal(err)
	}
	if count := len(recorder.requestsFor("workspace.list")); count != 1 {
		t.Fatalf("list-windows fetched the 1000-workspace collection %d times, want once", count)
	}
	data, err := os.ReadFile(output.Name())
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1000 {
		t.Fatalf("rendered %d windows, want 1000", len(lines))
	}
	for i, line := range lines {
		if line != fmt.Sprintf("workspace-%d", i) {
			t.Fatalf("window %d = %q", i, line)
		}
	}
}
