package main

import (
	"reflect"
	"strings"
	"testing"
)

// fakeClaudeProcessTree is an in-memory process tree for ancestor walks.
type fakeClaudeProcessTree struct {
	parents map[int]int
	argvs   map[int][]string
}

// parent returns the recorded parent PID.
func (tree fakeClaudeProcessTree) parent(pid int) int { return tree.parents[pid] }

// argv returns the recorded argv.
func (tree fakeClaudeProcessTree) argv(pid int) []string {
	return tree.argvs[pid]
}

// TestClaudeRelayAncestorWordsRedactsForwardedArguments checks that only identifying words leave the host.
func TestClaudeRelayAncestorWordsRedactsForwardedArguments(t *testing.T) {
	cases := []struct {
		name string
		argv []string
		want []string
	}{
		{"plain launcher keeps only argv0", []string{"/usr/local/bin/teamclaude", "run", "--token", "sk-secret", "--"}, []string{"/usr/local/bin/teamclaude"}},
		{"env assignments keep names only", []string{"env", "ANTHROPIC_API_KEY=sk-secret", "llm-gateway", "exec", "--key=hunter2"}, []string{"env", "ANTHROPIC_API_KEY=", "llm-gateway"}},
		{"env value options are placeholders", []string{"env", "-u", "SECRET_NAME", "--chdir=/srv/private", "teamclaude"}, []string{"env", "-u", "?", "--chdir=", "teamclaude"}},
		{"node follows to the script", []string{"node", "/usr/lib/node_modules/teamclaude/cli.js", "run", "--api-key", "sk-secret"}, []string{"node", "/usr/lib/node_modules/teamclaude/cli.js"}},
		{"interpreter option stops the scan", []string{"python3", "-c", "import os; os.system('secret')"}, []string{"python3"}},
		{"npx flags are kept, values never", []string{"npx", "--yes", "teamclaude", "run", "--password", "p"}, []string{"npx", "--yes", "teamclaude"}},
		{"unknown runner option stops the scan", []string{"npx", "--package", "secret-pkg", "wrapper"}, []string{"npx"}},
		{"stdin dash stops non-env", []string{"node", "-", "wrapper"}, []string{"node"}},
		{"two forwarding levels", []string{"env", "A=1", "node", "/opt/tc.js", "--secret", "x"}, []string{"env", "A=", "node", "/opt/tc.js"}},
		{"word cap", []string{"env", "A=1", "B=2", "C=3", "D=4", "E=5", "F=6", "teamclaude"}, []string{"env", "A=", "B=", "C=", "D=", "E="}},
		{"long path falls back to basename", []string{"/" + strings.Repeat("a", 140) + "/teamclaude", "run"}, []string{"teamclaude"}},
		{"control characters end the words", []string{"env", "llm\ngateway"}, []string{"env"}},
		{"empty argv", nil, nil},
	}
	for _, tc := range cases {
		got := claudeRelayAncestorWords(tc.argv)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
		for _, word := range got {
			if strings.Contains(word, "secret") || strings.Contains(word, "hunter2") {
				t.Errorf("%s: leaked value in %q", tc.name, got)
			}
		}
	}
}

// TestClaudeRelayAncestorExecutablesWalksNearestFirstWithinBounds checks order, depth, and size bounds.
func TestClaudeRelayAncestorExecutablesWalksNearestFirstWithinBounds(t *testing.T) {
	tree := fakeClaudeProcessTree{
		parents: map[int]int{100: 90, 90: 80, 80: 70, 70: 1},
		argvs: map[int][]string{
			90: {"/usr/bin/teamclaude", "run", "--"},
			80: {},
			70: {"-zsh"},
		},
	}
	got := claudeRelayAncestorExecutables(100, tree)
	want := [][]string{{"/usr/bin/teamclaude"}, {"-zsh"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ancestors = %q, want %q", got, want)
	}

	deep := fakeClaudeProcessTree{parents: map[int]int{}, argvs: map[int][]string{}}
	for pid := 2; pid < 40; pid++ {
		deep.parents[pid] = pid + 1
		deep.argvs[pid+1] = []string{"/" + strings.Repeat("d", 100)}
	}
	walked := claudeRelayAncestorExecutables(2, deep)
	if len(walked) != claudeRelayAncestorMaximumCount {
		t.Fatalf("walked %d ancestors, want %d", len(walked), claudeRelayAncestorMaximumCount)
	}

	wide := fakeClaudeProcessTree{parents: map[int]int{}, argvs: map[int][]string{}}
	for pid := 2; pid < 12; pid++ {
		wide.parents[pid] = pid + 1
		wide.argvs[pid+1] = []string{"env", "A=1", "B=2", "C=3", "D=4", "/" + strings.Repeat("w", 120)}
	}
	total := 0
	for _, words := range claudeRelayAncestorExecutables(2, wide) {
		if len(words) > claudeRelayAncestorMaximumWords {
			t.Fatalf("ancestor has %d words", len(words))
		}
		for _, word := range words {
			if len(word) > claudeRelayAncestorMaximumWordBytes {
				t.Fatalf("word of %d bytes", len(word))
			}
			total += len(word)
		}
	}
	if total > claudeRelayAncestorMaximumBytes {
		t.Fatalf("ancestors total %d bytes", total)
	}
}

// TestClaudeRelayRemoteCwdIsBounded checks the cwd admission rules.
func TestClaudeRelayRemoteCwdIsBounded(t *testing.T) {
	for input, want := range map[string]string{
		`{"cwd":"/home/leo/repo"}`:                     "/home/leo/repo",
		`{"cwd":"relative/path"}`:                      "",
		`{"cwd":"/home/leo/\nrepo"}`:                   "",
		`{"cwd":"/` + strings.Repeat("x", 1024) + `"}`: "",
		`{"cwd":7}`:                           "",
		`not json`:                            "",
		`{"nested":{"cwd":"/home/leo/repo"}}`: "",
	} {
		if got := claudeRelayRemoteCwd([]byte(input)); got != want {
			t.Errorf("claudeRelayRemoteCwd(%.40q) = %q, want %q", input, got, want)
		}
	}
}

// TestClaudeHookEnqueueParamsSendsResumeContextOnlyOnSessionStart checks which events carry the binding.
func TestClaudeHookEnqueueParamsSendsResumeContextOnlyOnSessionStart(t *testing.T) {
	previous := claudeRelayProcessTree
	claudeRelayProcessTree = fakeClaudeProcessTree{
		parents: map[int]int{4242: 4200, 4200: 1},
		argvs:   map[int][]string{4200: {"env", "TOKEN=sk-secret", "teamclaude", "run", "--"}},
	}
	t.Cleanup(func() { claudeRelayProcessTree = previous })
	env := claudeHookTestEnv(map[string]string{
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
		"CMUX_CLAUDE_PID":   "4242",
	})
	noTTY := func(string) string { return "" }
	input := []byte(`{"session_id":"sess-1","cwd":"/home/leo/repo","transcript_path":"/home/leo/t.jsonl"}`)

	p, ok := claudeHookEnqueueParams("session-start", input, env, noTTY)
	if !ok {
		t.Fatal("session-start was not relayed")
	}
	if p["remote_cwd"] != "/home/leo/repo" {
		t.Fatalf("remote_cwd = %v", p["remote_cwd"])
	}
	want := [][]string{{"env", "TOKEN=", "teamclaude"}}
	if got := p["ancestor_executables"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("ancestor_executables = %v, want %v", got, want)
	}
	if strings.Contains(p["payload"].(string), "/home/leo") {
		t.Fatalf("payload kept a host path: %s", p["payload"])
	}
	for _, key := range []string{"command", "argv", "environment", "launch_command", "settings"} {
		if _, present := p[key]; present {
			t.Fatalf("relay hook sent %q", key)
		}
	}

	for _, subcommand := range []string{"stop", "prompt-submit", "notification", "session-end"} {
		p, _ := claudeHookEnqueueParams(subcommand, input, env, noTTY)
		if _, present := p["remote_cwd"]; present {
			t.Fatalf("%s sent remote_cwd", subcommand)
		}
		if _, present := p["ancestor_executables"]; present {
			t.Fatalf("%s sent ancestor_executables", subcommand)
		}
	}
}
