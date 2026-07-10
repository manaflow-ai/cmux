# Remote-tmux sizing e2e suite

`cmuxUITests/RemoteTmuxSizingUITests` verifies the full remote-tmux mirror
sizing flow end to end: a lab tmux server holding a zoo of layout shapes, a
real attach through the app's ssh transport, and — after every window drag
and tab click — the assertion that every pane renders the size tmux assigned
it. The oracle is the `remote.tmux.pane_grids` debug socket verb (grid cells
straight from the app), never screenshots.

## Running it

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-uitest-dd \
  -only-testing:cmuxUITests/RemoteTmuxSizingUITests
```

Requires a local `tmux` at one of `/opt/homebrew/bin/tmux`,
`/usr/local/bin/tmux`, or `/usr/bin/tmux` (the exact paths the suite — and
the `test_exec` allowlist — probe; the suite skips when none exists). The
suite is hermetic: no network, no ssh config, no pre-existing tmux server,
and every path it creates is unique per run.

## Architecture (why it is shaped this way)

The XCUITest RUNNER is sandboxed — it cannot create files in `/tmp` or spawn
a tmux server there — while the app under test is not. The two processes
have disjoint filesystem reach, so the app owns everything:

- **Lab tmux server.** The runner never spawns tmux. It drives every
  `new-session` / `split-window` / `resize-pane` through
  `remote.tmux.test_exec`, a DEBUG-only socket verb that runs a tmux argv
  inside the app with the lab `TMUX_TMPDIR`.
- **ssh shim.** `scripts/remote-tmux-e2e-ssh-shim.sh` replaces `ssh` via
  `CMUX_REMOTE_TMUX_SSH_FOR_TESTING`: it strips ssh's option framing and
  runs the "remote" command locally, replicating the three ssh behaviors the
  transport depends on — the remote shell re-splits the quoted command, a
  pty exists only under `-t`/`-tt` (`tmux -CC` needs one; one-shot probes
  must NOT get one, because the app classifies probe failures by stderr
  text), and `-O check/exit` ControlMaster ops succeed.
- **Attach path.** `remote.tmux.window` (the `cmux ssh-tmux` entry point)
  mirrors the lab host in a dedicated, activated window — activation mounts
  the mirror views, whose geometry feeds the client-size pushes.

## The oracle contract

Per settle check, EVERY mirrored window must hold `base == pushed` (hidden
tabs keep their claimed size and re-render when selected), and the SELECTED
window must additionally be present with panes that satisfy the render
contract — exact on the immediate parent split's axis, rendered ≥ assigned
on the fill axis (a smaller render loses content; a larger one is background
beyond the PTY). Stability (window size steady across samples) and coherence
(top-row pane widths + separators sum to the window width, via `test_exec`
tmux queries) are asserted first.

## Debugging a red run

- **Shim suspicion:** `bash scripts/remote-tmux-e2e-ssh-shim-check.sh`
  exercises the shim through every ssh invocation shape the transport makes
  (master ops, one-shot probes with stderr classification, the `-tt`
  control stream with a live stdin dialogue, SIGTERM cleanup) in seconds.
- **Sizing suspicion:** the failure messages carry the full `pane_grids`
  introspection — per-window `base`/`pushed`/`current_f`,
  `visible_for_sizing`, `container_pt`, and per-pane assigned vs rendered
  with the raw calibration sample. `pushed != current_f` on a visible window
  means a push trigger was missed; `base != pushed` means tmux never applied
  (or a co-attached client constrained) the request.
- **Fast live iteration:** the same scenario can be replicated against a
  running tagged build outside the runner sandbox — mirror a loopback host,
  resize the window with `osascript`/System Events, switch tabs with the
  `surface.focus` socket verb, and poll `remote.tmux.pane_grids` between
  steps. Iterations take seconds instead of a build cycle; codify anything
  it finds back into the suite.
