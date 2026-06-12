package agentconv

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Session discovery scans each agent's own on-disk session store. Roots are
// parameterizable for tests; zero values resolve from the user home.

type Roots struct {
	// ClaudeDir is ~/.claude (containing projects/).
	ClaudeDir string
	// CodexDir is ~/.codex (containing sessions/).
	CodexDir string
}

func DefaultRoots() Roots {
	home, err := os.UserHomeDir()
	if err != nil {
		return Roots{}
	}
	return Roots{
		ClaudeDir: filepath.Join(home, ".claude"),
		CodexDir:  filepath.Join(home, ".codex"),
	}
}

type ListQuery struct {
	// Provider filters to one agent; empty lists all known providers.
	Provider ProviderID
	// Cwd filters to sessions whose working directory matches exactly.
	Cwd string
	// Limit caps the result count; <= 0 means the default (50).
	Limit int
}

const defaultListLimit = 50

// headScanBytes caps how much of a transcript discovery reads for metadata.
const headScanBytes = 256 * 1024

func ListSessions(roots Roots, query ListQuery) []SessionRef {
	limit := query.Limit
	if limit <= 0 {
		limit = defaultListLimit
	}
	var sessions []sessionWithTime
	if query.Provider == "" || query.Provider == ProviderClaude {
		sessions = append(sessions, listClaudeSessions(roots.ClaudeDir, query.Cwd)...)
	}
	if query.Provider == "" || query.Provider == ProviderCodex {
		sessions = append(sessions, listCodexSessions(roots.CodexDir, query.Cwd, limit)...)
	}
	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].modTime.After(sessions[j].modTime)
	})
	if len(sessions) > limit {
		sessions = sessions[:limit]
	}
	refs := make([]SessionRef, 0, len(sessions))
	for _, session := range sessions {
		refs = append(refs, session.ref)
	}
	return refs
}

type sessionWithTime struct {
	ref     SessionRef
	modTime time.Time
}

func listClaudeSessions(claudeDir, cwdFilter string) []sessionWithTime {
	if claudeDir == "" {
		return nil
	}
	projectsDir := filepath.Join(claudeDir, "projects")
	// The encoded project dir is only an optimization: Claude's encoding has
	// changed across versions (slashes, dots, and spaces all observed mapping
	// to "-"), so the parsed per-line cwd below is the ground truth and a cwd
	// filter must never silently exclude a differently-encoded dir.
	var projectDirs []string
	encodedDir := ""
	if cwdFilter != "" {
		encodedDir = filepath.Join(projectsDir, EncodeClaudeProjectDir(cwdFilter))
	}
	entries, err := os.ReadDir(projectsDir)
	if err != nil {
		return nil
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(projectsDir, entry.Name())
		if dir == encodedDir {
			continue
		}
		projectDirs = append(projectDirs, dir)
	}
	if encodedDir != "" {
		projectDirs = append([]string{encodedDir}, projectDirs...)
	}
	var sessions []sessionWithTime
	for _, dir := range projectDirs {
		paths, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
		if err != nil {
			continue
		}
		for _, path := range paths {
			info, err := os.Stat(path)
			if err != nil {
				continue
			}
			ref := scanTranscriptHead(ProviderClaude, path)
			if ref.SessionID == "" {
				ref.SessionID = strings.TrimSuffix(filepath.Base(path), ".jsonl")
			}
			// Filter on the parsed cwd; a transcript with no parseable cwd only
			// matches through the encoded-dir fast path.
			if cwdFilter != "" && ref.Cwd != cwdFilter && !(ref.Cwd == "" && filepath.Dir(path) == encodedDir) {
				continue
			}
			ref.UpdatedAt = info.ModTime().UTC().Format(time.RFC3339)
			sessions = append(sessions, sessionWithTime{ref: ref, modTime: info.ModTime()})
		}
	}
	return sessions
}

// listCodexSessions prefers the sqlite session index (~/.codex/state_5.sqlite,
// see discover_codex_index.go) and falls back to globbing the sessions tree
// when the index is missing, unreadable, or empty.
func listCodexSessions(codexDir, cwdFilter string, limit int) []sessionWithTime {
	if sessions, ok := listCodexSessionsFromIndex(codexDir, cwdFilter, limit); ok {
		return sessions
	}
	return listCodexSessionsFromGlob(codexDir, cwdFilter)
}

func listCodexSessionsFromGlob(codexDir, cwdFilter string) []sessionWithTime {
	if codexDir == "" {
		return nil
	}
	paths, err := filepath.Glob(filepath.Join(codexDir, "sessions", "*", "*", "*", "rollout-*.jsonl"))
	if err != nil {
		return nil
	}
	var sessions []sessionWithTime
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		ref := scanTranscriptHead(ProviderCodex, path)
		if ref.SessionID == "" {
			ref.SessionID = codexSessionIDFromFilename(path)
		}
		if cwdFilter != "" && ref.Cwd != cwdFilter {
			continue
		}
		ref.UpdatedAt = info.ModTime().UTC().Format(time.RFC3339)
		sessions = append(sessions, sessionWithTime{ref: ref, modTime: info.ModTime()})
	}
	return sessions
}

// scanTranscriptHead parses the first chunk of a transcript with the real
// parser to recover session id, cwd, and title cheaply.
func scanTranscriptHead(provider ProviderID, path string) SessionRef {
	parser := newTranscriptParser(provider, path)
	file, err := os.Open(path)
	if err != nil {
		return parser.conv().session
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), maxTranscriptLineBytes)
	read := 0
	for scanner.Scan() {
		line := scanner.Bytes()
		read += len(line)
		parser.consumeLine(line)
		state := parser.conv().session
		if state.SessionID != "" && state.Cwd != "" && state.Title != "" {
			break
		}
		if read > headScanBytes {
			break
		}
	}
	return parser.conv().session
}

// EncodeClaudeProjectDir maps a working directory to Claude Code's project
// directory name (every non-alphanumeric character becomes '-').
func EncodeClaudeProjectDir(cwd string) string {
	var builder strings.Builder
	builder.Grow(len(cwd))
	for _, r := range cwd {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			builder.WriteRune(r)
		} else {
			builder.WriteByte('-')
		}
	}
	return builder.String()
}

func codexSessionIDFromFilename(path string) string {
	stem := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	stem = strings.TrimPrefix(stem, "rollout-")
	// rollout-2026-06-08T18-53-17-<uuid>: the id is everything after the
	// timestamp's seconds segment.
	parts := strings.SplitN(stem, "-", 7)
	if len(parts) == 7 {
		return parts[6]
	}
	return stem
}

// ResolveTranscriptPath finds the transcript file for (provider, session id),
// optionally narrowed by cwd.
func ResolveTranscriptPath(roots Roots, provider ProviderID, sessionID, cwd string) (string, bool) {
	switch provider {
	case ProviderClaude:
		projectsDir := filepath.Join(roots.ClaudeDir, "projects")
		if cwd != "" {
			candidate := filepath.Join(projectsDir, EncodeClaudeProjectDir(cwd), sessionID+".jsonl")
			if _, err := os.Stat(candidate); err == nil {
				return candidate, true
			}
		}
		matches, _ := filepath.Glob(filepath.Join(projectsDir, "*", sessionID+".jsonl"))
		if len(matches) > 0 {
			return matches[0], true
		}
	case ProviderCodex:
		return resolveCodexTranscript(roots.CodexDir, sessionID, cwd)
	}
	return "", false
}
