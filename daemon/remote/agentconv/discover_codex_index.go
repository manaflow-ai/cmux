package agentconv

// Codex maintains a sqlite session index at ~/.codex/state_5.sqlite. The
// `threads` table maps session id → rollout transcript path and carries the
// metadata discovery otherwise recovers by scanning transcript heads:
//
//	threads(id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER,
//	        updated_at INTEGER, source TEXT, model_provider TEXT, cwd TEXT,
//	        title TEXT, ...)
//
// Discovery prefers this index (one indexed query instead of globbing and
// head-scanning every rollout file) and falls back to the sessions/ glob when
// the db is missing, unreadable, locked, or empty (older Codex versions, or a
// backfill that has not run yet). The db is only ever opened read-only
// (mode=ro, bounded busy_timeout) so a live Codex writing it is never blocked
// and the file is never mutated. mode=ro is deliberate over immutable=1:
// immutable would skip the WAL and miss the most recent sessions, which are
// exactly the ones a session list is for.

import (
	"database/sql"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const codexStateDBFile = "state_5.sqlite"

// codexIndexDSN builds a read-only sqlite URI for the index db. Paths go
// through URL escaping so spaces (DerivedData-style paths) survive the
// sqlite URI parser.
func codexIndexDSN(path string) string {
	uri := url.URL{
		Scheme:   "file",
		OmitHost: true,
		Path:     path,
		RawQuery: "mode=ro&_pragma=busy_timeout(200)",
	}
	return uri.String()
}

// openCodexIndex opens the session index read-only. Any failure (no file, no
// permission, not a database) is reported to the caller for glob fallback.
func openCodexIndex(codexDir string) (*sql.DB, error) {
	path := filepath.Join(codexDir, codexStateDBFile)
	if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", codexIndexDSN(path))
	if err != nil {
		return nil, err
	}
	return db, nil
}

// listCodexSessionsFromIndex serves session listing from the sqlite index.
// ok=false means the index gave no usable answer and the caller must fall
// back to the glob scan.
func listCodexSessionsFromIndex(codexDir, cwdFilter string, limit int) ([]sessionWithTime, bool) {
	if codexDir == "" || limit <= 0 {
		return nil, false
	}
	db, err := openCodexIndex(codexDir)
	if err != nil {
		return nil, false
	}
	defer db.Close()

	query := "SELECT id, rollout_path, cwd, title FROM threads"
	var args []any
	if cwdFilter != "" {
		query += " WHERE cwd = ?"
		args = append(args, cwdFilter)
	}
	query += " ORDER BY updated_at DESC, id DESC"
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, false
	}
	defer rows.Close()

	var sessions []sessionWithTime
	sawRow := false
	for len(sessions) < limit && rows.Next() {
		var id, rolloutPath, cwd, title string
		if err := rows.Scan(&id, &rolloutPath, &cwd, &title); err != nil {
			return nil, false
		}
		sawRow = true
		// Index rows can outlive their transcript (manual cleanup); a session
		// whose rollout file is gone cannot be opened, so it is not listed.
		info, err := os.Stat(rolloutPath)
		if err != nil {
			continue
		}
		if title == "" {
			// Parity with the glob path, which derives the title from the
			// first user message in the transcript head.
			title = scanTranscriptHead(ProviderCodex, rolloutPath).Title
		}
		sessions = append(sessions, sessionWithTime{
			ref: SessionRef{
				Provider:       ProviderCodex,
				SessionID:      id,
				TranscriptPath: rolloutPath,
				Cwd:            cwd,
				Title:          title,
				UpdatedAt:      info.ModTime().UTC().Format(time.RFC3339),
			},
			modTime: info.ModTime(),
		})
	}
	if err := rows.Err(); err != nil {
		return nil, false
	}
	if !sawRow {
		// Empty result: either there truly are no sessions or the index has
		// not been backfilled; the glob scan is ground truth for both.
		return nil, false
	}
	return sessions, true
}

// resolveCodexTranscript maps session id → rollout path, preferring the
// sqlite index (id is the primary key, so the lookup is exact and the cwd
// hint is unnecessary) and falling back to the sessions/ glob.
func resolveCodexTranscript(codexDir, sessionID, cwd string) (string, bool) {
	if path, ok := resolveCodexTranscriptFromIndex(codexDir, sessionID); ok {
		return path, true
	}
	return resolveCodexTranscriptFromGlob(codexDir, sessionID, cwd)
}

func resolveCodexTranscriptFromIndex(codexDir, sessionID string) (string, bool) {
	if codexDir == "" || sessionID == "" {
		return "", false
	}
	db, err := openCodexIndex(codexDir)
	if err != nil {
		return "", false
	}
	defer db.Close()
	var rolloutPath string
	if err := db.QueryRow("SELECT rollout_path FROM threads WHERE id = ?", sessionID).Scan(&rolloutPath); err != nil {
		return "", false
	}
	if _, err := os.Stat(rolloutPath); err != nil {
		return "", false
	}
	return rolloutPath, true
}

func resolveCodexTranscriptFromGlob(codexDir, sessionID, cwd string) (string, bool) {
	if codexDir == "" || sessionID == "" {
		return "", false
	}
	matches, _ := filepath.Glob(filepath.Join(codexDir, "sessions", "*", "*", "*", "rollout-*"+sessionID+".jsonl"))
	if len(matches) == 0 {
		return "", false
	}
	// The glob is a suffix match, so a short session id can overmatch. Honor
	// the cwd narrowing hint: newest match whose parsed cwd agrees wins;
	// without agreement the newest match stands (a stale cwd hint must not
	// hide an unambiguous session).
	if cwd != "" && len(matches) > 1 {
		for index := len(matches) - 1; index >= 0; index-- {
			if scanTranscriptHead(ProviderCodex, matches[index]).Cwd == cwd {
				return matches[index], true
			}
		}
	}
	return matches[len(matches)-1], true
}
