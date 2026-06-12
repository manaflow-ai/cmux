package agentconv

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Golden fixtures double as the cross-language contract: testdata/*/basic.jsonl
// inputs and testdata/*/expected.json wire-form outputs. Regenerate with
// UPDATE_GOLDEN=1 go test ./agentconv -run TestGolden, then review the diff.

func parseFixture(t *testing.T, provider ProviderID, path string) *conversation {
	t.Helper()
	parser := newTranscriptParser(provider, path)
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), maxTranscriptLineBytes)
	for scanner.Scan() {
		parser.consumeLine(scanner.Bytes())
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan fixture: %v", err)
	}
	return parser.conv()
}

func checkGolden(t *testing.T, conversation *conversation, expectedPath string) {
	t.Helper()
	got, err := json.MarshalIndent(struct {
		Session SessionRef `json:"session"`
		Items   []Item     `json:"items"`
	}{Session: conversation.session, Items: conversation.items}, "", "  ")
	if err != nil {
		t.Fatalf("marshal items: %v", err)
	}
	got = append(got, '\n')
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(expectedPath, got, 0o644); err != nil {
			t.Fatalf("update golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(expectedPath)
	if err != nil {
		t.Fatalf("read golden (run with UPDATE_GOLDEN=1 to create): %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("golden mismatch for %s\n--- got ---\n%s\n--- want ---\n%s", expectedPath, got, want)
	}
}

func TestGoldenClaude(t *testing.T) {
	conversation := parseFixture(t, ProviderClaude, filepath.Join("testdata", "claude", "basic.jsonl"))
	checkGolden(t, conversation, filepath.Join("testdata", "claude", "expected.json"))
}

func TestGoldenCodex(t *testing.T) {
	conversation := parseFixture(t, ProviderCodex, filepath.Join("testdata", "codex", "basic.jsonl"))
	checkGolden(t, conversation, filepath.Join("testdata", "codex", "expected.json"))
}

func TestClaudeToolFolding(t *testing.T) {
	conversation := parseFixture(t, ProviderClaude, filepath.Join("testdata", "claude", "basic.jsonl"))

	byID := map[string]Item{}
	for _, item := range conversation.items {
		byID[item.ID] = item
	}

	bash, ok := byID["toolu_1"]
	if !ok {
		t.Fatal("missing Bash tool item toolu_1")
	}
	if bash.Type != ItemCommandExecution || bash.Status != StatusCompleted {
		t.Errorf("Bash item = %s/%s, want command_execution/completed", bash.Type, bash.Status)
	}
	if bash.Output == nil || bash.Output.Text != "login.ts\nsession.ts" {
		t.Errorf("Bash output not folded: %+v", bash.Output)
	}
	if bash.Title != "ls -la src/auth" {
		t.Errorf("Bash title = %q", bash.Title)
	}

	edit, ok := byID["toolu_2"]
	if !ok {
		t.Fatal("missing Edit tool item toolu_2")
	}
	if edit.Type != ItemFileChange || edit.Status != StatusFailed {
		t.Errorf("Edit item = %s/%s, want file_change/failed", edit.Type, edit.Status)
	}
	if edit.Output == nil || !edit.Output.IsError || edit.Output.Text != "old_string not found" {
		t.Errorf("Edit error output not folded: %+v", edit.Output)
	}

	fetch, ok := byID["toolu_3"]
	if !ok {
		t.Fatal("missing WebFetch tool item toolu_3")
	}
	if fetch.Status != StatusInProgress {
		t.Errorf("unresolved WebFetch status = %s, want in_progress", fetch.Status)
	}
}

func TestClaudeSkipsNoise(t *testing.T) {
	conversation := parseFixture(t, ProviderClaude, filepath.Join("testdata", "claude", "basic.jsonl"))
	for _, item := range conversation.items {
		if item.ID == "side1" || item.ID == "meta1" || item.ID == "u4" {
			t.Errorf("noise line %s leaked into items", item.ID)
		}
	}
	if conversation.session.SessionID != "sess-claude-1" || conversation.session.Cwd != "/tmp/project" {
		t.Errorf("session metadata = %+v", conversation.session)
	}
	if conversation.session.Title != "Fix the login bug" {
		t.Errorf("title = %q, want first real user message", conversation.session.Title)
	}
}

func TestCodexDedupAndStripping(t *testing.T) {
	conversation := parseFixture(t, ProviderCodex, filepath.Join("testdata", "codex", "basic.jsonl"))

	var userMessages []Item
	for _, item := range conversation.items {
		if item.Type == ItemUserMessage {
			userMessages = append(userMessages, item)
		}
	}
	// event_msg duplicate and the AGENTS.md dump must not appear.
	if len(userMessages) != 1 {
		t.Fatalf("got %d user messages, want 1: %+v", len(userMessages), userMessages)
	}
	if userMessages[0].Text != "Make the tests pass" {
		t.Errorf("envelope not stripped: %q", userMessages[0].Text)
	}

	byID := map[string]Item{}
	for _, item := range conversation.items {
		byID[item.ID] = item
	}
	command := byID["call-1"]
	if command.Type != ItemCommandExecution || command.Status != StatusCompleted {
		t.Errorf("exec_command item = %s/%s", command.Type, command.Status)
	}
	if command.Output == nil || command.Output.Text != "ok  \tpkg\t0.2s" {
		t.Errorf("exec output not unwrapped: %+v", command.Output)
	}
	patch := byID["call-2"]
	if patch.Type != ItemFileChange || patch.Title != "pkg/auth.go" {
		t.Errorf("apply_patch item = %s title=%q", patch.Type, patch.Title)
	}
	if conversation.session.SessionID != "sess-codex-1" || conversation.session.Cwd != "/tmp/project" {
		t.Errorf("session metadata = %+v", conversation.session)
	}
}

func TestCodexExitCodeFailure(t *testing.T) {
	parser := newCodexParser("x.jsonl")
	parser.consumeLine([]byte(`{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"false\"}","call_id":"c"}}`))
	parser.consumeLine([]byte(`{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"{\"output\":\"boom\",\"metadata\":{\"exit_code\":1}}"}}`))
	items := parser.conv().items
	if len(items) != 1 || items[0].Status != StatusFailed || items[0].Output == nil || !items[0].Output.IsError {
		t.Fatalf("non-zero exit not marked failed: %+v", items)
	}
}

func TestEncodeClaudeProjectDir(t *testing.T) {
	cases := map[string]string{
		"/Users/lawrence/fun/cmuxterm-hq":  "-Users-lawrence-fun-cmuxterm-hq",
		"/Users/x/Library/App Support/C.P": "-Users-x-Library-App-Support-C-P",
	}
	for input, want := range cases {
		if got := EncodeClaudeProjectDir(input); got != want {
			t.Errorf("EncodeClaudeProjectDir(%q) = %q, want %q", input, got, want)
		}
	}
}
