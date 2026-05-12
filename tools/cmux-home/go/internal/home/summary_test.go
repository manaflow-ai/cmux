package home

import "testing"

func TestSummaryIsDeterministic(t *testing.T) {
	state := HomeState{
		Sessions: []Session{
			{ID: "done-1", Adapter: "pi", Status: "completed", Title: "Finished", CWD: "/tmp/pi"},
			{ID: "run-2", SessionID: "codex-native", Adapter: "codex", Status: "working", Title: "Beta", CWD: "/tmp/codex"},
			{ID: "run-1", Adapter: "claude", Status: "working", Title: "Alpha", CWD: "/tmp/claude"},
		},
		Tasks: []Task{{ID: "task", Title: "Queued"}},
	}

	want := `cmux home
adapters: claude=1 codex=1 opencode=0 pi=1
working: 2
  claude run-1 Alpha [/tmp/claude]
  codex codex-native Beta [/tmp/codex]
completed: 1
  pi done-1 Finished [/tmp/pi]
selected: run-1
resume: cd '/tmp/claude' && 'claude' '--resume' 'run-1'
task prompt: 1 queued
`
	if got := Summary(state); got != want {
		t.Fatalf("Summary mismatch\n--- got ---\n%s--- want ---\n%s", got, want)
	}
}
