# Remote-tmux testing

Two harnesses cover the remote-tmux mirror: the `RemoteTmuxSizingUITests` XCUITest suite and the live layout fuzz.

## Sizing UI suite

`cmuxUITests/RemoteTmuxSizingUITests` verifies the full sizing flow: a lab tmux server holding a zoo of layout shapes, a real attach through the app's ssh transport, and, after every window drag and tab click, the assertion that every pane renders the size tmux assigned it. The oracle is the `remote.tmux.pane_grids` debug socket verb (grid cells straight from the app), never screenshots.

### Running it

Hermetic (no network, no ssh config, no pre-existing tmux server, unique paths per run), so run it locally on every change and read red/green directly. Do not confuse it with the BrowserFixture socket suites, which fail locally by design.

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-uitest-dd \
  -only-testing:cmuxUITests/RemoteTmuxSizingUITests
```

Scope to one scenario while iterating with `-only-testing:cmuxUITests/RemoteTmuxSizingUITests/<testName>`. Requires a local `tmux` at `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, or `/usr/bin/tmux` (the exact paths the suite and the `test_exec` allowlist probe); it skips when none exists.

As a sandboxed agent, `xcodebuild` cannot run under the Bash-tool sandbox (its SwiftPM resolver's `sandbox-exec` dies with `Operation not permitted`). Run it outside the sandbox through the ssh hairpin, exactly like the build:

```bash
ssh cmux-srvA "zsh -lc 'cd <repo> && CMUX_SKIP_ZIG_BUILD=1 xcodebuild test \
  -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination platform=macOS -derivedDataPath /tmp/cmux-uitest-dd \
  -only-testing:cmuxUITests/RemoteTmuxSizingUITests/<testName>; echo EXIT=\$?'"
```

`CMUX_SKIP_ZIG_BUILD=1` skips the Ghostty CLI-helper script phase, which otherwise fails the run on its strict zig-version check (the same flag `reload.sh` uses). Reuse the warm `-derivedDataPath` and never `xcodebuild clean`: a wiped `Build/` forces SwiftPM re-resolution, which needs the same `sandbox-exec` and fails.

### Architecture

The XCUITest runner is sandboxed and the app under test is not, so the two processes have disjoint filesystem reach and the app owns everything:

- **Lab tmux server.** The runner never spawns tmux. Every `new-session` / `split-window` / `resize-pane` goes through `remote.tmux.test_exec`, a DEBUG-only socket verb running a tmux argv inside the app with the lab `TMUX_TMPDIR`.
- **ssh shim.** `scripts/remote-tmux-e2e-ssh-shim.sh` replaces `ssh` via `CMUX_REMOTE_TMUX_SSH_FOR_TESTING`. It strips ssh's option framing and runs the "remote" command locally, replicating the three behaviors the transport depends on: the remote shell re-splits the quoted command, a pty exists only under `-t`/`-tt` (`tmux -CC` needs one, one-shot probes must not get one because the app classifies probe failures by stderr text), and `-O check/exit` ControlMaster ops succeed.
- **Attach path.** `remote.tmux.window` (the `cmux ssh-tmux` entry point) mirrors the lab host in a dedicated, activated window; activation mounts the mirror views whose geometry feeds the client-size pushes.

### Oracle contract

Per settle check, every mirrored window must hold `base == pushed` (hidden tabs keep their claimed size and re-render when selected), and the selected window must additionally have panes satisfying the render contract: exact on the immediate parent split's axis, rendered >= assigned on the fill axis (a smaller render loses content, a larger one is background beyond the PTY). Stability (window size steady across samples) and coherence (top-row pane widths plus separators sum to the window width, via `test_exec` tmux queries) are asserted first.

### Debugging a red run

- **Shim suspicion:** `bash scripts/remote-tmux-e2e-ssh-shim-check.sh` exercises every ssh invocation shape the transport makes (master ops, one-shot probes with stderr classification, the `-tt` control stream with a live stdin dialogue, SIGTERM cleanup) in seconds.
- **Sizing suspicion:** failure messages carry the full `pane_grids` introspection: per-window `base`/`pushed`/`current_f`, `visible_for_sizing`, `container_pt`, and per-pane assigned vs rendered with the raw calibration sample. `pushed != current_f` on a visible window means a push trigger was missed; `base != pushed` means tmux never applied the request (or a co-attached client constrained it).
- **Fast live iteration:** replicate the scenario against a running tagged build outside the runner sandbox. Mirror a loopback host, resize the window through GUI automation, switch tabs with the `surface.focus` socket verb, and poll `remote.tmux.pane_grids` between steps. Iterations take seconds instead of a build cycle; codify anything it finds back into the suite.

## Live layout fuzz

The real app mirrors a real tmux server, driven with random layouts and churn and judged at settle by two oracles: sizing (claims, plans, and rendered grids agree and settle within budget) and content (each pane's `read-screen`, unwrapped, matches `tmux capture-pane -J`). Everything runs against a local fixture with no network and no MFA. Seeds are deterministic, so "seed 3, iteration 1" in a commit message is a complete repro recipe.

```bash
scripts/remote-tmux-fuzz-host.sh cmux-fuzzhost   # loopback-only sshd, isolated tmux
CMUX_TAG=<tag> scripts/remote-tmux-fuzz-marathon.sh cmux-fuzzhost [seeds] [iters]
scripts/remote-tmux-live-fuzz.sh cmux-fuzzhost <seed> <iters>   # replay one seed
```

Use the `cmux-fuzzhost` alias, never `cmux-srvA`/`cmux-srvB`. Those are the render-harness/interactive loopback aliases: their `/tmp/cmux-srv*` holds a live interactive tmux the fuzz harness refuses to clobber, and their tmux dir is not where the app's `ssh-tmux` connects, so the mirror comes up empty. The host script generates a loopback sshd whose logins land in an isolated `TMUX_TMPDIR` the harness owns and can freely create and kill.

Run on a quiet machine and treat load as part of the result: settle budgets are latency assertions, and a loaded box manufactures failures that read like code bugs. Launch in the background or a plain terminal and let it finish. Never run it inside a tmux session (the per-seed reset runs `tmux kill-server`, which inside tmux hits your default server), and do not kill the wrapper mid-run: that orphans the driver, which blocks the next run. Both scripts allow one driver at a time.

Setup failures and their fixes:

- `no workspace mirroring session 'fuzz'`: wrong host. Use `cmux-fuzzhost`.
- `refusing to kill an unowned lab`: a stale lab tmux from an aborted run or a manual `ssh cmux-fuzzhost` probe. Kill it scoped to that dir with `TMUX_TMPDIR=<host's fuzz tmux dir> tmux kill-server`, never a bare `kill-server`.
- `another fuzz driver (pid N) is running`: `pkill -9 -f remote-tmux-fuzz-marathon.sh; pkill -9 -f remote-tmux-live-fuzz.sh`, then remove the `cmux-fuzz-marathon.lock` directory under the temp root.
- ssh shows `REMOTE HOST IDENTIFICATION HAS CHANGED` or `no such identity`: the host script regenerated the sshd host key or relocated the client key. Run `ssh-keygen -R "[127.0.0.1]:<port>"` and confirm the alias's `IdentityFile` points at the key the script wrote.
