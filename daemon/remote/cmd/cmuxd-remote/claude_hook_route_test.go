package main

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
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

// launcherTmuxProcessTree mirrors a Claude session started by a launcher inside a
// tmux server that predates cmux: tmux -> launcher -> claude -> sh -> hook.
func launcherTmuxProcessTree() fakeClaudeProcessTree {
	return fakeClaudeProcessTree{
		100: {1, []string{"tmux", "new-session", "-d", "-s", "cc-s064"}},
		200: {100, []string{"launcher", "claude", "proxy", "--account", "a@example.com", "--resume", "064ae598"}},
		300: {200, []string{"/home/u/.local/bin/claude", "--settings", "/tmp/launcher-claude-settings-1/settings.json", "--resume", "064ae598"}},
		400: {300, []string{"/bin/sh", "-c", "test -x x && x claude-hook --user-settings stop || :"}},
		// A `claude -p` an agent tool call ran from that session.
		500: {300, []string{"bash", "-c", "claude -p hi"}},
		600: {500, []string{"/home/u/.local/share/claude/versions/2.1.283", "-p", "hi"}},
		700: {600, []string{"/bin/sh", "-c", "hook"}},
	}
}

// fakeClaudeHookTmuxProbe answers tmux queries from fixed output. pane is
// the display-message answer: session id, session group, window id.
func fakeClaudeHookTmuxProbe(pane string, clients string, environments map[int]map[string]string) (claudeHookTmuxProbe, *[][]string) {
	var calls [][]string
	return claudeHookTmuxProbe{
		run: func(args ...string) (string, error) {
			calls = append(calls, args)
			switch args[0] {
			case "display-message":
				return pane + "\n", nil
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
	tree := launcherTmuxProcessTree()
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
		{"launcher", "claude", "proxy"},
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
		"4101\t/dev/pts/9\t1790000300\t$2\t\t@1", // a plain terminal, newest
		"4102\t/dev/pts/4\t1790000100\t$2\t\t@1",
		"4103\t/dev/pts/5\t1790000200\t$2\t\t@1",
		"4104\t/dev/pts/6\t1790000400\t$7\t\t@9", // another session's cmux client
		"garbage",
	}, "\n")
	probe, calls := fakeClaudeHookTmuxProbe("$2\t\t@1", clients, map[int]map[string]string{
		4101: {"TERM": "xterm-256color"},
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
		4103: cmuxClientEnvironment("62357", "33333333-3333-4333-8333-333333333333"),
		4104: cmuxClientEnvironment("61000", "44444444-4444-4444-8444-444444444444"),
	})
	route, ok := discoverClaudeHookTmuxRoute(getenv, probe)
	if !ok {
		t.Fatal("expected a route from the attached cmux client")
	}
	if route.socketPath != "127.0.0.1:62357" || route.surfaceID != "33333333-3333-4333-8333-333333333333" || route.clientTTY != "/dev/pts/5" {
		t.Fatalf("route = %+v, want the most recent cmux client", route)
	}
	if got := strings.Join((*calls)[0], " "); got != "display-message -p -t %3 #{session_id}\t#{session_group}\t#{window_id}" {
		t.Fatalf("pane query = %q", got)
	}
	if got := strings.Join((*calls)[1][:2], " "); got != "list-clients -F" || len(*calls) != 2 {
		t.Fatalf("client query = %q after %d calls", got, len(*calls))
	}
}

// TestDiscoverClaudeHookTmuxRoutePrefersClientShowingThePane picks, among several cmux clients of one session group, the one whose current window holds the hook's pane.
func TestDiscoverClaudeHookTmuxRoutePrefersClientShowingThePane(t *testing.T) {
	getenv := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-1000/default,100,0", "TMUX_PANE": "%3"})
	clients := strings.Join([]string{
		"4102\t/dev/pts/4\t1790000100\t$2\twork\t@5", // shows the pane's window
		"4103\t/dev/pts/5\t1790000200\t$4\twork\t@6", // newer, grouped session on another window
		"4104\t/dev/pts/6\t1790000300\t$8\t\t@5",     // newest, unrelated session
	}, "\n")
	probe, _ := fakeClaudeHookTmuxProbe("$2\twork\t@5", clients, map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
		4103: cmuxClientEnvironment("62357", "33333333-3333-4333-8333-333333333333"),
		4104: cmuxClientEnvironment("61000", "44444444-4444-4444-8444-444444444444"),
	})
	route, ok := discoverClaudeHookTmuxRoute(getenv, probe)
	if !ok || route.surfaceID != "22222222-2222-4222-8222-222222222222" || route.clientTTY != "/dev/pts/4" {
		t.Fatalf("route = %+v ok=%v, want the client showing the pane", route, ok)
	}

	// With the pane in a background window, the grouped session's newer client wins.
	probe, _ = fakeClaudeHookTmuxProbe("$2\twork\t@7", clients, map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
		4103: cmuxClientEnvironment("62357", "33333333-3333-4333-8333-333333333333"),
		4104: cmuxClientEnvironment("61000", "44444444-4444-4444-8444-444444444444"),
	})
	route, ok = discoverClaudeHookTmuxRoute(getenv, probe)
	if !ok || route.surfaceID != "33333333-3333-4333-8333-333333333333" {
		t.Fatalf("route = %+v ok=%v, want the most recent client of the group", route, ok)
	}
}

// TestDiscoverClaudeHookTmuxRouteRequiresTmuxAndCmuxClient keeps hooks outside cmux-attached tmux sessions silent.
func TestDiscoverClaudeHookTmuxRouteRequiresTmuxAndCmuxClient(t *testing.T) {
	environments := map[int]map[string]string{4102: {"CMUX_SOCKET_PATH": "127.0.0.1:1", "CMUX_WORKSPACE_ID": "w"}}
	probe, calls := fakeClaudeHookTmuxProbe("$2\t\t@1", "4102\t/dev/pts/4\t1\t$2\t\t@1\n", environments)
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

// TestDiscoverClaudeHookTmuxRouteLogsWhyItFoundNoRoute records each reason a tmux route fails, such as a client environment the host would not show.
func TestDiscoverClaudeHookTmuxRouteLogsWhyItFoundNoRoute(t *testing.T) {
	inTmux := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-501/default,100,0"})
	var logged []string
	logf := func(format string, args ...any) { logged = append(logged, fmt.Sprintf(format, args...)) }
	probe, _ := fakeClaudeHookTmuxProbe("$2\t\t@1", "4102\t/dev/ttys004\t1\t$2\t\t@1\n4103\t/dev/ttys005\t2\t$2\t\t@1\n", map[int]map[string]string{
		4102: {"TERM": "xterm-ghostty"},
	})
	probe.logf = logf
	if _, ok := discoverClaudeHookTmuxRoute(inTmux, probe); ok {
		t.Fatal("no client carries a surface")
	}
	want := []string{
		"could not read the environment of tmux client pid 4103",
		"none of 2 tmux clients of session $2 carries a cmux surface",
	}
	if !reflect.DeepEqual(logged, want) {
		t.Fatalf("logged %q, want %q", logged, want)
	}

	logged = nil
	probe, _ = fakeClaudeHookTmuxProbe("$9\t\t@1", "4102\t/dev/ttys004\t1\t$2\t\t@1\n", nil)
	probe.logf = logf
	if _, ok := discoverClaudeHookTmuxRoute(inTmux, probe); ok || len(logged) != 1 || logged[0] != "no tmux client is attached to session $9" {
		t.Fatalf("detached session: ok=%v logged %q", ok, logged)
	}
}

// TestResolveClaudeHookDeliveryFollowsTmuxClientWithoutEnvironment covers a launcher-started Claude in a tmux server that predates cmux.
func TestResolveClaudeHookDeliveryFollowsTmuxClientWithoutEnvironment(t *testing.T) {
	paneEnv := claudeHookTestEnv(map[string]string{"TMUX": "/tmp/tmux-1000/default,100,0", "TMUX_PANE": "%0"})
	probe, _ := fakeClaudeHookTmuxProbe("$0\t\t@0", "4102\t/dev/pts/4\t1\t$0\t\t@0\n", map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
	})
	base := claudeHookDelivery{
		socketPath:  "127.0.0.1:62357", // ~/.cmux/socket_addr names another workspace's relay
		refreshAddr: func() string { return "127.0.0.1:62357" },
		getenv:      paneEnv,
		callerTTY:   func(string) string { return "/dev/pts/1" },
	}
	delivery, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), probe)
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
	wrapperDelivery, ok := resolveClaudeHookDelivery(base, false, 400, launcherTmuxProcessTree(), probe)
	if !ok {
		t.Fatal("wrapper hooks keep their socket")
	}
	if _, ok := claudeHookEnqueueParams("stop", []byte(`{}`), wrapperDelivery.getenv, wrapperDelivery.callerTTY); ok {
		t.Fatal("a wrapper hook without surface environment must not route")
	}
}

// TestResolveClaudeHookDeliveryStepsAsideForWrapperAndNestedSessions avoids double reports.
func TestResolveClaudeHookDeliveryStepsAsideForWrapperAndNestedSessions(t *testing.T) {
	probe, _ := fakeClaudeHookTmuxProbe("$0\t\t@0", "4102\t/dev/pts/4\t1\t$0\t\t@0\n", map[int]map[string]string{
		4102: cmuxClientEnvironment("63518", "22222222-2222-4222-8222-222222222222"),
	})
	values := map[string]string{
		"TMUX":              "/tmp/tmux-1000/default,100,0",
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
		"CMUX_SOCKET_PATH":  "127.0.0.1:63518",
	}
	values[claudeRelayWrapperActiveKey] = "1"
	values["CMUX_CLAUDE_PID"] = "300"
	base := claudeHookDelivery{socketPath: "127.0.0.1:63518", getenv: claudeHookTestEnv(values), callerTTY: func(string) string { return "" }}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), probe); ok {
		t.Fatal("installed hooks must step aside when the wrapper injected its own")
	}
	// A wrapped Claude that started the tmux server leaks the marker and its
	// PID into every pane; a different Claude there has no wrapper hooks.
	values["CMUX_CLAUDE_PID"] = "999"
	delivery, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), probe)
	if !ok {
		t.Fatal("an inherited wrapper marker must not silence another Claude")
	}
	if got := delivery.getenv("CMUX_CLAUDE_PID"); got != "300" {
		t.Fatalf("CMUX_CLAUDE_PID = %q, want the discovered Claude, not the leaked one", got)
	}
	delete(values, claudeRelayWrapperActiveKey)
	delete(values, "CMUX_CLAUDE_PID")
	if _, ok := resolveClaudeHookDelivery(base, true, 700, launcherTmuxProcessTree(), probe); ok {
		t.Fatal("installed hooks must not report a nested Claude session")
	}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), probe); !ok {
		t.Fatal("a top-level session with its own environment must route")
	}
}

// TestResolveClaudeHookDeliveryNeverUsesPaneEnvironmentInTmux: pane CMUX_*
// variables come from whichever shell started the tmux server, so without an
// attached cmux client the installed hook stays silent.
func TestResolveClaudeHookDeliveryNeverUsesPaneEnvironmentInTmux(t *testing.T) {
	probe, _ := fakeClaudeHookTmuxProbe("$1\t\t@1", "", nil)
	values := map[string]string{
		"TMUX":              "/tmp/tmux-1000/default,100,0",
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		"CMUX_SOCKET_PATH":  "127.0.0.1:63518",
	}
	base := claudeHookDelivery{socketPath: "127.0.0.1:63518", getenv: claudeHookTestEnv(values), callerTTY: func(string) string { return "" }}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), probe); ok {
		t.Fatal("a detached tmux session must not report to the server's original surface")
	}
}

// TestResolveClaudeHookDeliveryIgnoresSocketAddrOutsideTmux keeps surface IDs
// and relay from one environment: ~/.cmux/socket_addr may be another
// workspace's relay.
func TestResolveClaudeHookDeliveryIgnoresSocketAddrOutsideTmux(t *testing.T) {
	values := map[string]string{
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
	}
	base := claudeHookDelivery{
		socketPath:  "127.0.0.1:62357",
		refreshAddr: func() string { return "127.0.0.1:62357" },
		getenv:      claudeHookTestEnv(values),
		callerTTY:   func(string) string { return "" },
	}
	if _, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), claudeHookTmuxProbe{}); ok {
		t.Fatal("without CMUX_SOCKET_PATH the installed hook must not fall back to socket_addr")
	}
	values["CMUX_SOCKET_PATH"] = "127.0.0.1:63518"
	delivery, ok := resolveClaudeHookDelivery(base, true, 400, launcherTmuxProcessTree(), claudeHookTmuxProbe{})
	if !ok || delivery.socketPath != "127.0.0.1:63518" || delivery.refreshAddr != nil {
		t.Fatalf("delivery = %+v ok=%v, want the environment's own relay without refresh", delivery, ok)
	}
}

// TestClaudeHookRelayUserSettingsUsesSurfaceEnvironment runs the installed hook command shape end to end.
func TestClaudeHookRelayUserSettingsUsesSurfaceEnvironment(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("TMUX", "")
	t.Setenv("CMUX_SOCKET_PATH", sockPath)
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

// TestClaudeHookRelaySharesOneTimeBudget runs an installed hook against a hung
// tmux and a silent relay: routing and delivery together must finish within
// the hook's single budget, not one timeout each.
func TestClaudeHookRelaySharesOneTimeBudget(t *testing.T) {
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte("#!/bin/sh\nexec sleep 10\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			t.Cleanup(func() { conn.Close() })
		}
	}()
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TMUX", "/tmp/tmux-1000/default,100,0")
	t.Setenv("TMUX_PANE", "%0")
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	t.Setenv("CMUX_SURFACE_ID", "22222222-2222-4222-8222-222222222222")
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "")
	t.Setenv(claudeRelayWrapperActiveKey, "")
	t.Setenv("CMUX_RELAY_ID", "relay-test")
	t.Setenv("CMUX_RELAY_TOKEN", "00112233445566778899aabbccddeeff")
	home := t.TempDir()
	t.Setenv("HOME", home)
	previousTree, previousBudget := claudeRelayProcessTree, claudeHookTimeBudget
	claudeRelayProcessTree = fakeClaudeProcessTree{}
	claudeHookTimeBudget = 500 * time.Millisecond
	t.Cleanup(func() { claudeRelayProcessTree, claudeHookTimeBudget = previousTree, previousBudget })

	run := func() time.Duration {
		var stdout bytes.Buffer
		start := time.Now()
		code := runClaudeHookRelay(listener.Addr().String(), []string{claudeHookUserSettingsFlag, "stop"}, nil,
			strings.NewReader(`{"session_id":"s"}`), &stdout)
		if code != 0 || strings.TrimSpace(stdout.String()) != "{}" {
			t.Fatalf("exit %d stdout %q", code, stdout.String())
		}
		return time.Since(start)
	}
	// A hung tmux gives up inside the budget and routes nowhere.
	if elapsed := run(); elapsed > claudeHookTimeBudget+700*time.Millisecond {
		t.Fatalf("hung tmux: hook took %v, want at most about one %v budget", elapsed, claudeHookTimeBudget)
	}
	if log, _ := os.ReadFile(filepath.Join(home, ".cmux", "claude-hook.log")); !strings.Contains(string(log), "tmux display-message failed") {
		t.Fatalf("hung tmux was not logged: %q", log)
	}
	// A silent relay holds the hook for the rest of the same budget.
	t.Setenv("TMUX", "")
	t.Setenv("CMUX_SOCKET_PATH", listener.Addr().String())
	if elapsed := run(); elapsed < claudeHookTimeBudget || elapsed > claudeHookTimeBudget+700*time.Millisecond {
		t.Fatalf("silent relay: hook took %v, want about one %v budget", elapsed, claudeHookTimeBudget)
	}
	if log, _ := os.ReadFile(filepath.Join(home, ".cmux", "claude-hook.log")); !strings.Contains(string(log), "stop: relay "+listener.Addr().String()+" did not accept the event") {
		t.Fatalf("silent relay was not logged: %q", log)
	}
	if claudeHookDeclaredTimeout*time.Second-previousBudget < time.Second {
		t.Fatalf("budget %v leaves too little room under the declared %ds timeout", previousBudget, claudeHookDeclaredTimeout)
	}
}

// TestClaudeHookLiveRelayFollowsPersistentSlot covers a tmux client kept alive
// in a persistent remote terminal across a reconnect: its environment still
// names the old relay port, and the slot lease names the live one.
func TestClaudeHookLiveRelayFollowsPersistentSlot(t *testing.T) {
	relayDir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(relayDir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("52000.slot", "ssh-slot-a\n")
	write("52000.auth", `{"relay_id":"r","relay_token":"00"}`)
	write("53000.slot", "ssh-slot-b\n")
	write("53000.auth", `{"relay_id":"r","relay_token":"00"}`)
	tree := fakeClaudeProcessTree{
		10: {1, []string{"cmuxd-remote", "serve", "--persistent-server", "--slot", "ssh-slot-a", "--persistent-lease-port", "51000"}},
		11: {10, []string{"tmux", "attach-session", "-t", "=s"}},
	}
	if got := claudeHookLiveRelay("127.0.0.1:51000", 11, tree, relayDir); got != "127.0.0.1:52000" {
		t.Fatalf("relay = %q, want the live port leasing the client's slot", got)
	}
	// A live address is kept as is.
	if got := claudeHookLiveRelay("127.0.0.1:53000", 11, tree, relayDir); got != "127.0.0.1:53000" {
		t.Fatalf("relay = %q, want the live address unchanged", got)
	}
	// Without a slot above the client there is nothing to follow.
	if got := claudeHookLiveRelay("127.0.0.1:51000", 99, tree, relayDir); got != "127.0.0.1:51000" {
		t.Fatalf("relay = %q, want the original address", got)
	}
}
