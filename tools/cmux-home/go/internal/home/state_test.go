package home

import "testing"

func TestParseStateAcceptsSharedLikeShape(t *testing.T) {
	state, err := ParseState([]byte(`{
		"generatedAt": "2026-05-11T20:00:00Z",
		"sessions": [
			{
				"id": "row-1",
				"session_id": "claude-native-1",
				"agent": {"kind": "Claude Code"},
				"state": "in_progress",
				"prompt": "Fix the reload link",
				"workingDirectory": "/tmp/cmux",
				"git": {"branch": "feat-home"},
				"messages": [{"role": "user", "content": "ignored because prompt wins"}]
			},
			{
				"sessionId": "codex-native-1",
				"kind": "codex",
				"status": "completed",
				"messages": [{"role": "user", "content": "Review adapter metadata"}]
			}
		],
		"tasks": [
			{"id": "task-1", "title": "Start home", "status": "pending", "adapter": "Open Code"}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseState returned error: %v", err)
	}

	if got := len(state.Sessions); got != 2 {
		t.Fatalf("sessions = %d, want 2", got)
	}
	first := state.Sessions[0]
	if first.Adapter != "claude" {
		t.Fatalf("first adapter = %q, want claude", first.Adapter)
	}
	if first.Status != "working" {
		t.Fatalf("first status = %q, want working", first.Status)
	}
	if first.SessionID != "claude-native-1" {
		t.Fatalf("first session id = %q", first.SessionID)
	}
	if first.Branch != "feat-home" {
		t.Fatalf("first branch = %q", first.Branch)
	}
	if got := state.Sessions[1].Title; got != "Review adapter metadata" {
		t.Fatalf("second title = %q", got)
	}
	if got := state.Tasks[0].Adapter; got != "opencode" {
		t.Fatalf("task adapter = %q, want opencode", got)
	}
}

func TestFallbackStateHasAllPrototypeAdapters(t *testing.T) {
	state := FallbackState()
	counts := AdapterCounts(state.Sessions)
	got := map[string]int{}
	for _, count := range counts {
		got[count.Adapter] = count.Count
	}
	for _, adapter := range []string{"claude", "codex", "opencode", "pi"} {
		if got[adapter] != 1 {
			t.Fatalf("fallback count for %s = %d, want 1", adapter, got[adapter])
		}
	}
}

func TestParseStateRejectsUnsupportedSchemaVersion(t *testing.T) {
	_, err := ParseState([]byte(`{"schemaVersion":2,"sessions":[]}`))
	if err == nil {
		t.Fatal("ParseState returned nil error for unsupported schemaVersion")
	}
}

func TestParseStateRejectsSchemaStatusOutsideContract(t *testing.T) {
	_, err := ParseState([]byte(`{
		"schemaVersion": 1,
		"sessions": [
			{"id": "bad", "agent": "codex", "agentSessionId": "bad", "status": "failed"}
		]
	}`))
	if err == nil {
		t.Fatal("ParseState returned nil error for invalid schema status")
	}
}

func TestParseStateReadsCanonicalSchemaFields(t *testing.T) {
	state, err := ParseState([]byte(`{
		"schemaVersion": 1,
		"sessions": [
			{
				"id": "codex:canonical",
				"agent": "codex",
				"agentSessionId": "canonical",
				"title": "Canonical",
				"status": "awaiting",
				"updatedAt": "2026-05-12T16:00:00Z",
				"workspace": {
					"id": "workspace-id",
					"cwd": "/tmp/cmux",
					"git": {"branch": "feat/canonical"}
				},
				"activity": {"phase": "awaitingUser", "lastMessage": "Permission requested"},
				"attention": {"promptSummary": "Run tests"},
				"resume": {"command": ["codex", "resume", "canonical"]}
			}
		]
	}`))
	if err != nil {
		t.Fatalf("ParseState returned error: %v", err)
	}

	session := state.Sessions[0]
	if session.ResumeSessionID() != "canonical" {
		t.Fatalf("session id = %q, want canonical", session.ResumeSessionID())
	}
	if session.WorkingDir() != "/tmp/cmux" {
		t.Fatalf("cwd = %q, want /tmp/cmux", session.WorkingDir())
	}
	if session.Branch != "feat/canonical" {
		t.Fatalf("branch = %q, want feat/canonical", session.Branch)
	}
	if session.Preview != "Permission requested" {
		t.Fatalf("preview = %q, want Permission requested", session.Preview)
	}
	if session.ResumeCommand != "codex resume canonical" {
		t.Fatalf("resume command = %q, want codex resume canonical", session.ResumeCommand)
	}
}
