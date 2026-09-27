package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// fakeClaudeProcessTree is a fixed process table: pid -> parent and argv.
type fakeClaudeProcessTree map[int]struct {
	parentPID int
	args      []string
}

func (tree fakeClaudeProcessTree) parent(pid int) int { return tree[pid].parentPID }
func (tree fakeClaudeProcessTree) argv(pid int) []string {
	return tree[pid].args
}

// srTmuxProcessTree mirrors a Claude session started by a launcher inside a
// tmux server that predates cmux: tmux -> sr -> claude -> sh -> hook.
func srTmuxProcessTree() fakeClaudeProcessTree {
	return fakeClaudeProcessTree{
		100: {1, []string{"tmux", "new-session", "-d", "-s", "cc-s064"}},
		200: {100, []string{"sr", "claude", "proxy", "--account", "a@example.com", "--resume", "064ae598"}},
		300: {200, []string{"/home/u/.local/bin/claude", "--settings", "/tmp/subrouter-claude-settings-1/settings.json", "--resume", "064ae598"}},
		400: {300, []string{"/bin/sh", "-c", "test -x x && x claude-hook --user-settings stop || :"}},
		// A `claude -p` an agent tool call ran from that session.
		500: {300, []string{"bash", "-c", "claude -p hi"}},
		600: {500, []string{"/home/u/.local/share/claude/versions/2.1.283", "-p", "hi"}},
		700: {600, []string{"/bin/sh", "-c", "hook"}},
	}
}

// fakeClaudeHookTmuxProbe answers tmux queries from fixed output.
func fakeClaudeHookTmuxProbe(session string, clients string, environments map[int]map[string]string) (claudeHookTmuxProbe, *[][]string) {
	var calls [][]string
	return claudeHookTmuxProbe{
		run: func(args ...string) (string, error) {
			calls = append(calls, args)
			switch args[0] {
			case "display-message":
				return session + "\n", nil
			case "list-clients":
				return clients, nil
			}
			return "", errors.New("unexpected tmux command")
		},
		environ: func(pid int) map[string]string { return environments[pid] },
	}, &calls
}

// cmuxClientEnvironment is the environment cmux gives its tmux attach client.
func cmuxClientEnvironment(port string, surface string) map[string]string {
	return map[string]string{
		"CMUX_SOCKET_PATH":  "127.0.0.1:" + port,
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   surface,
		"TERM":              "xterm-ghostty",
	}
}

// TestClaudeHookAgentProcessFindsLauncherStartedClaude checks the hook finds its Claude through the shell and flags nested sessions.
func TestClaudeHookAgentProcessFindsLauncherStartedClaude(t *testing.T) {
	tree := srTmuxProcessTree()
	if pid, nested := claudeHookAgentProcess(400, tree); pid != 300 || nested {
		t.Fatalf("top-level session: pid=%d nested=%v, want 300 false", pid, nested)
	}
	// Claude Code may run the hook without an intermediate shell.
	if pid, nested := claudeHookAgentProcess(300, tree); pid != 300 || nested {
		t.Fatalf("direct child: pid=%d nested=%v, want 300 false", pid, nested)
	}
	if pid, nested := claudeHookAgentProcess(700, tree); pid != 600 || !nested {
		t.Fatalf("nested claude -p: pid=%d nested=%v, want 600 true", pid, nested)
	}
	if pid, _ := claudeHookAgentProcess(100, tree); pid != 0 {
		t.Fatalf("no Claude above tmux: pid=%d", pid)
	}
}

// TestClaudeHookIsAgentArgv covers the shapes Claude Code is started with.
func TestClaudeHookIsAgentArgv(t *testing.T) {
	for _, argv := range [][]string{
		{"claude"},
		{"/usr/local/bin/claude", "--resume", "x"},
		{"/home/u/.local/share/claude/versions/2.1.283"},
		{"node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"},
		{"/usr/bin/node", "/home/u/.npm-global/bin/claude"},
	} {
		if !claudeHookIsAgentArgv(argv) {
			t.Fatalf("%v should be Claude", argv)
		}
	}
	for _, argv := range [][]string{
		nil,
		{"sr", "claude", "proxy"},
		{"tmux", "attach", "-t", "claude"},
		{"node", "server.js", "claude"},
		{"claude-teams"},
	} {
		if claudeHookIsAgentArgv(argv) {
			t.Fatalf("%v should not be Claude", argv)
		}
	}
}

// TestDiscoverClaudeHookTmuxRouteUsesAttachedCmuxClient picks the most recent cmux client of the hook's own session.
func TestDiscoverClaudeHookTmuxRouteUsesAttachedCmuxClient(t *testing.T) {
	getenv := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-1000/default,100,0", "TMUX_PANE": "%3"})
	clients := strings.Join([]string{
		"4101\t/dev/pts/9\t1790000300", // a plain terminal, newest
		"4102\t/dev/pts/4\t1790000100",
		"4103\t/dev/pts/5\t1790000200",
		"garbage",
	}, "\n")
	probe, calls := fakeClaudeHookTmuxProbe("$2", clients, map[int]map[string]string{
		4101: {"TERM": "xterm-256color"},
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
		4103: cmuxClientEnvironment("62357", "33333333-3333-4333-8333-333333333333"),
	})
	route, ok := discoverClaudeHookTmuxRoute(getenv, probe)
	if !ok {
		t.Fatal("expected a route from the attached cmux client")
	}
	if route.socketPath != "127.0.0.1:62357" || route.surfaceID != "33333333-3333-4333-8333-333333333333" || route.clientTTY != "/dev/pts/5" {
		t.Fatalf("route = %+v, want the most recent cmux client", route)
	}
	if got := strings.Join((*calls)[0], " "); got != "display-message -p -t %3 #{session_id}" {
		t.Fatalf("session query = %q", got)
	}
	if got := strings.Join((*calls)[1][:3], " "); got != "list-clients -t $2" {
		t.Fatalf("client query = %q", got)
	}
}

// TestDiscoverClaudeHookTmuxRouteRequiresTmuxAndCmuxClient keeps hooks outside cmux-attached tmux sessions silent.
func TestDiscoverClaudeHookTmuxRouteRequiresTmuxAndCmuxClient(t *testing.T) {
	environments := map[int]map[string]string{4102: {"CMUX_SOCKET_PATH": "127.0.0.1:1", "CMUX_WORKSPACE_ID": "w"}}
	probe, calls := fakeClaudeHookTmuxProbe("$2", "4102\t/dev/pts/4\t1\n", environments)
	if _, ok := discoverClaudeHookTmuxRoute(claudeHookTestEnv(nil), probe); ok || len(*calls) != 0 {
		t.Fatalf("outside tmux: ok=%v calls=%v", ok, *calls)
	}
	inTmux := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-1000/default,100,0"})
	if _, ok := discoverClaudeHookTmuxRoute(inTmux, probe); ok {
		t.Fatal("a client without a surface id must not route")
	}
	failing := claudeHookTmuxProbe{
		run:     func(...string) (string, error) { return "", errors.New("no server") },
		environ: func(int) map[string]string { return nil },
	}
	if _, ok := discoverClaudeHookTmuxRoute(inTmux, failing); ok {
		t.Fatal("a tmux failure must not route")
	}
}

// TestResolveClaudeHookDeliveryFollowsTmuxClientWithoutEnvironment covers a launcher-started Claude in a tmux server that predates cmux.
func TestResolveClaudeHookDeliveryFollowsTmuxClientWithoutEnvironment(t *testing.T) {
	paneEnv := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-1000/default,100,0", "TMUX_PANE": "%0"})
	probe, _ := fakeClaudeHookTmuxProbe("$0", "4102\t/dev/pts/4\t1\n", map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
	})
	base := claudeHookDelivery{
		socketPath:  "127.0.0.1:62357", // ~/.cmux/socket_addr names another workspace's relay
		refreshAddr: func() string { return "127.0.0.1:62357" },
		getenv:      paneEnv,
		callerTTY:   func(string) string { return "/dev/pts/1" },
	}
	delivery, ok := resolveClaudeHookDelivery(base, true, 400, srTmuxProcessTree(), probe)
	if !ok {
		t.Fatal("expected delivery through the attached cmux client")
	}
	if delivery.socketPath != "127.0.0.1:63518" || delivery.refreshAddr != nil {
		t.Fatalf("delivery must use the client's relay only: %q refresh=%v", delivery.socketPath, delivery.refreshAddr != nil)
	}
	params, ok := claudeHookEnqueueParams("stop", []byte(`{"session_id":"s"}`), delivery.getenv, delivery.callerTTY)
	if !ok {
		t.Fatal("expected enqueue params")
	}
	if params["workspace_id"] != "11111111-1111-4111-8111-111111111111" ||
		params["surface_id"] != "22222222-2222-4222-8222-222222222222" ||
		params["caller_tty"] != "/dev/pts/4" {
		t.Fatalf("params = %v", params)
	}
	if got := delivery.getenv("CMUX_CLAUDE_PID"); got != "300" {
		t.Fatalf("CMUX_CLAUDE_PID = %q, want the discovered Claude pid", got)
	}

	// The same hook without the user-settings flag keeps the old contract:
	// it has no surface environment, so it does not route.
	wrapperDelivery, ok := resolveClaudeHookDelivery(base, false, 400, srTmuxProcessTree(), probe)
	if !ok {
		t.Fatal("wrapper hooks keep their socket")
	}
	if _, ok := claudeHookEnqueueParams("stop", []byte(`{}`), wrapperDelivery.getenv, wrapperDelivery.callerTTY); ok {
		t.Fatal("a wrapper hook without surface environment must not route")
	}
}

// TestResolveClaudeHookDeliveryStepsAsideForWrapperAndNestedSessions avoids double reports.
func TestResolveClaudeHookDeliveryStepsAsideForWrapperAndNestedSessions(t *testing.T) {
	probe, _ := fakeClaudeHookTmuxProbe("$0", "4102\t/dev/pts/4\t1\n", map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
	})
	values := map[string]string{
		"TMUX":              "/tmp/tmux-1000/default,100,0",
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
		"CMUX_SOCKET_PATH":  "127.0.0.1:63518",
	}
	values[claudeRelayWrapperActiveKey] = "1"
	base := claudeHookDelivery{socketPath: "127.0.0.1:63518", getenv: claudeHookTestEnv(values), callerTTY: func(string) string { return "" }}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, srTmuxProcessTree(), probe); ok {
		t.Fatal("installed hooks must step aside when the wrapper injected its own")
	}
	delete(values, claudeRelayWrapperActiveKey)
	if _, ok := resolveClaudeHookDelivery(base, true, 700, srTmuxProcessTree(), probe); ok {
		t.Fatal("installed hooks must not report a nested Claude session")
	}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, srTmuxProcessTree(), probe); !ok {
		t.Fatal("a top-level session with its own environment must route")
	}
}

// TestClaudeHookRelayUserSettingsUsesSurfaceEnvironment runs the installed hook command shape end to end.
func TestClaudeHookRelayUserSettingsUsesSurfaceEnvironment(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("TMUX", "")
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	t.Setenv("CMUX_SURFACE_ID", "22222222-2222-4222-8222-222222222222")
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "")
	t.Setenv(claudeRelayWrapperActiveKey, "")
	// Keep the test's own ancestry (which may include an agent) out of it.
	previousTree := claudeRelayProcessTree
	claudeRelayProcessTree = fakeClaudeProcessTree{}
	t.Cleanup(func() { claudeRelayProcessTree = previousTree })
	var stdout bytes.Buffer
	code := runClaudeHookRelay(sockPath, []string{claudeHookUserSettingsFlag, "prompt-submit"}, nil,
		strings.NewReader(`{"session_id":"s"}`), &stdout)
	if code != 0 || strings.TrimSpace(stdout.String()) != "{}" {
		t.Fatalf("exit %d stdout %q", code, stdout.String())
	}
	req := receiveRequest(t, requests)
	if p := params(req); p["subcommand"] != "prompt-submit" || p["surface_id"] != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("params = %v", p)
	}
}
