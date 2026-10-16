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
		{"claude import starts a session", claudeTeamsLaunchIsNonLaunch, []string{"import", "codex", "--dry-run"}, false},
		{"claude background management", claudeTeamsLaunchIsNonLaunch, []string{"logs", "session-id"}, true},
		{"claude daemon status", claudeTeamsLaunchIsNonLaunch, []string{"daemon", "status"}, true},
		{"claude daemon stop with config", claudeTeamsLaunchIsNonLaunch, []string{"daemon", "--json-path", "/tmp/daemon.json", "stop", "--any"}, true},
		{"claude daemon host", claudeTeamsLaunchIsNonLaunch, []string{"daemon", "run"}, false},
		{"claude bare daemon", claudeTeamsLaunchIsNonLaunch, []string{"daemon"}, false},
		{"claude Agent View", claudeTeamsLaunchIsNonLaunch, []string{"agents"}, false},
		{"claude agents JSON", claudeTeamsLaunchIsNonLaunch, []string{"agents", "--json"}, true},
		{"claude all agents JSON", claudeTeamsLaunchIsNonLaunch, []string{"agents", "--all", "--json"}, true},
		{"claude Agent View all", claudeTeamsLaunchIsNonLaunch, []string{"agents", "--all"}, false},
		{"claude agents JSON prompt", claudeTeamsLaunchIsNonLaunch, []string{"agents", "--json", "prompt"}, false},
		{"claude ultrareview workflow", claudeTeamsLaunchIsNonLaunch, []string{"ultrareview"}, false},
		{"claude tmux management", claudeTeamsLaunchIsNonLaunch, []string{"--tmux", "classic", "doctor"}, true},
		{"claude informational after prompt", claudeTeamsLaunchIsNonLaunch, []string{"prompt", "--version"}, true},
		{"claude informational after forward subagent text", claudeTeamsLaunchIsNonLaunch, []string{"--forward-subagent-text", "--version"}, true},
		{"claude uppercase V is a launch", claudeTeamsLaunchIsNonLaunch, []string{"-V"}, false},
		{"claude command-shaped value", claudeTeamsLaunchIsNonLaunch, []string{"--model", "doctor"}, false},
		{"claude background command-shaped value", claudeTeamsLaunchIsNonLaunch, []string{"--model", "logs"}, false},
		{"claude ambiguous optional value", claudeTeamsLaunchIsNonLaunch, []string{"--debug", "doctor"}, false},
		{"claude session routing", claudeTeamsLaunchIsNonLaunch, []string{"--resume", "doctor"}, false},
		{"claude tmux prompt", claudeTeamsLaunchIsNonLaunch, []string{"--tmux", "doctor"}, false},
		{"omo management with mdns", omoLaunchIsNonLaunch, []string{"--mdns", "models"}, true},
		{"omo session help", omoLaunchIsNonLaunch, []string{"session", "--help"}, true},
		{"omo unknown session command help", omoLaunchIsNonLaunch, []string{"session", "run", "--help"}, true},
		{"omo session list after global option", omoLaunchIsNonLaunch, []string{"session", "--log-level", "WARN", "list"}, true},
		{"omo github install after joined global option", omoLaunchIsNonLaunch, []string{"github", "--log-level=ERROR", "install"}, true},
		{"omo run help", omoLaunchIsNonLaunch, []string{"run", "--help"}, true},
		{"omo run version after prompt", omoLaunchIsNonLaunch, []string{"run", "message", "--version"}, true},
		{"omo run help after option value", omoLaunchIsNonLaunch, []string{"run", "--log-level", "WARN", "--help"}, true},
		{"omo session delimiter help", omoLaunchIsNonLaunch, []string{"session", "--", "--help"}, false},
		{"omo session delimiter list", omoLaunchIsNonLaunch, []string{"session", "--", "list"}, false},
		{"omo session unknown option list", omoLaunchIsNonLaunch, []string{"session", "--unknown-option", "list"}, false},
		{"omo github missing option value", omoLaunchIsNonLaunch, []string{"github", "--log-level"}, false},
		{"omo run delimiter help", omoLaunchIsNonLaunch, []string{"run", "--", "--help"}, false},
		{"omo run help in option value", omoLaunchIsNonLaunch, []string{"run", "--log-level", "--help"}, false},
		{"omo run help after unknown option", omoLaunchIsNonLaunch, []string{"run", "--unknown-option", "--help"}, false},
		{"omo github install", omoLaunchIsNonLaunch, []string{"github", "install"}, true},
		{"omo github run", omoLaunchIsNonLaunch, []string{"github", "run"}, false},
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
		{"omx operator command", omxLaunchIsNonLaunch, []string{"ask", "question"}, true},
		{"omx first-token help", omxLaunchIsNonLaunch, []string{"--help"}, true},
		{"omx team api", omxLaunchIsNonLaunch, []string{"team", "api", "claim-task"}, true},
		{"omx team status", omxLaunchIsNonLaunch, []string{"team", "status", "demo"}, true},
		{"omx team shutdown", omxLaunchIsNonLaunch, []string{"team", "shutdown", "demo"}, true},
		{"omx team help", omxLaunchIsNonLaunch, []string{"team", "--help"}, true},
		{"omx nested team help", omxLaunchIsNonLaunch, []string{"team", "resume", "--help"}, true},
		{"omx bare team", omxLaunchIsNonLaunch, []string{"team"}, false},
		{"omx team resume", omxLaunchIsNonLaunch, []string{"team", "resume"}, false},
		{"omx leading option dispatches launch", omxLaunchIsNonLaunch, []string{"--scope", "project", "setup"}, false},
		{"omx operator after leading option dispatches launch", omxLaunchIsNonLaunch, []string{"--scope", "project", "ask"}, false},
		{"omx informational option value dispatches launch", omxLaunchIsNonLaunch, []string{"--scope", "--version"}, false},
		{"omx delimiter blocks informational option", omxLaunchIsNonLaunch, []string{"--", "--version"}, false},
		{"omc management", omcLaunchIsNonLaunch, []string{"doctor", "conflicts"}, true},
		{"omc team api", omcLaunchIsNonLaunch, []string{"team", "api", "claim-task"}, true},
		{"omc team status", omcLaunchIsNonLaunch, []string{"team", "status", "demo"}, true},
		{"omc team shutdown", omcLaunchIsNonLaunch, []string{"team", "shutdown", "demo"}, true},
		{"omc team help", omcLaunchIsNonLaunch, []string{"team", "--help"}, true},
		{"omc nested team help", omcLaunchIsNonLaunch, []string{"team", "resume", "--help"}, true},
		{"omc team short help", omcLaunchIsNonLaunch, []string{"team", "-h"}, true},
		{"omc bare team", omcLaunchIsNonLaunch, []string{"team"}, false},
		{"omc team resume", omcLaunchIsNonLaunch, []string{"team", "resume"}, false},
		{"omc team launch", omcLaunchIsNonLaunch, []string{"team", "1:codex", "review this"}, false},
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
