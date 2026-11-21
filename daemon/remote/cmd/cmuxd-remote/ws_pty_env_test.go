package main

import "testing"

// The daemon inherits its own process environment when seeding a remote PTY
// session. Terminal-identity variables set on the host (for example when
// cmuxd-remote is launched from tmux, iTerm, or Apple Terminal) must not leak
// into the session: the remote PTY always presents cmux's own identity.
func TestDefaultWebSocketPTYEnvForcesTerminalIdentity(t *testing.T) {
	t.Setenv("TERM_PROGRAM", "iTerm.app")
	t.Setenv("COLORTERM", "24bit")
	t.Setenv("TERM_PROGRAM_VERSION", "3.5.0")

	env, _ := envMapWithOrder(defaultWebSocketPTYEnv("/bin/zsh"))

	for _, tc := range []struct{ key, want string }{
		{"TERM_PROGRAM", "ghostty"},
		{"COLORTERM", "truecolor"},
	} {
		if got := env[tc.key]; got != tc.want {
			t.Errorf("%s = %q, want %q (host value must not leak into the remote PTY)", tc.key, got, tc.want)
		}
	}
	if got, ok := env["TERM_PROGRAM_VERSION"]; ok {
		t.Errorf("TERM_PROGRAM_VERSION = %q, want unset (host terminal version must not leak)", got)
	}
}

// PATH is the one environment variable that the SSH client can accidentally
// carry across hosts through AcceptEnv. The remote login shell must be allowed
// to initialize it from the remote host's own startup files instead.
func TestDefaultWebSocketPTYEnvDoesNotInheritClientPath(t *testing.T) {
	t.Setenv("PATH", "/Users/jluker/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")

	env, _ := envMapWithOrder(defaultWebSocketPTYEnv("/bin/zsh"))
	if _, ok := env["PATH"]; ok {
		t.Fatalf("PATH = %q, want omitted so the remote login shell can initialize it", env["PATH"])
	}
}
