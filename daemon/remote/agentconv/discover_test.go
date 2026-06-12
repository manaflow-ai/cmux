package agentconv

import (
	"os"
	"path/filepath"
	"testing"
)

// Claude Code derives a project directory name by replacing every
// non-alphanumeric character with '-' (verified empirically: a session
// launched in /private/tmp/cmux_enc_probe.test_dir lands in
// projects/-private-tmp-cmux-enc-probe-test-dir). These fixtures pin the
// encoded-dir fast paths in ListSessions and ResolveTranscriptPath to that
// rule for cwds containing underscores, dots, and spaces.

// writeClaudeEncodedCwdFixture lays out a transcript under the project dir
// Claude actually writes for cwd, returning the transcript path. The
// transcript body has no parseable cwd line, so a cwd-filtered list can only
// match it through the encoded-dir fast path.
func writeClaudeEncodedCwdFixture(t *testing.T, claudeDir, cwd, sessionID string) string {
	t.Helper()
	projectDir := filepath.Join(claudeDir, "projects", EncodeClaudeProjectDir(cwd))
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatalf("mkdir project dir: %v", err)
	}
	transcript := filepath.Join(projectDir, sessionID+".jsonl")
	line := `{"type":"user","uuid":"u1","sessionId":"` + sessionID + `","message":{"role":"user","content":"hello"}}` + "\n"
	if err := os.WriteFile(transcript, []byte(line), 0o644); err != nil {
		t.Fatalf("write transcript: %v", err)
	}
	return transcript
}

func TestListClaudeSessionsEncodedCwdFastPath(t *testing.T) {
	claudeDir := t.TempDir()
	cwd := "/tmp/my_repo.dir/sub dir"
	const sessionID = "11111111-2222-3333-4444-555555555555"
	writeClaudeEncodedCwdFixture(t, claudeDir, cwd, sessionID)

	// Sanity-check the fixture landed where Claude would write it.
	wantDir := filepath.Join(claudeDir, "projects", "-tmp-my-repo-dir-sub-dir")
	if _, err := os.Stat(wantDir); err != nil {
		t.Fatalf("fixture project dir %s missing: %v", wantDir, err)
	}

	refs := ListSessions(Roots{ClaudeDir: claudeDir}, ListQuery{Provider: ProviderClaude, Cwd: cwd})
	if len(refs) != 1 {
		t.Fatalf("cwd-filtered list = %d sessions, want 1 (encoded-dir fast path missed)", len(refs))
	}
	if refs[0].SessionID != sessionID {
		t.Errorf("session id = %q, want %q", refs[0].SessionID, sessionID)
	}
}

func TestResolveTranscriptPathEncodedCwd(t *testing.T) {
	claudeDir := t.TempDir()
	cwd := "/tmp/my_repo.dir"
	const sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	transcript := writeClaudeEncodedCwdFixture(t, claudeDir, cwd, sessionID)

	path, ok := ResolveTranscriptPath(Roots{ClaudeDir: claudeDir}, ProviderClaude, sessionID, cwd)
	if !ok {
		t.Fatal("ResolveTranscriptPath missed the encoded-cwd transcript")
	}
	if path != transcript {
		t.Errorf("path = %q, want %q", path, transcript)
	}
}
