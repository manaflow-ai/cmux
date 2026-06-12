package agentconv

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Fixture index dbs are built with the same driver the reader uses, against
// the real ~/.codex/state_5.sqlite schema (the columns discovery touches plus
// the NOT NULL companions, observed on Codex 2026-06).

type codexThreadRow struct {
	id          string
	rolloutPath string
	cwd         string
	title       string
	updatedAt   int64
	archived    bool
}

func buildCodexIndexFixture(t *testing.T, codexDir string, rows []codexThreadRow) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(codexDir, codexStateDBFile))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE threads (
		id TEXT PRIMARY KEY,
		rollout_path TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL,
		source TEXT NOT NULL,
		model_provider TEXT NOT NULL,
		cwd TEXT NOT NULL,
		title TEXT NOT NULL,
		sandbox_policy TEXT NOT NULL,
		approval_mode TEXT NOT NULL,
		tokens_used INTEGER NOT NULL DEFAULT 0,
		has_user_event INTEGER NOT NULL DEFAULT 0,
		archived INTEGER NOT NULL DEFAULT 0
	)`); err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		archived := 0
		if row.archived {
			archived = 1
		}
		if _, err := db.Exec(
			`INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, archived)
			 VALUES (?, ?, ?, ?, 'cli', 'openai', ?, ?, 'workspace-write', 'on-request', ?)`,
			row.id, row.rolloutPath, row.updatedAt, row.updatedAt, row.cwd, row.title, archived,
		); err != nil {
			t.Fatal(err)
		}
	}
}

// writeCodexArchivedRolloutFile mirrors writeCodexRolloutFile but places the
// transcript under archived_sessions/, where Codex moves archived threads
// (outside the sessions/ glob).
func writeCodexArchivedRolloutFile(t *testing.T, codexDir, stamp, sessionID, cwd, firstMessage string) string {
	t.Helper()
	dir := filepath.Join(codexDir, "archived_sessions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "rollout-"+stamp+"-"+sessionID+".jsonl")
	content := `{"timestamp":"2026-06-01T10:00:00.000Z","type":"session_meta","payload":{"id":"` + sessionID + `","cwd":"` + cwd + `"}}` + "\n" +
		`{"timestamp":"2026-06-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"` + firstMessage + `"}]}}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func codexSessionIDs(refs []SessionRef) []string {
	ids := make([]string, 0, len(refs))
	for _, ref := range refs {
		ids = append(ids, ref.SessionID)
	}
	return ids
}

func TestCodexIndexServesListing(t *testing.T) {
	codexDir := t.TempDir()
	pathA := writeCodexRolloutFile(t, codexDir, "2026-06-01", "2026-06-01T10-00-00", "sess-a", "/tmp/project-a", "work in a")
	pathB := writeCodexRolloutFile(t, codexDir, "2026-06-02", "2026-06-02T10-00-00", "sess-b", "/tmp/project-b", "work in b")
	// On disk but not in the index: an index-served listing must not contain
	// it (this is what proves the glob was not used).
	writeCodexRolloutFile(t, codexDir, "2026-06-03", "2026-06-03T10-00-00", "sess-unindexed", "/tmp/project-a", "not indexed")
	// File mtimes drive the cross-provider sort; pin them.
	if err := os.Chtimes(pathA, time.Unix(1000, 0), time.Unix(1000, 0)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(pathB, time.Unix(2000, 0), time.Unix(2000, 0)); err != nil {
		t.Fatal(err)
	}
	// Archived threads keep a readable transcript (Codex moves it under
	// archived_sessions/) but must not show up in the active listing.
	archivedPath := writeCodexArchivedRolloutFile(t, codexDir, "2026-06-04T10-00-00", "sess-archived", "/tmp/project-a", "archived work")
	buildCodexIndexFixture(t, codexDir, []codexThreadRow{
		{id: "sess-a", rolloutPath: pathA, cwd: "/tmp/project-a", title: "work in a", updatedAt: 100},
		{id: "sess-b", rolloutPath: pathB, cwd: "/tmp/project-b", title: "", updatedAt: 200},
		{id: "sess-gone", rolloutPath: filepath.Join(codexDir, "sessions", "2026", "06", "01", "rollout-x-gone.jsonl"), cwd: "/tmp/project-a", title: "deleted transcript", updatedAt: 300},
		{id: "sess-archived", rolloutPath: archivedPath, cwd: "/tmp/project-a", title: "archived work", updatedAt: 400, archived: true},
	})

	roots := Roots{CodexDir: codexDir}
	all := ListSessions(roots, ListQuery{Provider: ProviderCodex})
	got := codexSessionIDs(all)
	// Exactly the active indexed sessions whose transcript exists, newest
	// first: sess-unindexed (on disk, not indexed) proves the glob was not
	// used, sess-gone (indexed, transcript deleted) must be skipped, and
	// sess-archived (archived=1, transcript alive) must be filtered like the
	// sessions/-only glob always did.
	if len(got) != 2 || got[0] != "sess-b" || got[1] != "sess-a" {
		t.Fatalf("index listing = %v, want [sess-b sess-a]", got)
	}
	if ref := all[1]; ref.Title != "work in a" || ref.Cwd != "/tmp/project-a" || ref.TranscriptPath != pathA {
		t.Errorf("sess-a ref = %+v", ref)
	}
	// Empty title in the index falls back to the transcript head.
	if ref := all[0]; ref.Title != "work in b" || ref.UpdatedAt == "" {
		t.Errorf("sess-b ref = %+v, want transcript-head title and updated_at", ref)
	}

	narrowed := ListSessions(roots, ListQuery{Provider: ProviderCodex, Cwd: "/tmp/project-a"})
	if ids := codexSessionIDs(narrowed); len(ids) != 1 || ids[0] != "sess-a" {
		t.Errorf("cwd-narrowed listing = %v, want [sess-a]", ids)
	}

	limited := ListSessions(roots, ListQuery{Provider: ProviderCodex, Limit: 1})
	if len(limited) != 1 {
		t.Errorf("limited listing returned %d sessions, want 1", len(limited))
	}
}

func TestCodexIndexFallsBackToGlob(t *testing.T) {
	cases := map[string]func(t *testing.T, codexDir string){
		"no-index": func(t *testing.T, codexDir string) {},
		"corrupt-index": func(t *testing.T, codexDir string) {
			if err := os.WriteFile(filepath.Join(codexDir, codexStateDBFile), []byte("not a sqlite db"), 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"empty-index": func(t *testing.T, codexDir string) {
			buildCodexIndexFixture(t, codexDir, nil)
		},
		"wrong-schema": func(t *testing.T, codexDir string) {
			db, err := sql.Open("sqlite", filepath.Join(codexDir, codexStateDBFile))
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			if _, err := db.Exec(`CREATE TABLE threads (id TEXT PRIMARY KEY)`); err != nil {
				t.Fatal(err)
			}
		},
		// Rows exist but every rollout_path is gone (stale or partially
		// repaired db): an unusable index must not hide on-disk sessions.
		"stale-index": func(t *testing.T, codexDir string) {
			buildCodexIndexFixture(t, codexDir, []codexThreadRow{
				{id: "sess-stale", rolloutPath: filepath.Join(codexDir, "missing.jsonl"), cwd: "/tmp/project", title: "stale", updatedAt: 100},
			})
		},
	}
	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			codexDir := t.TempDir()
			writeCodexRolloutFile(t, codexDir, "2026-06-01", "2026-06-01T10-00-00", "sess-glob", "/tmp/project", "hello from glob")
			corrupt(t, codexDir)
			roots := Roots{CodexDir: codexDir}
			sessions := ListSessions(roots, ListQuery{Provider: ProviderCodex})
			if ids := codexSessionIDs(sessions); len(ids) != 1 || ids[0] != "sess-glob" {
				t.Errorf("glob fallback listing = %v, want [sess-glob]", ids)
			}
			resolved, ok := ResolveTranscriptPath(roots, ProviderCodex, "sess-glob", "/tmp/project")
			if !ok || filepath.Base(resolved) != "rollout-2026-06-01T10-00-00-sess-glob.jsonl" {
				t.Errorf("glob fallback resolve = %q ok=%v", resolved, ok)
			}
		})
	}
}

func TestCodexIndexResolve(t *testing.T) {
	codexDir := t.TempDir()
	pathA := writeCodexRolloutFile(t, codexDir, "2026-06-01", "2026-06-01T10-00-00", "sess-a", "/tmp/project-a", "work in a")
	buildCodexIndexFixture(t, codexDir, []codexThreadRow{
		{id: "sess-a", rolloutPath: pathA, cwd: "/tmp/project-a", title: "work in a", updatedAt: 100},
		{id: "sess-gone", rolloutPath: filepath.Join(codexDir, "missing.jsonl"), cwd: "/tmp/project-a", title: "gone", updatedAt: 200},
	})
	roots := Roots{CodexDir: codexDir}

	resolved, ok := ResolveTranscriptPath(roots, ProviderCodex, "sess-a", "")
	if !ok || resolved != pathA {
		t.Errorf("index resolve = %q ok=%v, want %s", resolved, ok, pathA)
	}
	// The id-keyed row is exact; a different cwd hint must not reject it.
	resolved, ok = ResolveTranscriptPath(roots, ProviderCodex, "sess-a", "/tmp/elsewhere")
	if !ok || resolved != pathA {
		t.Errorf("index resolve with stale cwd = %q ok=%v, want %s", resolved, ok, pathA)
	}
	// Index row whose transcript is gone falls through to the glob (which
	// also finds nothing here).
	if _, ok := ResolveTranscriptPath(roots, ProviderCodex, "sess-gone", ""); ok {
		t.Error("resolved a session whose transcript no longer exists")
	}
	if _, ok := ResolveTranscriptPath(roots, ProviderCodex, "sess-unknown", ""); ok {
		t.Error("resolved an unknown session id")
	}
}

// Resolution by explicit id deliberately serves archived threads: the
// transcript still exists under archived_sessions/ and a read-only viewer
// pointed at it beats "not found". Only the listing filters archived.
func TestCodexIndexResolvesArchivedThread(t *testing.T) {
	codexDir := t.TempDir()
	archivedPath := writeCodexArchivedRolloutFile(t, codexDir, "2026-06-01T10-00-00", "sess-archived", "/tmp/project", "archived work")
	buildCodexIndexFixture(t, codexDir, []codexThreadRow{
		{id: "sess-archived", rolloutPath: archivedPath, cwd: "/tmp/project", title: "archived work", updatedAt: 100, archived: true},
	})
	roots := Roots{CodexDir: codexDir}
	if ids := codexSessionIDs(ListSessions(roots, ListQuery{Provider: ProviderCodex})); len(ids) != 0 {
		t.Errorf("archived thread leaked into listing: %v", ids)
	}
	resolved, ok := ResolveTranscriptPath(roots, ProviderCodex, "sess-archived", "")
	if !ok || resolved != archivedPath {
		t.Errorf("archived resolve = %q ok=%v, want %s", resolved, ok, archivedPath)
	}
}

func TestCodexIndexDSNHandlesSpacesInPath(t *testing.T) {
	base := t.TempDir()
	codexDir := filepath.Join(base, "dir with spaces")
	if err := os.MkdirAll(codexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeCodexRolloutFile(t, codexDir, "2026-06-01", "2026-06-01T10-00-00", "sess-sp", "/tmp/project", "spaced out")
	buildCodexIndexFixture(t, codexDir, []codexThreadRow{
		{id: "sess-sp", rolloutPath: path, cwd: "/tmp/project", title: "spaced out", updatedAt: 100},
	})
	sessions, ok := listCodexSessionsFromIndex(codexDir, "", 10)
	if !ok || len(sessions) != 1 || sessions[0].ref.SessionID != "sess-sp" {
		t.Fatalf("index under spaced path: ok=%v sessions=%+v", ok, sessions)
	}
}
