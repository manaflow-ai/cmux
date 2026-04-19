package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// envSnapshot captures the current values of the named env vars and returns
// a cleanup that restores them. Use `t.Cleanup(envSnapshot(t, ...))` so each
// test's mutations don't leak into siblings.
func envSnapshot(t *testing.T, keys ...string) func() {
	t.Helper()
	saved := make(map[string]struct {
		val string
		ok  bool
	}, len(keys))
	for _, k := range keys {
		v, ok := os.LookupEnv(k)
		saved[k] = struct {
			val string
			ok  bool
		}{v, ok}
	}
	return func() {
		for k, s := range saved {
			if s.ok {
				_ = os.Setenv(k, s.val)
			} else {
				_ = os.Unsetenv(k)
			}
		}
	}
}

// claudeTeamsConfig returns an agentConfig matching the real claude-teams
// relay (see runClaudeTeamsRelay).
func claudeTeamsConfig() agentConfig {
	return agentConfig{
		shimDir:             "/tmp/test-claude-teams-shim",
		socketPath:          "127.0.0.1:54321",
		focused:             nil,
		tmuxPathPrefix:      "cmux-claude-teams",
		cmuxBinEnvVar:       "CMUX_CLAUDE_TEAMS_CMUX_BIN",
		termEnvVar:          "CMUX_CLAUDE_TEAMS_TERM",
		preserveTermProgram: true,
		extraEnv: map[string]string{
			"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
		},
	}
}

// opencodeFamilyConfig returns an agentConfig matching the real omo/omx/omc
// relays — the preserveTermProgram flag is left at the zero value (false),
// which yields the legacy "unset TERM_PROGRAM" behavior. opencode-family
// agents react to any non-empty TERM_PROGRAM by switching to a light theme
// (regression #2516), so the unset is required.
func opencodeFamilyConfig() agentConfig {
	return agentConfig{
		shimDir:        "/tmp/test-omo-shim",
		socketPath:     "127.0.0.1:54321",
		focused:        nil,
		tmuxPathPrefix: "cmux-omo",
		cmuxBinEnvVar:  "CMUX_OMO_CMUX_BIN",
		termEnvVar:     "CMUX_OMO_TERM",
		extraEnv:       map[string]string{},
	}
}

// TestConfigureAgentEnvironment_PreservesTermProgramWhenFlagSet exercises the
// claude-teams contract: TERM_PROGRAM must survive configureAgentEnvironment
// because Claude Code v2.1.112+ crashes during permission escalation when
// the variable is missing (issue #2947).
func TestConfigureAgentEnvironment_PreservesTermProgramWhenFlagSet(t *testing.T) {
	t.Cleanup(envSnapshot(t,
		"TERM_PROGRAM", "TERM", "COLORTERM", "PATH", "TMUX", "TMUX_PANE",
		"CMUX_CLAUDE_TEAMS_CMUX_BIN", "CMUX_SOCKET_PATH", "CMUX_SOCKET",
		"CMUX_CLAUDE_TEAMS_TERM", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
	))

	if err := os.Setenv("TERM_PROGRAM", "ghostty"); err != nil {
		t.Fatalf("setenv TERM_PROGRAM: %v", err)
	}

	configureAgentEnvironment(claudeTeamsConfig())

	got, ok := os.LookupEnv("TERM_PROGRAM")
	if !ok {
		t.Fatal("TERM_PROGRAM was unset; claude-teams must preserve it (#2947)")
	}
	if got != "ghostty" {
		t.Errorf("TERM_PROGRAM = %q, want %q (preserved unmodified)", got, "ghostty")
	}
}

// TestConfigureAgentEnvironment_OpencodeFamilyUnsetsTermProgram exercises the
// opencode-family contract: TERM_PROGRAM must NOT leak through, otherwise
// opencode flips to a light theme (regression #2516).
func TestConfigureAgentEnvironment_OpencodeFamilyUnsetsTermProgram(t *testing.T) {
	t.Cleanup(envSnapshot(t,
		"TERM_PROGRAM", "TERM", "COLORTERM", "PATH", "TMUX", "TMUX_PANE",
		"CMUX_OMO_CMUX_BIN", "CMUX_SOCKET_PATH", "CMUX_SOCKET",
		"CMUX_OMO_TERM",
	))

	if err := os.Setenv("TERM_PROGRAM", "ghostty"); err != nil {
		t.Fatalf("setenv TERM_PROGRAM: %v", err)
	}

	configureAgentEnvironment(opencodeFamilyConfig())

	if v, ok := os.LookupEnv("TERM_PROGRAM"); ok {
		t.Errorf("TERM_PROGRAM = %q, should be unset (prevents #2516 light-theme regression)", v)
	}
}

// TestConfigureAgentEnvironment_TermEnvVarOverride asserts that the
// agent-specific override env var (e.g. CMUX_CLAUDE_TEAMS_TERM) wins over
// the built-in default.
func TestConfigureAgentEnvironment_TermEnvVarOverride(t *testing.T) {
	t.Cleanup(envSnapshot(t,
		"TERM", "CMUX_CLAUDE_TEAMS_TERM", "COLORTERM", "PATH", "TMUX",
		"TMUX_PANE", "CMUX_CLAUDE_TEAMS_CMUX_BIN", "CMUX_SOCKET_PATH",
		"CMUX_SOCKET", "TERM_PROGRAM",
	))

	if err := os.Setenv("CMUX_CLAUDE_TEAMS_TERM", "screen-256color"); err != nil {
		t.Fatalf("setenv CMUX_CLAUDE_TEAMS_TERM: %v", err)
	}

	configureAgentEnvironment(claudeTeamsConfig())

	if got := os.Getenv("TERM"); got != "screen-256color" {
		t.Errorf("TERM = %q, want %q (override should win over default)", got, "screen-256color")
	}
}

// TestConfigureAgentEnvironment_COLORTERMPreservedWhenSet asserts the
// truecolor fallback only runs when COLORTERM is empty — we should never
// downgrade an explicitly-set value.
func TestConfigureAgentEnvironment_COLORTERMPreservedWhenSet(t *testing.T) {
	t.Cleanup(envSnapshot(t,
		"COLORTERM", "TERM", "PATH", "TMUX", "TMUX_PANE",
		"CMUX_CLAUDE_TEAMS_CMUX_BIN", "CMUX_SOCKET_PATH", "CMUX_SOCKET",
		"CMUX_CLAUDE_TEAMS_TERM", "TERM_PROGRAM",
	))

	if err := os.Setenv("COLORTERM", "256color"); err != nil {
		t.Fatalf("setenv COLORTERM: %v", err)
	}

	configureAgentEnvironment(claudeTeamsConfig())

	if got := os.Getenv("COLORTERM"); got != "256color" {
		t.Errorf("COLORTERM = %q, want %q (must not overwrite caller-provided value)", got, "256color")
	}
}

// TestConfigureAgentEnvironment_AppliesExtraEnv asserts the extraEnv map is
// applied LAST (after all other env mutations) so callers can override
// anything the function sets — including, in principle, TERM_PROGRAM itself
// for opt-in test/debug scenarios.
func TestConfigureAgentEnvironment_AppliesExtraEnv(t *testing.T) {
	t.Cleanup(envSnapshot(t,
		"COLORTERM", "TERM", "PATH", "TMUX", "TMUX_PANE",
		"CMUX_CLAUDE_TEAMS_CMUX_BIN", "CMUX_SOCKET_PATH", "CMUX_SOCKET",
		"CMUX_CLAUDE_TEAMS_TERM", "TERM_PROGRAM",
		"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
	))

	configureAgentEnvironment(claudeTeamsConfig())

	if got := os.Getenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"); got != "1" {
		t.Errorf("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = %q, want 1", got)
	}
}

// hasInfocmp reports whether the test host has the `infocmp` binary
// available — needed to guard tests that depend on it being present.
func hasInfocmp() bool {
	for _, dir := range strings.Split(os.Getenv("PATH"), string(os.PathListSeparator)) {
		if dir == "" {
			continue
		}
		if info, err := os.Stat(dir + "/infocmp"); err == nil && !info.IsDir() {
			return true
		}
	}
	return false
}

// TestResolveDefaultTerm_FallsBackWhenInfocmpAbsent simulates the case where
// the xterm-ghostty terminfo entry isn't installed (or `infocmp` itself is
// missing). The fallback to xterm-256color avoids ncurses errors on fresh
// remote SSH hosts where cmux's terminfo overlay installs asynchronously
// during shell bootstrap.
func TestResolveDefaultTerm_FallsBackWhenInfocmpAbsent(t *testing.T) {
	t.Cleanup(envSnapshot(t, "PATH"))

	// Empty PATH ⇒ exec.Command("infocmp") cannot find the binary, which
	// returns the same error class as a real "infocmp xterm-ghostty"
	// failure. Either way, resolveDefaultTerm must fall back.
	if err := os.Setenv("PATH", ""); err != nil {
		t.Fatalf("setenv PATH: %v", err)
	}

	got := resolveDefaultTerm()
	if got != "xterm-256color" {
		t.Errorf("resolveDefaultTerm() = %q, want %q (fallback when infocmp can't resolve xterm-ghostty)", got, "xterm-256color")
	}
}

// TestResolveDefaultTerm_PrefersXtermGhosttyWhenInfocmpSucceeds asserts the
// happy-path return value when the terminfo entry IS installed. Skipped on
// hosts that don't have either `infocmp` or the xterm-ghostty entry.
func TestResolveDefaultTerm_PrefersXtermGhosttyWhenInfocmpSucceeds(t *testing.T) {
	if !hasInfocmp() {
		t.Skip("infocmp not in PATH — fallback path is covered by TestResolveDefaultTerm_FallsBackWhenInfocmpAbsent")
	}

	// Probe: does this host have xterm-ghostty terminfo? Skip if not — the
	// happy path requires a real terminfo entry and we don't want to depend
	// on test-host configuration.
	probe := exec.Command("infocmp", "xterm-ghostty")
	probe.Stdout = nil
	probe.Stderr = nil
	if err := probe.Run(); err != nil {
		t.Skip("xterm-ghostty terminfo not installed on this host — fallback path is covered separately")
	}

	got := resolveDefaultTerm()
	if got != "xterm-ghostty" {
		t.Errorf("resolveDefaultTerm() = %q, want %q (terminfo present)", got, "xterm-ghostty")
	}
}
