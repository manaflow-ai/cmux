package main

import "testing"

func TestAgentLaunchNonLaunchClassification(t *testing.T) {
	tests := []struct {
		name       string
		classifier func([]string) bool
		args       []string
		want       bool
	}{
		{"claude management", claudeTeamsLaunchIsNonLaunch, []string{"--verbose", "auth"}, true},
		{"claude Agent View", claudeTeamsLaunchIsNonLaunch, []string{"agents"}, false},
		{"claude tmux management", claudeTeamsLaunchIsNonLaunch, []string{"--tmux", "classic", "doctor"}, true},
		{"claude informational after prompt", claudeTeamsLaunchIsNonLaunch, []string{"prompt", "--version"}, true},
		{"claude uppercase V is a launch", claudeTeamsLaunchIsNonLaunch, []string{"-V"}, false},
		{"claude command-shaped value", claudeTeamsLaunchIsNonLaunch, []string{"--model", "doctor"}, false},
		{"claude ambiguous optional value", claudeTeamsLaunchIsNonLaunch, []string{"--debug", "doctor"}, false},
		{"claude session routing", claudeTeamsLaunchIsNonLaunch, []string{"--resume", "doctor"}, false},
		{"claude tmux prompt", claudeTeamsLaunchIsNonLaunch, []string{"--tmux", "doctor"}, false},
		{"omo management with mdns", omoLaunchIsNonLaunch, []string{"--mdns", "models"}, true},
		{"omo ACP service", omoLaunchIsNonLaunch, []string{"acp"}, false},
		{"omo headless service", omoLaunchIsNonLaunch, []string{"serve"}, false},
		{"omo web service", omoLaunchIsNonLaunch, []string{"web"}, false},
		{"omo management with port", omoLaunchIsNonLaunch, []string{"--port", "4096", "models"}, true},
		{"omo management with hostname", omoLaunchIsNonLaunch, []string{"--hostname=127.0.0.1", "models"}, true},
		{"omo management with mdns domain", omoLaunchIsNonLaunch, []string{"--mdns-domain", "local", "models"}, true},
		{"omo management with cors", omoLaunchIsNonLaunch, []string{"--cors", "https://example.com", "models"}, true},
		{"omo command-shaped port value", omoLaunchIsNonLaunch, []string{"--port", "models"}, false},
		{"omo missing cors value", omoLaunchIsNonLaunch, []string{"--cors"}, false},
		{"omo real launch after mdns", omoLaunchIsNonLaunch, []string{"--mdns", "run", "hello"}, false},
		{"omx first-token management", omxLaunchIsNonLaunch, []string{"setup"}, true},
		{"omx first-token help", omxLaunchIsNonLaunch, []string{"--help"}, true},
		{"omx leading option dispatches launch", omxLaunchIsNonLaunch, []string{"--scope", "project", "setup"}, false},
		{"omc management", omcLaunchIsNonLaunch, []string{"doctor", "conflicts"}, true},
		{"omc real launch", omcLaunchIsNonLaunch, []string{"start a team"}, false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.classifier(test.args); got != test.want {
				t.Fatalf("classification = %v, want %v for %q", got, test.want, test.args)
			}
		})
	}
}

func TestClaudeTeamsVariadicValuesNeverBecomeManagementCommands(t *testing.T) {
	for _, option := range []string{
		"--add-dir", "--allowedTools", "--allowed-tools", "--betas",
		"--dangerously-load-development-channels", "--disallowedTools",
		"--disallowed-tools", "--file", "--mcp-config", "--tools",
	} {
		t.Run(option, func(t *testing.T) {
			args := []string{option, "/tmp/value", "auth"}
			if claudeTeamsLaunchIsNonLaunch(args) {
				t.Fatalf("variadic option values were classified as management: %q", args)
			}
		})
	}
}
