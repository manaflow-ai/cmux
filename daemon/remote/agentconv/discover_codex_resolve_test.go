package agentconv

import (
	"os"
	"path/filepath"
	"testing"
)

// writeCodexRolloutFile drops a minimal real-shaped rollout transcript into
// the sessions/YYYY/MM/DD tree and returns its path.
func writeCodexRolloutFile(t *testing.T, codexDir, day, stamp, sessionID, cwd, firstMessage string) string {
	t.Helper()
	dir := filepath.Join(codexDir, "sessions", day[:4], day[5:7], day[8:10])
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "rollout-"+stamp+"-"+sessionID+".jsonl")
	content := `{"timestamp":"` + day + `T10:00:00.000Z","type":"session_meta","payload":{"id":"` + sessionID + `","cwd":"` + cwd + `"}}` + "\n" +
		`{"timestamp":"` + day + `T10:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"` + firstMessage + `"}]}}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// Regression test for the CodeRabbit finding on PR 5736: the Codex branch of
// ResolveTranscriptPath advertised optional cwd narrowing but ignored it. The
// rollout glob is a suffix match on the session id, so a short id can match
// several files; the cwd hint must pick the right one.
func TestCodexResolveHonorsCwdNarrowing(t *testing.T) {
	codexDir := t.TempDir()
	wanted := writeCodexRolloutFile(t, codexDir, "2026-06-01", "2026-06-01T10-00-00", "abc", "/tmp/project-a", "session in a")
	// Later file whose id ("xyzabc") overmatches the glob for id "abc".
	overmatch := writeCodexRolloutFile(t, codexDir, "2026-06-02", "2026-06-02T10-00-00", "xyzabc", "/tmp/project-b", "session in b")

	roots := Roots{CodexDir: codexDir}
	resolved, ok := ResolveTranscriptPath(roots, ProviderCodex, "abc", "/tmp/project-a")
	if !ok {
		t.Fatal("session abc not resolved")
	}
	if resolved != wanted {
		t.Errorf("cwd narrowing ignored: resolved %s, want %s", resolved, wanted)
	}

	// Without a cwd hint the newest match still wins (existing behavior).
	resolved, ok = ResolveTranscriptPath(roots, ProviderCodex, "abc", "")
	if !ok || resolved != overmatch {
		t.Errorf("no-cwd resolve = %s ok=%v, want newest match %s", resolved, ok, overmatch)
	}

	// A stale cwd hint must not hide an unambiguous session.
	resolved, ok = ResolveTranscriptPath(roots, ProviderCodex, "xyzabc", "/tmp/somewhere-else")
	if !ok || resolved != overmatch {
		t.Errorf("stale-cwd resolve = %s ok=%v, want %s", resolved, ok, overmatch)
	}
}
