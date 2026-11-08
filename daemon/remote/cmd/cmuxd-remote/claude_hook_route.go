package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Hooks installed in Claude's user settings (`cmux claude-hook install`) run
// for every Claude session on the host, including ones whose environment
// never saw cmux: a tmux server started before cmux attached to it, or a
// launcher restarted by a supervisor. Those panes have no CMUX_* variables,
// but the tmux client that cmux runs to attach the session does. The hook
// finds that client and routes the event to its relay and surface.

// claudeHookUserSettingsFlag marks hook commands written into Claude's user
// settings. Those hooks step aside when the launch wrapper already injected
// its own, and for Claude sessions nested inside another one.
const claudeHookUserSettingsFlag = "--user-settings"

const (
	// Hook commands run through `sh -c`, which may or may not exec, so Claude
	// is at most a few hops above the hook process.
	claudeHookAgentSearchDepth  = 4
	claudeHookNestedSearchDepth = 32
)

// claudeProcessTree looks up a process's parent and argv.
type claudeProcessTree interface {
	parent(pid int) int
	argv(pid int) []string
}

// procClaudeProcessTree reads the host's process table: /proc on Linux,
// sysctl on macOS (claude_hook_proc_*.go). A process it cannot inspect
// reports parent 0 and no argv.
type procClaudeProcessTree struct{}

var claudeRelayProcessTree claudeProcessTree = procClaudeProcessTree{}

// claudeHookIsAgentArgv reports whether argv starts Claude Code: the `claude`
// launcher, the native versioned binary, or the npm package under node/bun.
func claudeHookIsAgentArgv(argv []string) bool {
	if len(argv) == 0 {
		return false
	}
	isClaudePath := func(word string) bool {
		return filepath.Base(word) == "claude" ||
			strings.Contains(word, "/claude/versions/") ||
			strings.Contains(word, "/@anthropic-ai/claude-code/")
	}
	if isClaudePath(argv[0]) {
		return true
	}
	switch filepath.Base(argv[0]) {
	case "node", "nodejs", "bun":
		return len(argv) > 1 && isClaudePath(argv[1])
	}
	return false
}

// claudeHookAgentProcess finds the Claude process that ran this hook, starting
// at the hook's parent. nested is true when another Claude process sits
// above it, as for `claude -p` run by an agent's tool call.
func claudeHookAgentProcess(hookParent int, tree claudeProcessTree) (pid int, nested bool) {
	current := hookParent
	for depth := 0; depth < claudeHookAgentSearchDepth && current > 1; depth++ {
		if claudeHookIsAgentArgv(tree.argv(current)) {
			pid = current
			break
		}
		current = tree.parent(current)
	}
	if pid == 0 {
		return 0, false
	}
	current = tree.parent(pid)
	for depth := 0; depth < claudeHookNestedSearchDepth && current > 1; depth++ {
		if claudeHookIsAgentArgv(tree.argv(current)) {
			return pid, true
		}
		current = tree.parent(current)
	}
	return pid, false
}

// claudeHookTmuxRoute is the cmux surface of the tmux client attached to the
// hook's tmux session.
type claudeHookTmuxRoute struct {
	socketPath  string
	workspaceID string
	surfaceID   string
	clientTTY   string
}

// claudeHookTmuxProbe runs tmux and reads a client's environment.
type claudeHookTmuxProbe struct {
	run     func(args ...string) (string, error)
	environ func(pid int) map[string]string
	// liveRelay maps a client's relay address to the one currently serving
	// its persistent slot; nil keeps the address.
	liveRelay func(socketPath string, clientPID int) string
	// logf records why no route was found; nil discards it.
	logf func(format string, args ...any)
}

func (probe claudeHookTmuxProbe) log(format string, args ...any) {
	if probe.logf != nil {
		probe.logf(format, args...)
	}
}

// defaultClaudeHookTmuxProbe runs the host's tmux under the hook's deadline
// and reads client environments from the process table.
func defaultClaudeHookTmuxProbe(deadline time.Time) claudeHookTmuxProbe {
	return claudeHookTmuxProbe{
		run:     func(args ...string) (string, error) { return runClaudeHookTmux(deadline, args...) },
		environ: readProcEnviron,
		logf:    logClaudeHookDrop,
		liveRelay: func(socketPath string, clientPID int) string {
			home, err := os.UserHomeDir()
			if err != nil || home == "" {
				return socketPath
			}
			return claudeHookLiveRelay(socketPath, clientPID, claudeRelayProcessTree, filepath.Join(home, ".cmux", "relay"))
		},
	}
}

// runClaudeHookTmux runs tmux against the server named by $TMUX. The command
// is killed at deadline, and its output pipes are abandoned shortly after in
// case a child of tmux still holds them.
func runClaudeHookTmux(deadline time.Time, args ...string) (string, error) {
	path, err := exec.LookPath("tmux")
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	command := exec.CommandContext(ctx, path, args...)
	command.WaitDelay = 100 * time.Millisecond
	output, err := command.Output()
	return string(output), err
}

// discoverClaudeHookTmuxRoute finds the cmux surface attached to the tmux
// session this hook runs in. Clients of the pane's session, or of a session
// grouped with it, are candidates. A client whose current window holds the
// pane is preferred, then the most recently active one; the first candidate
// that carries a complete cmux relay environment wins.
func discoverClaudeHookTmuxRoute(getenv func(string) string, probe claudeHookTmuxProbe) (claudeHookTmuxRoute, bool) {
	if strings.TrimSpace(getenv("TMUX")) == "" || probe.run == nil || probe.environ == nil {
		return claudeHookTmuxRoute{}, false
	}
	displayArgs := []string{"display-message", "-p"}
	if pane := strings.TrimSpace(getenv("TMUX_PANE")); pane != "" {
		displayArgs = append(displayArgs, "-t", pane)
	}
	paneOutput, err := probe.run(append(displayArgs, "#{session_id}\t#{session_group}\t#{window_id}")...)
	if err != nil {
		probe.log("tmux display-message failed: %v", err)
		return claudeHookTmuxRoute{}, false
	}
	paneLine := strings.TrimRight(paneOutput, "\n")
	paneFields := strings.Split(paneLine, "\t")
	if len(paneFields) != 3 || paneFields[0] == "" || strings.Contains(paneLine, "\n") {
		probe.log("tmux display-message returned %q", paneLine)
		return claudeHookTmuxRoute{}, false
	}
	paneSession, paneGroup, paneWindow := paneFields[0], paneFields[1], paneFields[2]
	clientOutput, err := probe.run("list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{client_activity}\t#{session_id}\t#{session_group}\t#{window_id}")
	if err != nil {
		probe.log("tmux list-clients failed: %v", err)
		return claudeHookTmuxRoute{}, false
	}
	type client struct {
		pid       int
		tty       string
		activity  int64
		showsPane bool
	}
	var clients []client
	for _, line := range strings.Split(clientOutput, "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) != 6 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 1 {
			continue
		}
		sameSession := fields[3] == paneSession || (paneGroup != "" && fields[4] == paneGroup)
		if !sameSession {
			continue
		}
		activity, _ := strconv.ParseInt(fields[2], 10, 64)
		clients = append(clients, client{pid: pid, tty: fields[1], activity: activity, showsPane: paneWindow != "" && fields[5] == paneWindow})
	}
	sort.SliceStable(clients, func(i, j int) bool {
		if clients[i].showsPane != clients[j].showsPane {
			return clients[i].showsPane
		}
		return clients[i].activity > clients[j].activity
	})
	if len(clients) == 0 {
		probe.log("no tmux client is attached to session %s", paneSession)
		return claudeHookTmuxRoute{}, false
	}
	for _, candidate := range clients {
		environment := probe.environ(candidate.pid)
		if environment == nil {
			probe.log("could not read the environment of tmux client pid %d", candidate.pid)
			continue
		}
		route := claudeHookTmuxRoute{
			socketPath:  strings.TrimSpace(environment["CMUX_SOCKET_PATH"]),
			workspaceID: strings.TrimSpace(environment["CMUX_WORKSPACE_ID"]),
			surfaceID:   strings.TrimSpace(environment["CMUX_SURFACE_ID"]),
			clientTTY:   strings.TrimSpace(candidate.tty),
		}
		if route.socketPath != "" && route.workspaceID != "" && route.surfaceID != "" {
			if probe.liveRelay != nil {
				route.socketPath = probe.liveRelay(route.socketPath, candidate.pid)
			}
			return route, true
		}
	}
	probe.log("none of %d tmux clients of session %s carries a cmux surface", len(clients), paneSession)
	return claudeHookTmuxRoute{}, false
}

// claudeHookLiveRelay returns the relay that serves a tmux client now. A
// client in a persistent remote terminal keeps the environment it started
// with, so after a reconnect its relay port can be gone. The persistent
// daemon above the client names its slot, and the relay directory records
// which live port (with an auth file) leases that slot.
func claudeHookLiveRelay(socketPath string, clientPID int, tree claudeProcessTree, relayDir string) string {
	host, port, ok := strings.Cut(socketPath, ":")
	if !ok || strings.HasPrefix(socketPath, "/") || port == "" {
		return socketPath
	}
	if _, err := os.Stat(filepath.Join(relayDir, port+".auth")); err == nil {
		return socketPath
	}
	slot := ""
	current := tree.parent(clientPID)
	for depth := 0; depth < claudeHookAgentSearchDepth && current > 1 && slot == ""; depth++ {
		argv := tree.argv(current)
		for index := 0; index+1 < len(argv); index++ {
			if argv[index] == "--slot" {
				slot = strings.TrimSpace(argv[index+1])
				break
			}
		}
		current = tree.parent(current)
	}
	if slot == "" {
		return socketPath
	}
	leases, _ := filepath.Glob(filepath.Join(relayDir, "*.slot"))
	best, bestTime := "", time.Time{}
	for _, lease := range leases {
		data, err := os.ReadFile(lease)
		if err != nil || strings.TrimSpace(string(data)) != slot {
			continue
		}
		livePort := strings.TrimSuffix(filepath.Base(lease), ".slot")
		if _, err := strconv.Atoi(livePort); err != nil {
			continue
		}
		info, err := os.Stat(filepath.Join(relayDir, livePort+".auth"))
		if err != nil || (best != "" && !info.ModTime().After(bestTime)) {
			continue
		}
		best, bestTime = livePort, info.ModTime()
	}
	if best == "" {
		return socketPath
	}
	return host + ":" + best
}
