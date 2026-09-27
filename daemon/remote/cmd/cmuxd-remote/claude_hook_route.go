package main

import (
	"bytes"
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
	claudeHookTmuxTimeout = time.Second
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

// procClaudeProcessTree reads /proc. Hosts without it report no processes,
// which only means the hook falls back to the environment it was given.
type procClaudeProcessTree struct{}

// parent reads the parent PID from /proc/<pid>/stat.
func (procClaudeProcessTree) parent(pid int) int {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0
	}
	// The command name can contain spaces and parentheses; fields resume
	// after the last ')': state, then ppid.
	closing := bytes.LastIndexByte(data, ')')
	if closing < 0 {
		return 0
	}
	fields := strings.Fields(string(data[closing+1:]))
	if len(fields) < 2 {
		return 0
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0
	}
	return parent
}

// argv reads the NUL-separated argv from /proc/<pid>/cmdline.
func (procClaudeProcessTree) argv(pid int) []string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
}

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
}

// defaultClaudeHookTmuxProbe runs the host's tmux with a short timeout and
// reads client environments from /proc.
func defaultClaudeHookTmuxProbe() claudeHookTmuxProbe {
	return claudeHookTmuxProbe{run: runClaudeHookTmux, environ: readProcEnviron}
}

// runClaudeHookTmux runs tmux against the server named by $TMUX.
func runClaudeHookTmux(args ...string) (string, error) {
	path, err := exec.LookPath("tmux")
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), claudeHookTmuxTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, path, args...).Output()
	return string(output), err
}

// readProcEnviron parses /proc/<pid>/environ. It is readable only for
// processes of the same user.
func readProcEnviron(pid int) map[string]string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "environ"))
	if err != nil {
		return nil
	}
	environment := map[string]string{}
	for _, entry := range strings.Split(string(data), "\x00") {
		if key, value, ok := strings.Cut(entry, "="); ok && key != "" {
			environment[key] = value
		}
	}
	return environment
}

// discoverClaudeHookTmuxRoute finds the cmux surface attached to the tmux
// session this hook runs in. The most recently active client that carries a
// complete cmux relay environment wins.
func discoverClaudeHookTmuxRoute(getenv func(string) string, probe claudeHookTmuxProbe) (claudeHookTmuxRoute, bool) {
	if strings.TrimSpace(getenv("TMUX")) == "" || probe.run == nil || probe.environ == nil {
		return claudeHookTmuxRoute{}, false
	}
	displayArgs := []string{"display-message", "-p"}
	if pane := strings.TrimSpace(getenv("TMUX_PANE")); pane != "" {
		displayArgs = append(displayArgs, "-t", pane)
	}
	sessionOutput, err := probe.run(append(displayArgs, "#{session_id}")...)
	sessionID := strings.TrimSpace(sessionOutput)
	if err != nil || sessionID == "" || strings.ContainsAny(sessionID, "\n\t") {
		return claudeHookTmuxRoute{}, false
	}
	clientOutput, err := probe.run("list-clients", "-t", sessionID, "-F", "#{client_pid}\t#{client_tty}\t#{client_activity}")
	if err != nil {
		return claudeHookTmuxRoute{}, false
	}
	type client struct {
		pid      int
		tty      string
		activity int64
	}
	var clients []client
	for _, line := range strings.Split(clientOutput, "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) != 3 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 1 {
			continue
		}
		activity, _ := strconv.ParseInt(fields[2], 10, 64)
		clients = append(clients, client{pid: pid, tty: fields[1], activity: activity})
	}
	sort.SliceStable(clients, func(i, j int) bool { return clients[i].activity > clients[j].activity })
	for _, candidate := range clients {
		environment := probe.environ(candidate.pid)
		route := claudeHookTmuxRoute{
			socketPath:  strings.TrimSpace(environment["CMUX_SOCKET_PATH"]),
			workspaceID: strings.TrimSpace(environment["CMUX_WORKSPACE_ID"]),
			surfaceID:   strings.TrimSpace(environment["CMUX_SURFACE_ID"]),
			clientTTY:   strings.TrimSpace(candidate.tty),
		}
		if route.socketPath != "" && route.workspaceID != "" && route.surfaceID != "" {
			return route, true
		}
	}
	return claudeHookTmuxRoute{}, false
}
