package main

import "testing"

// TestTmuxVersionAtLeast verifies the version comparison logic that gates
// exact-match target syntax (tmux ≥2.5) and control-mode support (tmux ≥1.8).
func TestTmuxVersionAtLeast(t *testing.T) {
	tests := []struct {
		version string
		major   int
		minor   int
		want    bool
	}{
		// Exact match
		{"2.5", 2, 5, true},
		{"1.8", 1, 8, true},
		{"3.4", 3, 4, true},

		// Greater than
		{"3.0", 2, 5, true},
		{"3.4", 3, 3, true},
		{"3.5", 3, 4, true},
		{"4.0", 3, 4, true},
		{"2.9", 2, 5, true},

		// Less than
		{"2.4", 2, 5, false},
		{"1.7", 1, 8, false},
		{"3.3", 3, 4, false},
		{"1.9", 2, 0, false},

		// Suffix stripped (e.g. "3.4a" release candidates)
		{"3.4a", 3, 4, true},
		{"3.3b", 3, 4, false},
		{"2.5a", 2, 5, true},

		// Minor == 0 edge cases
		{"3.0", 3, 0, true},
		{"2.0", 3, 0, false},

		// Malformed input — should not panic, return false
		{"", 2, 5, false},
		{"abc", 2, 5, false},
		{"x.y", 2, 5, false},
	}
	for _, tt := range tests {
		got := tmuxVersionAtLeast(tt.version, tt.major, tt.minor)
		if got != tt.want {
			t.Errorf("tmuxVersionAtLeast(%q, %d, %d) = %v, want %v",
				tt.version, tt.major, tt.minor, got, tt.want)
		}
	}
}

// TestIsValidNewTmuxName verifies names that are allowed for new tmux sessions.
// The restriction is intentionally tighter than what tmux itself permits —
// only ASCII alphanumeric, dash, and underscore — to ensure unambiguous exact targets.
func TestIsValidNewTmuxName(t *testing.T) {
	valid := []string{
		"dev",
		"my-session",
		"my_session",
		"Session123",
		"abc-123_DEF",
		"a",
	}
	invalid := []string{
		"",           // empty
		"my session", // space
		"my:session", // colon — tmux would parse as window target
		"my.session", // dot — tmux would parse as pane target
		"foo/bar",    // slash
		"@special",   // at-sign
		"$id",        // dollar — tmux session ID prefix
		"%pane",      // percent — tmux pane ID prefix
	}

	for _, name := range valid {
		if !isValidNewTmuxName(name) {
			t.Errorf("isValidNewTmuxName(%q) = false, want true", name)
		}
	}
	for _, name := range invalid {
		if isValidNewTmuxName(name) {
			t.Errorf("isValidNewTmuxName(%q) = true, want false", name)
		}
	}
}
