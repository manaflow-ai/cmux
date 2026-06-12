package agentconv

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func claudeUserLine(uuid, text string) string {
	return `{"type":"user","uuid":"` + uuid + `","timestamp":"2026-06-09T10:00:00.000Z","sessionId":"sess-tail","cwd":"/tmp/project","message":{"role":"user","content":"` + text + `"}}` + "\n"
}

func awaitEvent(t *testing.T, events <-chan Event, wantType EventType) Event {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case event, ok := <-events:
			if !ok {
				t.Fatalf("event channel closed while waiting for %s", wantType)
			}
			if event.Type == wantType {
				return event
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s", wantType)
		}
	}
}

func TestSubscriptionSnapshotAndTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	if err := os.WriteFile(path, []byte(claudeUserLine("u1", "first")), 0o644); err != nil {
		t.Fatal(err)
	}

	subscription, session, err := Open(Config{
		Provider:       ProviderClaude,
		TranscriptPath: path,
		PollInterval:   2 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	if session.SessionID != "sess-tail" {
		t.Errorf("session id = %q", session.SessionID)
	}
	snapshot := awaitEvent(t, subscription.Events, EventSnapshot)
	if len(snapshot.Items) != 1 || snapshot.Items[0].Text != "first" {
		t.Fatalf("snapshot items = %+v", snapshot.Items)
	}

	// Append a line split across two writes: no event until the newline lands.
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	full := claudeUserLine("u2", "second")
	if _, err := file.WriteString(full[:20]); err != nil {
		t.Fatal(err)
	}
	select {
	case event := <-subscription.Events:
		t.Fatalf("got event for a partial line: %+v", event)
	case <-time.After(30 * time.Millisecond):
	}
	if _, err := file.WriteString(full[20:]); err != nil {
		t.Fatal(err)
	}
	file.Close()

	completed := awaitEvent(t, subscription.Events, EventItemCompleted)
	if completed.Item == nil || completed.Item.Text != "second" {
		t.Fatalf("tail item = %+v", completed.Item)
	}
	if completed.Seq <= snapshot.Seq {
		t.Errorf("seq did not advance: snapshot=%d item=%d", snapshot.Seq, completed.Seq)
	}
}

func TestSubscriptionTruncationResnapshots(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	initial := claudeUserLine("u1", "first") + claudeUserLine("u2", "second")
	if err := os.WriteFile(path, []byte(initial), 0o644); err != nil {
		t.Fatal(err)
	}

	subscription, _, err := Open(Config{
		Provider:       ProviderClaude,
		TranscriptPath: path,
		PollInterval:   2 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	first := awaitEvent(t, subscription.Events, EventSnapshot)
	if len(first.Items) != 2 {
		t.Fatalf("first snapshot has %d items", len(first.Items))
	}

	// Replace the file with a shorter transcript: the reader must detect the
	// shrink and emit a fresh snapshot.
	if err := os.WriteFile(path, []byte(claudeUserLine("u9", "rewritten")), 0o644); err != nil {
		t.Fatal(err)
	}
	second := awaitEvent(t, subscription.Events, EventSnapshot)
	if len(second.Items) != 1 || second.Items[0].Text != "rewritten" {
		t.Fatalf("re-snapshot items = %+v", second.Items)
	}
	if second.Seq <= first.Seq {
		t.Errorf("seq did not advance across snapshots")
	}
}

func TestSnapshotCapSkipsToCompleteLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	content := claudeUserLine("u1", "dropped-by-cap") + claudeUserLine("u2", "kept")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	subscription, _, err := Open(Config{
		Provider:       ProviderClaude,
		TranscriptPath: path,
		PollInterval:   time.Millisecond,
		// Cap below the full size so the replay starts mid-file.
		MaxSnapshotBytes: int64(len(content)) - 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	snapshot := awaitEvent(t, subscription.Events, EventSnapshot)
	if len(snapshot.Items) != 1 || snapshot.Items[0].Text != "kept" {
		t.Fatalf("capped snapshot items = %+v", snapshot.Items)
	}
}

func TestDiscoveryAndResolve(t *testing.T) {
	claudeDir := t.TempDir()
	codexDir := t.TempDir()
	projectDir := filepath.Join(claudeDir, "projects", EncodeClaudeProjectDir("/tmp/project"))
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	claudePath := filepath.Join(projectDir, "abc-123.jsonl")
	if err := os.WriteFile(claudePath, []byte(claudeUserLine("u1", "claude session")), 0o644); err != nil {
		t.Fatal(err)
	}
	codexDayDir := filepath.Join(codexDir, "sessions", "2026", "06", "09")
	if err := os.MkdirAll(codexDayDir, 0o755); err != nil {
		t.Fatal(err)
	}
	codexPath := filepath.Join(codexDayDir, "rollout-2026-06-09T10-00-00-cdx-1.jsonl")
	codexMeta := `{"timestamp":"t","type":"session_meta","payload":{"id":"cdx-1","cwd":"/tmp/other"}}` + "\n"
	if err := os.WriteFile(codexPath, []byte(codexMeta), 0o644); err != nil {
		t.Fatal(err)
	}

	roots := Roots{ClaudeDir: claudeDir, CodexDir: codexDir}
	all := ListSessions(roots, ListQuery{})
	if len(all) != 2 {
		t.Fatalf("ListSessions returned %d sessions: %+v", len(all), all)
	}

	claudeOnly := ListSessions(roots, ListQuery{Provider: ProviderClaude})
	if len(claudeOnly) != 1 || claudeOnly[0].SessionID != "sess-tail" {
		t.Fatalf("claude filter = %+v", claudeOnly)
	}
	if claudeOnly[0].Title != "claude session" {
		t.Errorf("claude title = %q", claudeOnly[0].Title)
	}

	byCwd := ListSessions(roots, ListQuery{Cwd: "/tmp/other"})
	if len(byCwd) != 1 || byCwd[0].Provider != ProviderCodex {
		t.Fatalf("cwd filter = %+v", byCwd)
	}

	resolved, ok := ResolveTranscriptPath(roots, ProviderClaude, "abc-123", "/tmp/project")
	if !ok || resolved != claudePath {
		t.Errorf("claude resolve = %q ok=%v", resolved, ok)
	}
	resolvedCodex, ok := ResolveTranscriptPath(roots, ProviderCodex, "cdx-1", "")
	if !ok || resolvedCodex != codexPath {
		t.Errorf("codex resolve = %q ok=%v", resolvedCodex, ok)
	}
	if _, ok := ResolveTranscriptPath(roots, ProviderClaude, "missing", ""); ok {
		t.Error("resolve of unknown session should fail")
	}
}

// Regression for the CodeRabbit finding on PR 5736: Codex writes session_meta
// as the FIRST transcript line, so a tail-only replay of a transcript over the
// snapshot cap lost the session id/cwd. The open path now recovers head
// metadata with a bounded scan when the cap skips the head.
func TestSnapshotCapKeepsCodexSessionMeta(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	meta := `{"timestamp":"t","type":"session_meta","payload":{"id":"cdx-cap","cwd":"/tmp/capped"}}` + "\n"
	body := `{"timestamp":"t","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"tail line"}]}}` + "\n"
	content := meta + body
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	subscription, session, err := Open(Config{
		Provider:       ProviderCodex,
		TranscriptPath: path,
		PollInterval:   time.Millisecond,
		// Cap below the full size so the replay starts past the meta line.
		MaxSnapshotBytes: int64(len(body)) + 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if session.SessionID != "cdx-cap" || session.Cwd != "/tmp/capped" {
		t.Fatalf("capped codex session = %+v, want id cdx-cap cwd /tmp/capped", session)
	}
	snapshot := awaitEvent(t, subscription.Events, EventSnapshot)
	if snapshot.Session == nil || snapshot.Session.SessionID != "cdx-cap" {
		t.Fatalf("capped snapshot session = %+v", snapshot.Session)
	}
	if len(snapshot.Items) != 1 || snapshot.Items[0].Text != "tail line" {
		t.Fatalf("capped snapshot items = %+v", snapshot.Items)
	}
}

// One readNewLines call must never materialize more than its budget: a large
// append drains across successive calls, with the partial-line carry joining
// lines that straddle the budget boundary.
func TestReadNewLinesBoundedByBudget(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big.jsonl")
	var content string
	for i := 0; i < 8; i++ {
		content += fmt.Sprintf(`{"line":%d,"pad":"%s"}`, i, strings.Repeat("x", 40)) + "\n"
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	reader := &transcriptReader{path: path, readBudget: 96}
	var lines [][]byte
	for i := 0; i < 64; i++ {
		batch, truncated, err := reader.readNewLines()
		if err != nil {
			t.Fatal(err)
		}
		if truncated {
			t.Fatal("unexpected truncation")
		}
		if len(batch) == 0 && reader.offset == int64(len(content)) {
			break
		}
		lines = append(lines, batch...)
	}
	if len(lines) != 8 {
		t.Fatalf("drained %d lines across budgeted reads, want 8", len(lines))
	}
	for i, line := range lines {
		if !strings.Contains(string(line), fmt.Sprintf(`"line":%d`, i)) {
			t.Fatalf("line %d out of order or corrupted: %s", i, line)
		}
	}
}

// A live subscription must not retain conversation items without bound: past
// MaxLiveItems the oldest history is dropped and the client resynchronizes
// via a fresh snapshot holding only the newest items.
func TestLiveRetentionTrimsAndResnapshots(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	if err := os.WriteFile(path, []byte(claudeUserLine("u0", "first")), 0o644); err != nil {
		t.Fatal(err)
	}
	subscription, _, err := Open(Config{
		Provider:       ProviderClaude,
		TranscriptPath: path,
		PollInterval:   time.Millisecond,
		MaxLiveItems:   8,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	awaitEvent(t, subscription.Events, EventSnapshot)

	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 12; i++ {
		if _, err := file.WriteString(claudeUserLine(fmt.Sprintf("u%d", i), fmt.Sprintf("msg %d", i))); err != nil {
			t.Fatal(err)
		}
	}
	file.Close()

	resnapshot := awaitEvent(t, subscription.Events, EventSnapshot)
	if len(resnapshot.Items) != 6 {
		t.Fatalf("retention snapshot has %d items, want 6 (3/4 of 8)", len(resnapshot.Items))
	}
	last := resnapshot.Items[len(resnapshot.Items)-1]
	if last.Text != "msg 12" {
		t.Fatalf("retention snapshot tail = %q, want the newest item", last.Text)
	}
}
