package main

import "testing"

const tmuxCorpusUpstreamCommit = "a9ba7b8ecbe1d107aa716f52d53c99ea1a00cf11"

type tmuxCorpusPortStatus string

const (
	tmuxCorpusPorted        tmuxCorpusPortStatus = "ported"
	tmuxCorpusAdapted       tmuxCorpusPortStatus = "adapted"
	tmuxCorpusNotApplicable tmuxCorpusPortStatus = "not_applicable"
)

type tmuxCorpusCILane string

const (
	tmuxCorpusLanePR      tmuxCorpusCILane = "pr"
	tmuxCorpusLaneNightly tmuxCorpusCILane = "nightly"
	tmuxCorpusLaneNone    tmuxCorpusCILane = "none"
)

type tmuxCorpusEntry struct {
	Source string
	Layer  string
	Status tmuxCorpusPortStatus
	Lane   tmuxCorpusCILane
	Reason string
}

var tmuxCorpusManifest = []tmuxCorpusEntry{
	{Source: "regress/am-terminal.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Autowrap belongs to Ghostty/cmux terminal rendering, not the Go remote daemon."},
	{Source: "regress/border-arrows.sh", Layer: "tmux-ui", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not expose tmux border arrow indicators."},
	{Source: "regress/capture-pane-hyperlink.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "OSC 8 hyperlink capture belongs to terminal rendering and should preserve Ghostty behavior."},
	{Source: "regress/capture-pane-sgr0.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "SGR reset semantics belong to terminal rendering and session replay."},
	{Source: "regress/combine-test.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Unicode combining width belongs to Ghostty/cmux terminal rendering."},
	{Source: "regress/command-order.sh", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "Command splitting and sequential dispatch are covered for the supported tmux-compat subset."},
	{Source: "regress/conf-syntax.sh", Layer: "tmux-config", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not parse tmux configuration files."},
	{Source: "regress/control-client-sanity.sh", Layer: "tmux-compat", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLanePR, Reason: "cmux exposes JSON-RPC and tmux-compat commands instead of tmux control mode."},
	{Source: "regress/control-client-size.sh", Layer: "remote-pty", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "WebSocket PTY resize control frames are covered."},
	{Source: "regress/copy-mode-test-emacs.sh", Layer: "tmux-copy-mode", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux copy-mode key tables."},
	{Source: "regress/copy-mode-test-vi.sh", Layer: "tmux-copy-mode", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux copy-mode key tables."},
	{Source: "regress/cursor-test1.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Cursor wrapping and reflow belong to terminal rendering."},
	{Source: "regress/cursor-test2.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Cursor wrapping and reflow belong to terminal rendering."},
	{Source: "regress/cursor-test3.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Cursor wrapping and reflow belong to terminal rendering."},
	{Source: "regress/cursor-test4.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Cursor wrapping and reflow belong to terminal rendering."},
	{Source: "regress/decrqm-sync.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Synchronized output mode belongs to terminal rendering."},
	{Source: "regress/format-strings.sh", Layer: "tmux-compat", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLanePR, Reason: "cmux supports a deliberate tmux format subset for agent shims."},
	{Source: "regress/has-session-return.sh", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "has-session success and failure are covered through workspace resolution."},
	{Source: "regress/if-shell-TERM.sh", Layer: "tmux-shell", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux if-shell."},
	{Source: "regress/if-shell-error.sh", Layer: "tmux-shell", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux if-shell."},
	{Source: "regress/if-shell-nested.sh", Layer: "tmux-shell", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux if-shell."},
	{Source: "regress/input-keys.sh", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "send-keys token translation and literal passthrough are covered."},
	{Source: "regress/kill-session-process-exit.sh", Layer: "remote-pty", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLanePR, Reason: "PTY process exit closes the WebSocket session normally."},
	{Source: "regress/new-session-base-index.sh", Layer: "tmux-indexing", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux workspace numbering is not tmux base-index configurable."},
	{Source: "regress/new-session-command.sh", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "new-session command dispatch to the first surface is covered."},
	{Source: "regress/new-session-environment.sh", Layer: "remote-pty", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "WebSocket PTY startup environment is covered, including UTF-8 and truecolor identity."},
	{Source: "regress/new-session-no-client.sh", Layer: "tmux-compat", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLanePR, Reason: "Detached creation is represented by focus=false workspace creation."},
	{Source: "regress/new-session-size.sh", Layer: "remote-pty", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "Initial PTY rows and columns are covered through stty output."},
	{Source: "regress/new-window-command.sh", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "new-window command dispatch is covered through workspace creation and surface input."},
	{Source: "regress/osc-11colours.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "cmux should preserve Ghostty truecolor behavior instead of tmux's poorer default color assumptions."},
	{Source: "regress/run-shell-output.sh", Layer: "tmux-shell", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux run-shell."},
	{Source: "regress/session-group-resize.sh", Layer: "remote-rpc", Status: tmuxCorpusPorted, Lane: tmuxCorpusLanePR, Reason: "Smallest-client resize arbitration is covered in the remote session coordinator."},
	{Source: "regress/style-trim.sh", Layer: "tmux-status-style", Status: tmuxCorpusNotApplicable, Lane: tmuxCorpusLaneNone, Reason: "cmux does not implement tmux status line style trimming."},
	{Source: "regress/tty-keys.sh", Layer: "terminal-input", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "OS key event forwarding is covered in macOS terminal tests, not the Go daemon."},
	{Source: "regress/utf8-test.sh", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "UTF-8 rendering belongs to Ghostty/cmux; Go covers UTF-8 environment and byte-safe command paths."},
	{Source: "fuzz/cmd-parse-fuzzer.c", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLaneNightly, Reason: "Go fuzz target covers supported tmux-compat argv parsing."},
	{Source: "fuzz/format-fuzzer.c", Layer: "tmux-compat", Status: tmuxCorpusPorted, Lane: tmuxCorpusLaneNightly, Reason: "Go fuzz target covers supported format-string expansion."},
	{Source: "fuzz/input-fuzzer.c", Layer: "remote-pty", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Go fuzz covers PTY control frames and send-keys tokens; full escape rendering remains in Ghostty."},
	{Source: "fuzz/style-fuzzer.c", Layer: "terminal-renderer", Status: tmuxCorpusAdapted, Lane: tmuxCorpusLaneNightly, Reason: "Style and color parsing belongs to Ghostty/cmux rendering, with better truecolor expectations than tmux defaults."},
}

func TestTmuxCorpusManifestCoversPinnedUpstreamTests(t *testing.T) {
	if tmuxCorpusUpstreamCommit == "" {
		t.Fatal("tmux corpus upstream commit must be pinned")
	}

	wantSources := []string{
		"regress/am-terminal.sh",
		"regress/border-arrows.sh",
		"regress/capture-pane-hyperlink.sh",
		"regress/capture-pane-sgr0.sh",
		"regress/combine-test.sh",
		"regress/command-order.sh",
		"regress/conf-syntax.sh",
		"regress/control-client-sanity.sh",
		"regress/control-client-size.sh",
		"regress/copy-mode-test-emacs.sh",
		"regress/copy-mode-test-vi.sh",
		"regress/cursor-test1.sh",
		"regress/cursor-test2.sh",
		"regress/cursor-test3.sh",
		"regress/cursor-test4.sh",
		"regress/decrqm-sync.sh",
		"regress/format-strings.sh",
		"regress/has-session-return.sh",
		"regress/if-shell-TERM.sh",
		"regress/if-shell-error.sh",
		"regress/if-shell-nested.sh",
		"regress/input-keys.sh",
		"regress/kill-session-process-exit.sh",
		"regress/new-session-base-index.sh",
		"regress/new-session-command.sh",
		"regress/new-session-environment.sh",
		"regress/new-session-no-client.sh",
		"regress/new-session-size.sh",
		"regress/new-window-command.sh",
		"regress/osc-11colours.sh",
		"regress/run-shell-output.sh",
		"regress/session-group-resize.sh",
		"regress/style-trim.sh",
		"regress/tty-keys.sh",
		"regress/utf8-test.sh",
		"fuzz/cmd-parse-fuzzer.c",
		"fuzz/format-fuzzer.c",
		"fuzz/input-fuzzer.c",
		"fuzz/style-fuzzer.c",
	}

	got := make(map[string]tmuxCorpusEntry, len(tmuxCorpusManifest))
	for _, entry := range tmuxCorpusManifest {
		if entry.Source == "" {
			t.Fatalf("manifest entry has empty source: %+v", entry)
		}
		if _, exists := got[entry.Source]; exists {
			t.Fatalf("duplicate manifest source %q", entry.Source)
		}
		got[entry.Source] = entry
		if entry.Layer == "" {
			t.Fatalf("%s has empty layer", entry.Source)
		}
		switch entry.Status {
		case tmuxCorpusPorted, tmuxCorpusAdapted, tmuxCorpusNotApplicable:
		default:
			t.Fatalf("%s has invalid status %q", entry.Source, entry.Status)
		}
		switch entry.Lane {
		case tmuxCorpusLanePR, tmuxCorpusLaneNightly, tmuxCorpusLaneNone:
		default:
			t.Fatalf("%s has invalid CI lane %q", entry.Source, entry.Lane)
		}
		if entry.Status == tmuxCorpusNotApplicable && entry.Lane != tmuxCorpusLaneNone {
			t.Fatalf("%s is not applicable but has CI lane %q", entry.Source, entry.Lane)
		}
		if entry.Status != tmuxCorpusNotApplicable && entry.Lane == tmuxCorpusLaneNone {
			t.Fatalf("%s is %q but has no CI lane", entry.Source, entry.Status)
		}
		if entry.Reason == "" {
			t.Fatalf("%s must explain its porting decision", entry.Source)
		}
	}

	for _, source := range wantSources {
		if _, ok := got[source]; !ok {
			t.Fatalf("pinned tmux corpus source %q is missing from manifest", source)
		}
	}
	if len(got) != len(wantSources) {
		t.Fatalf("manifest has %d entries, want %d", len(got), len(wantSources))
	}
}
