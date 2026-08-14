package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

// turnVisibleHookEvents are the events a user would notice if they went
// missing. Only they need the empty-stdout failure contract below; the rest are
// acked so a routine tool call never surfaces a hook failure to the agent.
var turnVisibleHookEvents = map[string]struct{}{
	"stop":         {},
	"notification": {},
}

// runHooksRelay implements `cmux hooks <agent> <event>` on a remote host by
// forwarding the invocation to the Mac, which runs its own bundled CLI.
//
// The agent runs here, but the hook behaviors -- session registration, status
// transitions, the blocking permission decision, auto-naming -- are implemented
// in the macOS Swift CLI, which does not exist on this host. Reimplementing
// them here would fork that logic into a second language and let the two drift.
// Forwarding instead means every hook behaves identically whether the agent is
// local or across the relay, because it is literally the same executable.
//
// The surface is identified by the token the launch wrapper announced over the
// terminal stream: the environment here carries no surface identity, since
// shell integration clears CMUX_SURFACE_ID inside tmux and it never survives
// SSH.
//
// Output contract the wrapper's dispatch script depends on: stdout carries the
// hook's JSON response, and EMPTY stdout means delivery did not happen, which
// is its cue to write an OSC 777 notification straight to the terminal. So a
// turn-visible event that could not be delivered must print nothing at all
// rather than a bare ack.
func runHooksRelay(socketPath string, args []string, refreshAddr func() string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "cmux hooks: usage: cmux hooks <agent> <event>")
		return 2
	}
	agent := strings.TrimSpace(args[0])
	if agent == "feed" {
		return runFeedHookRelay(socketPath, args[1:], refreshAddr)
	}
	event := strings.TrimSpace(args[1])
	_, isVisible := turnVisibleHookEvents[event]

	// Claude Code delivers each hook's payload on stdin; the CLI on the far
	// side expects to read the same bytes.
	var stdinPayload string
	if data, err := io.ReadAll(os.Stdin); err == nil {
		stdinPayload = string(data)
	}

	token := strings.TrimSpace(os.Getenv("CMUX_AGENT_HOOK_TOKEN"))
	if token == "" {
		// Nothing announced this launch, so no surface can be proven. Guessing
		// would deliver a background agent's turn onto whatever pane happens to
		// be focused, which is what the announcement exists to prevent.
		return hookRelayFailure(isVisible)
	}

	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}
	result, err := rc.call("agent.hook.run", map[string]any{
		"token": token,
		"agent": agent,
		"event": event,
		"stdin": stdinPayload,
	})
	if err != nil {
		maybeReannounceAgentIdentity(err, token)
		return hookRelayFailure(isVisible)
	}

	stdout, _ := result["stdout"].(string)
	if strings.TrimSpace(stdout) == "" {
		return hookRelayFailure(isVisible)
	}
	fmt.Print(stdout)
	if !strings.HasSuffix(stdout, "\n") {
		fmt.Println()
	}
	return 0
}

// feedSourceFromArgs extracts the --source value from a
// `cmux hooks feed --source <agent>` invocation's trailing arguments,
// last occurrence winning, or "" when absent.
func feedSourceFromArgs(args []string) string {
	source := ""
	for i := 0; i+1 < len(args); i++ {
		if strings.TrimSpace(args[i]) == "--source" {
			source = strings.TrimSpace(args[i+1])
		}
	}
	return source
}

// relayErrorIndicatesBindingGone reports whether an agent.hook.run error means
// the Mac has no live binding for the announced token — the one failure a
// re-announcement can repair. Transport failures must not re-announce: the
// terminal write would land, but nothing is listening on the other end and
// the binding may be perfectly healthy.
func relayErrorIndicatesBindingGone(err error) bool {
	return err != nil && strings.Contains(err.Error(), "not_found")
}

// maybeReannounceAgentIdentity re-emits the OSC 777 identity announcement for
// token on this process's controlling terminal when the Mac reports the
// binding gone (not_found). The launch wrapper announces only once, so a
// binding dies whenever the app restarts or the workspace that carried the
// announcement closes while the agent keeps running in tmux. Rewriting the
// announcement onto the CURRENT stream rebinds the token to whichever surface
// now displays this pane — the registry's documented "newest stream wins"
// refresh — so the agent's next hook resolves again without a relaunch.
func maybeReannounceAgentIdentity(err error, token string) {
	if token == "" || !relayErrorIndicatesBindingGone(err) {
		return
	}
	tty, openErr := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if openErr != nil {
		return
	}
	defer tty.Close()
	if os.Getenv("TMUX") != "" {
		// Passthrough must be on for tmux to forward the wrapped sequence;
		// the wrapper enables it at launch, but a tmux server restarted since
		// then would have lost it.
		_ = exec.Command("tmux", "set", "-g", "allow-passthrough", "on").Run()
		fmt.Fprintf(tty, "\x1bPtmux;\x1b\x1b]777;notify;%s;%s\x07\x1b\\", "cmux.agent.identity", token)
		return
	}
	fmt.Fprintf(tty, "\x1b]777;notify;%s;%s\x07", "cmux.agent.identity", token)
}

// hookRelayFailure keeps the empty-stdout contract: a turn-visible event that
// failed prints nothing so the caller falls back to OSC, while a routine event
// acks so the agent does not see a hook failure on every tool call.
func hookRelayFailure(isVisible bool) int {
	if isVisible {
		return 1
	}
	fmt.Println("{}")
	return 0
}

// callAgentHookRun performs one agent.hook.run round trip with a caller-chosen
// read deadline (rpcContext.call is fixed at the 15s default, which is too
// short for the blocking permission lane).
func callAgentHookRun(socketPath string, refreshAddr func() string, timeout time.Duration, params map[string]any) (map[string]any, error) {
	resp, err := socketRoundTripV2Deadline(socketPath, "agent.hook.run", params, refreshAddr, timeout)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		return nil, err
	}
	return result, nil
}

// feedHookTimeout bounds the feed hook's round trip. The feed lane carries
// PermissionRequest, which legitimately blocks until the user answers (the
// wrapper installs it with a 125s hook timeout, and the Mac's agent.hook.run
// lane allows 130s), so the default 15s socket deadline would cut every
// permission prompt short.
const feedHookTimeout = 130 * time.Second

// runFeedHookRelay forwards `cmux hooks feed --source <agent>` — the
// feed/permission lane — to the Mac. The source travels in agent.hook.run's
// `event` parameter so the RPC shape stays unchanged; the far side rebuilds
// the argv from an allowlist, exactly as it does for `hooks claude <event>`.
//
// A feed event that cannot be delivered acks with "{}" rather than failing:
// Claude treats an empty hook decision as "no opinion", so a PermissionRequest
// falls back to Claude's own terminal prompt and a Stop-feed update is simply
// lost — neither may surface an error into the agent's turn.
func runFeedHookRelay(socketPath string, args []string, refreshAddr func() string) int {
	source := feedSourceFromArgs(args)
	if source == "" {
		fmt.Fprintln(os.Stderr, "cmux hooks feed: usage: cmux hooks feed --source <agent>")
		return 2
	}

	var stdinPayload string
	if data, err := io.ReadAll(os.Stdin); err == nil {
		stdinPayload = string(data)
	}

	token := strings.TrimSpace(os.Getenv("CMUX_AGENT_HOOK_TOKEN"))
	if token == "" {
		return hookRelayFailure(false)
	}

	result, err := callAgentHookRun(socketPath, refreshAddr, feedHookTimeout, map[string]any{
		"token": token,
		"agent": "feed",
		"event": source,
		"stdin": stdinPayload,
	})
	if err != nil {
		maybeReannounceAgentIdentity(err, token)
		return hookRelayFailure(false)
	}
	stdout, _ := result["stdout"].(string)
	if strings.TrimSpace(stdout) == "" {
		return hookRelayFailure(false)
	}
	fmt.Print(stdout)
	if !strings.HasSuffix(stdout, "\n") {
		fmt.Println()
	}
	return 0
}
