# tmux Corpus Port Map

Pinned upstream tmux commit: `a9ba7b8ecbe1d107aa716f52d53c99ea1a00cf11`.

This map records how each selected upstream tmux regression or fuzz target is represented in cmux. It is documentation only; CI confidence comes from executable Go tests, Go fuzz targets, and the macOS terminal-renderer tests in `.github/workflows/tmux-corpus.yml`. The daemon and tmux-compat rows marked `pr` run on pull requests touching `daemon/remote/**`; the terminal-renderer rows remain nightly because they need the macOS app and GhosttyKit.

| Upstream source | cmux layer | Status | CI lane | Port note |
| --- | --- | --- | --- | --- |
| `regress/am-terminal.sh` | terminal-renderer | adapted | nightly | Autowrap belongs to Ghostty/cmux rendering. |
| `regress/border-arrows.sh` | tmux-ui | not_applicable | none | cmux does not expose tmux border arrow indicators. |
| `regress/capture-pane-hyperlink.sh` | terminal-renderer | adapted | nightly | OSC 8 hyperlink capture should preserve Ghostty behavior. |
| `regress/capture-pane-sgr0.sh` | terminal-renderer | adapted | nightly | SGR reset semantics belong to terminal rendering and replay. |
| `regress/combine-test.sh` | terminal-renderer | adapted | nightly | Unicode combining width belongs to Ghostty/cmux rendering. |
| `regress/command-order.sh` | tmux-compat | ported | pr | Command splitting and sequential dispatch are covered. |
| `regress/conf-syntax.sh` | tmux-config | not_applicable | none | cmux does not parse tmux config files. |
| `regress/control-client-sanity.sh` | tmux-compat | adapted | pr | cmux exposes JSON-RPC and tmux-compat commands instead of tmux control mode. |
| `regress/control-client-size.sh` | remote-pty | ported | pr | WebSocket PTY resize control frames are covered. |
| `regress/copy-mode-test-emacs.sh` | tmux-copy-mode | not_applicable | none | cmux does not implement tmux copy-mode key tables. |
| `regress/copy-mode-test-vi.sh` | tmux-copy-mode | not_applicable | none | cmux does not implement tmux copy-mode key tables. |
| `regress/cursor-test1.sh` | terminal-renderer | adapted | nightly | Cursor wrapping and reflow belong to terminal rendering. |
| `regress/cursor-test2.sh` | terminal-renderer | adapted | nightly | Cursor wrapping and reflow belong to terminal rendering. |
| `regress/cursor-test3.sh` | terminal-renderer | adapted | nightly | Cursor wrapping and reflow belong to terminal rendering. |
| `regress/cursor-test4.sh` | terminal-renderer | adapted | nightly | Cursor wrapping and reflow belong to terminal rendering. |
| `regress/decrqm-sync.sh` | terminal-renderer | adapted | nightly | Synchronized output mode belongs to terminal rendering. |
| `regress/format-strings.sh` | tmux-compat | adapted | pr | cmux supports a deliberate tmux format subset for agent shims. |
| `regress/has-session-return.sh` | tmux-compat | ported | pr | has-session success and failure are covered through workspace resolution. |
| `regress/if-shell-TERM.sh` | tmux-shell | not_applicable | none | cmux does not implement tmux if-shell. |
| `regress/if-shell-error.sh` | tmux-shell | not_applicable | none | cmux does not implement tmux if-shell. |
| `regress/if-shell-nested.sh` | tmux-shell | not_applicable | none | cmux does not implement tmux if-shell. |
| `regress/input-keys.sh` | tmux-compat | ported | pr | send-keys token translation and literal passthrough are covered. |
| `regress/kill-session-process-exit.sh` | remote-pty | adapted | pr | PTY process exit closes the WebSocket session normally. |
| `regress/new-session-base-index.sh` | tmux-indexing | not_applicable | none | cmux workspace numbering is not tmux base-index configurable. |
| `regress/new-session-command.sh` | tmux-compat | ported | pr | new-session command dispatch to the first surface is covered. |
| `regress/new-session-environment.sh` | remote-pty | ported | pr | WebSocket PTY startup environment covers UTF-8 and truecolor identity. |
| `regress/new-session-no-client.sh` | tmux-compat | adapted | pr | Detached creation is represented by focus=false workspace creation. |
| `regress/new-session-size.sh` | remote-pty | ported | pr | Initial PTY rows and columns are covered through stty output. |
| `regress/new-window-command.sh` | tmux-compat | ported | pr | new-window command dispatch is covered through workspace creation and surface input. |
| `regress/osc-11colours.sh` | terminal-renderer | adapted | nightly | cmux should preserve Ghostty truecolor behavior instead of tmux default color assumptions. |
| `regress/run-shell-output.sh` | tmux-shell | not_applicable | none | cmux does not implement tmux run-shell. |
| `regress/session-group-resize.sh` | remote-rpc | ported | pr | Smallest-client resize arbitration is covered in the remote session coordinator. |
| `regress/style-trim.sh` | tmux-status-style | not_applicable | none | cmux does not implement tmux status line style trimming. |
| `regress/tty-keys.sh` | terminal-input | adapted | nightly | OS key forwarding is covered in macOS terminal tests. |
| `regress/utf8-test.sh` | terminal-renderer | adapted | nightly | UTF-8 rendering belongs to Ghostty/cmux; Go covers UTF-8 env and byte-safe command paths. |
| `fuzz/cmd-parse-fuzzer.c` | tmux-compat | ported | nightly | Go fuzz covers supported tmux-compat argv parsing. |
| `fuzz/format-fuzzer.c` | tmux-compat | ported | nightly | Go fuzz covers supported format-string expansion. |
| `fuzz/input-fuzzer.c` | remote-pty | adapted | nightly | Go fuzz covers PTY control frames and send-keys tokens; full escape rendering remains in Ghostty. |
| `fuzz/style-fuzzer.c` | terminal-renderer | adapted | nightly | Style and color parsing belongs to Ghostty/cmux rendering, with better truecolor expectations. |
