package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

// The feed relay parses `cmux hooks feed --source <agent>` argv through the
// daemon's shared parseFlags helper; a parsing regression silently kills
// every remote permission prompt and feed update, so the accepted shapes are
// pinned here through the same call the relay makes.
func TestFeedRelaySourceParsing(t *testing.T) {
	parseSource := func(args []string) string {
		parsed, err := parseFlags(args, []string{"source"})
		if err != nil {
			return ""
		}
		return strings.TrimSpace(parsed.flags["source"])
	}
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"canonical", []string{"--source", "claude"}, "claude"},
		{"missing", []string{}, ""},
		{"surroundingArgs", []string{"--source", "claude", "extra"}, "claude"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := parseSource(tc.args); got != tc.want {
				t.Fatalf("source(%v) = %q, want %q", tc.args, got, tc.want)
			}
		})
	}
}

// Re-announcement must fire only for a dead binding (not_found), never for
// transport failures: re-announcing cannot repair an unreachable relay, and
// on a healthy binding it would be wasted terminal writes on every error.
func TestRelayErrorIndicatesBindingGone(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"bindingGone", errors.New("server error [not_found]: No surface announced this token"), true},
		{"surfaceGone", errors.New("server error [not_found]: Announced surface is gone"), true},
		{"connectionRefused", errors.New("failed to connect to 127.0.0.1:1: connection refused"), false},
		{"timeout", errors.New("failed to read response: i/o timeout"), false},
		{"otherServerError", errors.New("server error [invalid_params]: unsupported event"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := relayErrorIndicatesBindingGone(tc.err); got != tc.want {
				t.Fatalf("relayErrorIndicatesBindingGone(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

// The feed round trip must outlast the blocking PermissionRequest hook: the
// wrapper installs it with a 125s timeout and the Mac's agent.hook.run lane
// allows 130s, so a shorter socket deadline would cut every permission prompt
// short. Pinned so a refactor back to the 15s default fails loudly.
func TestFeedHookTimeoutCoversPermissionWait(t *testing.T) {
	if feedHookTimeout < 125*time.Second {
		t.Fatalf("feedHookTimeout = %v, must cover the 125s PermissionRequest hook timeout", feedHookTimeout)
	}
}

// Stop and notification are the only turn-visible events: their failure must
// print nothing (the dispatch script's cue to fall back to an OSC 777 write),
// while every other event acks so the agent never sees a hook failure.
func TestTurnVisibleHookEvents(t *testing.T) {
	for _, event := range []string{"stop", "notification"} {
		if _, ok := turnVisibleHookEvents[event]; !ok {
			t.Fatalf("%q must be turn-visible", event)
		}
	}
	for _, event := range []string{"session-start", "prompt-submit", "pre-tool-use", "session-end"} {
		if _, ok := turnVisibleHookEvents[event]; ok {
			t.Fatalf("%q must not be turn-visible", event)
		}
	}
}
