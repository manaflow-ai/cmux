package main

import (
	"encoding/base64"
	"os"
	"testing"
)

func TestEncodeClaudeTeamsRespawnEnvironmentRoundTripsPath(t *testing.T) {
	encoded := encodeClaudeTeamsRespawnEnvironment([]string{
		"PATH=/opt/homebrew/bin:/usr/bin:/bin",
		"HOME=/home/user",
	})
	if encoded == "" {
		t.Fatal("encode returned empty for an environment containing PATH")
	}

	decoded := decodeClaudeTeamsRespawnEnvironment(encoded)
	if got := decoded["PATH"]; got != "/opt/homebrew/bin:/usr/bin:/bin" {
		t.Errorf("PATH = %q, want the launcher PATH", got)
	}
	if len(decoded) != 1 {
		t.Errorf("decoded = %v, want PATH only", decoded)
	}
}

func TestEncodeClaudeTeamsRespawnEnvironmentDropsNonAllowlistedKeys(t *testing.T) {
	encoded := encodeClaudeTeamsRespawnEnvironment([]string{
		"PATH=/usr/bin",
		"ANTHROPIC_API_KEY=secret",
		"CMUX_SURFACE_ID=surface-1",
		"malformed-entry-without-separator",
	})

	decoded := decodeClaudeTeamsRespawnEnvironment(encoded)
	for _, key := range []string{"ANTHROPIC_API_KEY", "CMUX_SURFACE_ID"} {
		if _, ok := decoded[key]; ok {
			t.Errorf("%s crossed the respawn boundary", key)
		}
	}
	if decoded["PATH"] != "/usr/bin" {
		t.Errorf("PATH = %q, want /usr/bin", decoded["PATH"])
	}
}

func TestEncodeClaudeTeamsRespawnEnvironmentWithoutPathEncodesNothing(t *testing.T) {
	for _, environ := range [][]string{
		{"HOME=/home/user"},
		{"PATH="},
		nil,
	} {
		if got := encodeClaudeTeamsRespawnEnvironment(environ); got != "" {
			t.Errorf("encode(%v) = %q, want empty", environ, got)
		}
	}
}

// A forged or truncated transport value must yield nothing, never a partial or
// attacker-chosen environment.
func TestDecodeClaudeTeamsRespawnEnvironmentFailsClosed(t *testing.T) {
	tests := []struct {
		name    string
		encoded string
	}{
		{"empty", ""},
		{"not base64", "!!!not-base64!!!"},
		{"base64 of non-JSON", base64.StdEncoding.EncodeToString([]byte("PATH=/usr/bin"))},
		{"base64 of a JSON array", base64.StdEncoding.EncodeToString([]byte(`["PATH"]`))},
		{"base64 of a JSON string", base64.StdEncoding.EncodeToString([]byte(`"PATH"`))},
		{"non-string JSON values", base64.StdEncoding.EncodeToString([]byte(`{"PATH":42}`))},
		{"allowlisted key absent", base64.StdEncoding.EncodeToString([]byte(`{"LD_PRELOAD":"/tmp/evil.so"}`))},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if decoded := decodeClaudeTeamsRespawnEnvironment(tc.encoded); len(decoded) != 0 {
				t.Errorf("decoded = %v, want no values", decoded)
			}
		})
	}
}

func TestTmuxClaudeTeamsRespawnEnvironmentReplaysTransportedPath(t *testing.T) {
	encoded := encodeClaudeTeamsRespawnEnvironment([]string{"PATH=/opt/homebrew/bin:/usr/bin"})
	t.Setenv(claudeTeamsRespawnEnvironmentKey, encoded)
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "")

	pairs := tmuxClaudeTeamsRespawnEnvironment()
	want := []tmuxEnvPair{{key: "PATH", value: "/opt/homebrew/bin:/usr/bin"}}
	if len(pairs) != len(want) || pairs[0] != want[0] {
		t.Errorf("pairs = %v, want %v", pairs, want)
	}
}

func TestTmuxClaudeTeamsRespawnEnvironmentOrdersKeysDeterministically(t *testing.T) {
	t.Setenv(claudeTeamsRespawnEnvironmentKey, encodeClaudeTeamsRespawnEnvironment([]string{"PATH=/usr/bin"}))
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "1")

	pairs := tmuxClaudeTeamsRespawnEnvironment()
	want := []tmuxEnvPair{
		{key: "CLAUDE_CODE_SANDBOXED", value: "1"},
		{key: "PATH", value: "/usr/bin"},
	}
	if len(pairs) != len(want) {
		t.Fatalf("pairs = %v, want %v", pairs, want)
	}
	for i := range want {
		if pairs[i] != want[i] {
			t.Errorf("pairs[%d] = %v, want %v", i, pairs[i], want[i])
		}
	}
}

func TestTmuxClaudeTeamsRespawnEnvironmentWithoutOptInOrTransportIsEmpty(t *testing.T) {
	t.Setenv(claudeTeamsRespawnEnvironmentKey, "garbage")
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "")

	if pairs := tmuxClaudeTeamsRespawnEnvironment(); pairs != nil {
		t.Errorf("pairs = %v, want nil", pairs)
	}
}

// `cmux omc`/`omo`/`omx` launched from inside a claude-teams process tree must
// not replay the lead's PATH into its own pane respawns.
func TestConfigureAgentEnvironmentClearsInheritedRespawnTransport(t *testing.T) {
	for _, key := range []string{
		"PATH",
		"TMUX",
		"TMUX_PANE",
		"TERM",
		"CMUX_SOCKET_PATH",
		"CMUX_SOCKET",
		"TERM_PROGRAM",
		"COLORTERM",
		"CMUX_WORKSPACE_ID",
		"CMUX_SURFACE_ID",
		"CMUX_PANEL_ID",
		"CMUX_TAB_ID",
		"CMUX_PANE_ID",
		"CMUX_RESPAWN_TRANSPORT_TEST_BIN",
		"CMUX_RESPAWN_TRANSPORT_TEST_TERM",
	} {
		t.Setenv(key, os.Getenv(key))
	}
	t.Setenv("PATH", "/omc/own/bin:/usr/bin")
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "")
	t.Setenv(claudeTeamsRespawnEnvironmentKey,
		encodeClaudeTeamsRespawnEnvironment([]string{"PATH=/claude-teams/lead/bin"}))

	configureAgentEnvironment(agentConfig{
		shimDir:        t.TempDir(),
		socketPath:     "/tmp/cmux-respawn-transport-test.sock",
		launchContext:  nil,
		tmuxPathPrefix: "cmux-omc",
		cmuxBinEnvVar:  "CMUX_RESPAWN_TRANSPORT_TEST_BIN",
		termEnvVar:     "CMUX_RESPAWN_TRANSPORT_TEST_TERM",
		extraEnv:       map[string]string{},
	})

	if value, present := os.LookupEnv(claudeTeamsRespawnEnvironmentKey); present {
		t.Errorf("%s survived as %q", claudeTeamsRespawnEnvironmentKey, value)
	}
	if pairs := tmuxClaudeTeamsRespawnEnvironment(); pairs != nil {
		t.Errorf("pairs = %v, want nil", pairs)
	}
}
