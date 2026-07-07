package agentdirs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	uuidA = "019d60bc-b684-7a01-b4ac-52feffc5fcb5"
	uuidB = "019d60bc-b685-7a02-b4ac-52feffc5fcb6"
	uuidC = "019d60bc-b686-7a03-b4ac-52feffc5fcb7"
	uuidD = "019f21d4-161e-7d25-a342-8a426f41d8a4"
)

func TestClaudeDiscover(t *testing.T) {
	root := filepath.Join(t.TempDir(), "claude-config")
	sessionPath := filepath.Join(root, "projects", "-Users-lawrence-work-cmux", uuidA+".jsonl")
	writeFile(t, sessionPath, `{"type":"message","cwd":"/Users/lawrence/work/cmux"}`+"\n")
	writeFile(t, filepath.Join(root, "projects", "-Users-lawrence-work-cmux", "not-a-session.jsonl"), "{}\n")
	writeFile(t, filepath.Join(root, "projects", "-Users-lawrence-work-cmux", uuidB+".txt"), "{}\n")
	writeFile(t, filepath.Join(root, "projects", "nested", uuidB+".jsonl"), `{"cwd":"/nested"}`+"\n")
	if err := os.Symlink(filepath.Join(root, "missing-target.jsonl"), filepath.Join(root, "projects", "nested", uuidC+".jsonl")); err != nil {
		t.Fatal(err)
	}
	unreadable := filepath.Join(root, "projects", "unreadable")
	if err := os.MkdirAll(unreadable, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(unreadable, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Chmod(unreadable, 0o700)
	})

	var warnings []string
	got, err := (Claude{}).Discover(Environ{
		HomeDir:  t.TempDir(),
		Vars:     map[string]string{"CLAUDE_CONFIG_DIR": root},
		Warnings: &warnings,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions, got %d: %#v", len(got), got)
	}
	first := findSession(t, got, uuidA)
	if first.CWD != "/Users/lawrence/work/cmux" {
		t.Fatalf("cwd = %q", first.CWD)
	}
	if first.RelPath != "projects/-Users-lawrence-work-cmux/"+uuidA+".jsonl" {
		t.Fatalf("relPath = %q", first.RelPath)
	}
	if len(warnings) == 0 {
		t.Fatal("expected skip warning")
	}
}

func TestDiscoverSymlinkedRoots(t *testing.T) {
	base := t.TempDir()
	shared := filepath.Join(base, "shared")

	claudeRoot := filepath.Join(base, "claude-config")
	claudeProjects := filepath.Join(shared, "claude-projects")
	writeFile(t, filepath.Join(claudeProjects, "-repo", uuidA+".jsonl"), `{"cwd":"/repo"}`+"\n")
	if err := os.MkdirAll(claudeRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(claudeProjects, filepath.Join(claudeRoot, "projects")); err != nil {
		t.Fatal(err)
	}
	claudeSessions, err := (Claude{}).Discover(Environ{
		HomeDir: base,
		Vars:    map[string]string{"CLAUDE_CONFIG_DIR": claudeRoot},
	})
	if err != nil {
		t.Fatal(err)
	}
	claudeSession := findSession(t, claudeSessions, uuidA)
	if claudeSession.RelPath != "projects/-repo/"+uuidA+".jsonl" {
		t.Fatalf("claude relPath = %q", claudeSession.RelPath)
	}

	codexHome := filepath.Join(base, ".codex")
	codexSessions := filepath.Join(shared, "codex-sessions")
	writeFile(t,
		filepath.Join(codexSessions, "2026", "04", "05", "rollout-2026-04-05T20-01-13-"+uuidB+".jsonl"),
		`{"type":"session_meta","payload":{"id":"`+uuidB+`","cwd":"/repo"}}`+"\n",
	)
	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(codexSessions, filepath.Join(codexHome, "sessions")); err != nil {
		t.Fatal(err)
	}
	codexFound, err := (Codex{}).Discover(Environ{HomeDir: base, Vars: map[string]string{}})
	if err != nil {
		t.Fatal(err)
	}
	codexSession := findSession(t, codexFound, uuidB)
	if codexSession.RelPath != "sessions/2026/04/05/rollout-2026-04-05T20-01-13-"+uuidB+".jsonl" {
		t.Fatalf("codex relPath = %q", codexSession.RelPath)
	}

	piHome := filepath.Join(base, "pi-home")
	piSessions := filepath.Join(shared, "pi-sessions")
	writeFile(t, filepath.Join(piSessions, "-repo", "2026-07-02T07-56-15-262Z_"+uuidD+".jsonl"), `{"cwd":"/repo"}`+"\n")
	if err := os.MkdirAll(filepath.Join(piHome, ".pi", "agent"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(piSessions, filepath.Join(piHome, ".pi", "agent", "sessions")); err != nil {
		t.Fatal(err)
	}
	piFound, err := (Pi{}).Discover(Environ{HomeDir: piHome, Vars: map[string]string{}})
	if err != nil {
		t.Fatal(err)
	}
	piSession := findSession(t, piFound, uuidD)
	if piSession.RelPath != "-repo/2026-07-02T07-56-15-262Z_"+uuidD+".jsonl" {
		t.Fatalf("pi relPath = %q", piSession.RelPath)
	}
}

func TestDiscoverRejectsSymlinkedTranscript(t *testing.T) {
	tests := []struct {
		name      string
		discover  func(Environ) ([]Session, error)
		setup     func(t *testing.T, base, targetPath string) Environ
		blockedID string
		allowedID string
	}{
		{
			name:      "claude",
			discover:  (Claude{}).Discover,
			blockedID: uuidA,
			allowedID: uuidB,
			setup: func(t *testing.T, base, targetPath string) Environ {
				root := filepath.Join(base, "claude-config")
				projectDir := filepath.Join(root, "projects", "-repo")
				if err := os.MkdirAll(projectDir, 0o700); err != nil {
					t.Fatal(err)
				}
				linkPath := filepath.Join(projectDir, uuidA+".jsonl")
				if err := os.Symlink(targetPath, linkPath); err != nil {
					t.Fatal(err)
				}
				writeFile(t, filepath.Join(projectDir, uuidB+".jsonl"), `{"cwd":"/repo/real"}`+"\n")
				return Environ{
					HomeDir: base,
					Vars:    map[string]string{"CLAUDE_CONFIG_DIR": root},
				}
			},
		},
		{
			name:      "codex",
			discover:  (Codex{}).Discover,
			blockedID: uuidA,
			allowedID: uuidB,
			setup: func(t *testing.T, base, targetPath string) Environ {
				home := filepath.Join(base, "codex-home")
				sessionDir := filepath.Join(home, ".codex", "sessions", "2026", "07", "05")
				if err := os.MkdirAll(sessionDir, 0o700); err != nil {
					t.Fatal(err)
				}
				linkPath := filepath.Join(sessionDir, "rollout-2026-07-05T00-00-00-"+uuidA+".jsonl")
				if err := os.Symlink(targetPath, linkPath); err != nil {
					t.Fatal(err)
				}
				writeFile(t,
					filepath.Join(sessionDir, "rollout-2026-07-05T00-00-01-"+uuidB+".jsonl"),
					`{"type":"session_meta","payload":{"id":"`+uuidB+`","cwd":"/repo/real"}}`+"\n",
				)
				return Environ{HomeDir: home, Vars: map[string]string{}}
			},
		},
		{
			name:      "pi",
			discover:  (Pi{}).Discover,
			blockedID: uuidA,
			allowedID: uuidB,
			setup: func(t *testing.T, base, targetPath string) Environ {
				home := filepath.Join(base, "pi-home")
				sessionDir := filepath.Join(home, ".pi", "agent", "sessions", "-repo")
				if err := os.MkdirAll(sessionDir, 0o700); err != nil {
					t.Fatal(err)
				}
				linkPath := filepath.Join(sessionDir, "2026-07-05T00-00-00_"+uuidA+".jsonl")
				if err := os.Symlink(targetPath, linkPath); err != nil {
					t.Fatal(err)
				}
				writeFile(t, filepath.Join(sessionDir, "2026-07-05T00-00-01_"+uuidB+".jsonl"), `{"cwd":"/repo/real"}`+"\n")
				return Environ{HomeDir: home, Vars: map[string]string{}}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			base := t.TempDir()
			targetPath := filepath.Join(base, "outside-transcript.jsonl")
			writeFile(t, targetPath, `{"type":"session_meta","payload":{"id":"`+tt.blockedID+`","cwd":"/secret"}}`+"\n")

			env := tt.setup(t, base, targetPath)
			var warnings []string
			env.Warnings = &warnings

			got, err := tt.discover(env)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 1 {
				t.Fatalf("expected only the regular transcript, got %d sessions: %#v", len(got), got)
			}
			if got[0].AgentSessionID != tt.allowedID {
				t.Fatalf("discovered session id = %q, want %q", got[0].AgentSessionID, tt.allowedID)
			}
			if containsSession(got, tt.blockedID) {
				t.Fatalf("symlinked transcript %s was discovered: %#v", tt.blockedID, got)
			}
			if !containsWarning(warnings, "symlinked transcript") {
				t.Fatalf("expected symlink warning, got %#v", warnings)
			}
		})
	}
}

func TestCodexDiscoverSessionsAndArchived(t *testing.T) {
	home := t.TempDir()
	root := filepath.Join(home, ".codex")
	writeFile(t,
		filepath.Join(root, "sessions", "2026", "07", "04", "rollout-2026-07-04T00-00-00-"+uuidA+".jsonl"),
		`{"type":"session_meta","payload":{"id":"`+uuidB+`","cwd":"/repo/from/meta"}}`+"\n",
	)
	writeFile(t,
		filepath.Join(root, "archived_sessions", "2026", "07", "03", "rollout-2026-07-03T00-00-00-"+uuidC+".jsonl"),
		`{"type":"other","payload":{}}`+"\n",
	)
	writeFile(t,
		filepath.Join(root, "sessions", "2026", "07", "04", "junk-"+uuidD+".jsonl"),
		"{}\n",
	)

	got, err := (Codex{}).Discover(Environ{HomeDir: home, Vars: map[string]string{}})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 sessions, got %d: %#v", len(got), got)
	}
	meta := findSession(t, got, uuidB)
	if meta.CWD != "/repo/from/meta" {
		t.Fatalf("meta cwd = %q", meta.CWD)
	}
	fallback := findSession(t, got, uuidC)
	if fallback.RelPath != "archived_sessions/2026/07/03/rollout-2026-07-03T00-00-00-"+uuidC+".jsonl" {
		t.Fatalf("fallback relPath = %q", fallback.RelPath)
	}
}

func TestPiDiscover(t *testing.T) {
	home := t.TempDir()
	sessionPath := filepath.Join(home, ".pi", "agent", "sessions", "-Users-lawrence-work-cmux", "2026-07-04T00-00-00_"+uuidD+".jsonl")
	writeFile(t, sessionPath, `{"cwd":"/Users/lawrence/work/cmux"}`+"\n")
	writeFile(t, filepath.Join(home, ".pi", "agent", "sessions", "-Users-lawrence-work-cmux", "junk.jsonl"), "{}\n")

	got, err := (Pi{}).Discover(Environ{HomeDir: home, Vars: map[string]string{}})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 session, got %d: %#v", len(got), got)
	}
	if got[0].AgentSessionID != uuidD {
		t.Fatalf("id = %q", got[0].AgentSessionID)
	}
	if got[0].CWD != "/Users/lawrence/work/cmux" {
		t.Fatalf("cwd = %q", got[0].CWD)
	}
}

func findSession(t *testing.T, sessions []Session, id string) Session {
	t.Helper()
	for _, session := range sessions {
		if session.AgentSessionID == id {
			return session
		}
	}
	t.Fatalf("session %s not found in %#v", id, sessions)
	return Session{}
}

func containsSession(sessions []Session, id string) bool {
	for _, session := range sessions {
		if session.AgentSessionID == id {
			return true
		}
	}
	return false
}

func containsWarning(warnings []string, needle string) bool {
	for _, warning := range warnings {
		if strings.Contains(warning, needle) {
			return true
		}
	}
	return false
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}
