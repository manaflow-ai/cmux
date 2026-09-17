package home

import (
	"strings"
	"testing"
)

func TestAdapterResumeCommands(t *testing.T) {
	session := Session{ID: "row", SessionID: "session with space", CWD: "/tmp/cmux repo"}
	tests := map[string]string{
		"claude":   "cd '/tmp/cmux repo' && 'claude' '--resume' 'session with space'",
		"codex":    "cd '/tmp/cmux repo' && 'codex' 'resume' 'session with space'",
		"opencode": "cd '/tmp/cmux repo' && 'opencode' '--session' 'session with space'",
		"pi":       "cd '/tmp/cmux repo' && 'pi' '--session' 'session with space'",
	}

	for id, want := range tests {
		adapter, ok := AdapterFor(id)
		if !ok {
			t.Fatalf("missing adapter %s", id)
		}
		if got := adapter.ResumeCommand(session); got != want {
			t.Fatalf("%s resume command = %q, want %q", id, got, want)
		}
		if len(adapter.FeatureGaps) == 0 {
			t.Fatalf("%s should declare known feature gaps", id)
		}
		if !strings.Contains(adapter.ResumeTemplate, "{{sessionId}}") {
			t.Fatalf("%s resume template should contain session placeholder", id)
		}
	}
}

func TestShellQuoteEscapesSingleQuotes(t *testing.T) {
	if got := ShellQuote("can't"); got != "'can'\\''t'" {
		t.Fatalf("ShellQuote = %q", got)
	}
}
