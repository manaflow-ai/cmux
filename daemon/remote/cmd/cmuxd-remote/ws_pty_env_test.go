package main

import "testing"

// The daemon inherits its own process environment when seeding a remote PTY
// session. Terminal-identity variables set on the host (for example when
// cmuxd-remote is launched from tmux, iTerm, or Apple Terminal) must not leak
// into the session: the remote PTY always presents cmux's own identity.
func TestDefaultWebSocketPTYEnvForcesTerminalIdentity(t *testing.T) {
	t.Setenv("TERM_PROGRAM", "iTerm.app")
	t.Setenv("COLORTERM", "24bit")

	env, _ := envMapWithOrder(defaultWebSocketPTYEnv("/bin/zsh"))

	for _, tc := range []struct{ key, want string }{
		{"TERM_PROGRAM", "ghostty"},
		{"COLORTERM", "truecolor"},
	} {
		if got := env[tc.key]; got != tc.want {
			t.Errorf("%s = %q, want %q (host value must not leak into the remote PTY)", tc.key, got, tc.want)
		}
	}
}
