# Tagged Builds

Tagged builds isolate app name, bundle ID, debug socket, and DerivedData path so multiple agents and the user's normal app do not collide.

First: a web or daemon change needs no build. `cmux app try .` copies the installed NIGHTLY and swaps your code
into the copy ([the loop](../../../CLAUDE.md#the-loop-use-it-first-then-test)); a tagged build is for a change
`scripts/cmux-next/hot-verify.py plan` says needs one (Swift signatures, resources, FFI Rust).

```bash
./scripts/reload.sh --tag <tag>
./scripts/reload.sh --tag <tag> --launch
./scripts/reload.sh --tag <tag> --build-only
```

cmux-next reads no web API origin, so `reload.sh` defaults to
`CMUX_DEV_BACKEND_MODE=local` and provisions no shared backend. An explicit
`CMUX_DEV_BACKEND_MODE` or `CMUX_DEV_BACKEND_URL` (the fleet passes one) still
wins. See [contributor setup](../../../CONTRIBUTING.md#getting-started).

A normal reload builds, then terminates the running app with the same tag; `--launch`
also opens the replacement. `--build-only` validates a separately staged bundle
without replacing the app or changing its daemon or tag state, then removes that
validation artifact. It cannot be combined with `--launch`.

For Release variants, `reloads.sh --tag <tag>` uses an isolated staging identity.
`reloadp.sh` uses the stable identity, and `reload2.sh --tag <tag>` also invokes
`reloadp.sh`; both are subject to the running-app restrictions below.

## The user's running cmux

The installed cmux (`/Applications/cmux.app`, bundle id `com.cmuxterm.app`, process `cmux`) holds the user's live agent sessions. Never quit, kill (`pkill -x cmux`, `killall cmux`), relaunch or profile it with `xctrace --launch` or Instruments, and never launch a locally built Release app or any other bundle that uses `com.cmuxterm.app` while it runs. To reproduce the user's state, copy their session into the tagged build instead of touching the running app. Profile only by attaching to a tagged build's pid.

`reloadp.sh` refuses to run while another stable-id cmux is running;
`reload.sh --bundle-id` accepts only `com.cmuxterm.app.debug.*` IDs. The app
itself has no single-instance guard, so never launch another bundle with the
stable ID. Never bypass these protections;
`CMUX_ALLOW_REPLACING_RUNNING_CMUX=1` is an override only the user may set.

## Prebuilt GhosttyKit

For prebuilt GhosttyKit, run `./scripts/download-prebuilt-ghosttykit.sh` (it verifies the pinned artifact), then use `CMUX_GHOSTTYKIT_PREPROVISIONED=1` with the tagged reload.

## Compile-only checks

Use the tagged `reload.sh --build-only` command above. Reuse the same tag to retain
its DerivedData cache; a new tag starts a cold build. Tags are lowercased and runs
of other characters become `-` (`Fix/ABC-1` becomes `fix-abc-1`).

An app build does not compile or execute the test targets; use the
[test verification guide](../../cmux-testing/references/local-vs-ci-validation.md#native-app-versus-test-compilation)
for those checks. For GhosttyKit source builds, follow the
[Ghostty workflow](../../cmux-ghostty/SKILL.md).

## App path links

A normal `reload.sh` build prints an `App path:` line with the absolute path to the built `.app`. Use it to confirm the tag built. Never put a `file://` URL, a raw `.app` or DerivedData path, or a `/tmp/cmux-<tag>/...` link in chat output.

## Tagged CLI and socket

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh app identify
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh workspace list
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh terminal current write --text $'echo ok\n'
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh terminal current screen read
```

`current` is the tagged app's focused terminal; pass a `term_…` id from `terminal list` when more than one is open.

The helper refuses to run without `CMUX_TAG`, targets the tag's socket (cmux NEXT: `~/.local/state/cmux/cmux-debug-<tag>.sock`, else `/tmp/cmux-debug-<tag>.sock`), uses the matching tagged CLI from DerivedData (or, for a fleet build restored with `publish-hq`, from `~/Library/Application Support/cmux/tag-app-cache`), scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, legacy workspace/surface/tab/panel IDs, cmuxd and mux sockets, every `CMUX_TUI_*` variable, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for that tag.

`/tmp/cmux-cli` points at the most recently reloaded build and can target the user's main app socket, so it is never safe for tagged dogfood.

## Quitting a tagged build ends its helpers

A shipped cmux keeps its terminal owner, acpmux, the Chief host and their shells and agents running
after a quit, so the next launch picks them up. A tagged build (`com.cmuxterm.app.debug.<tag>`, not the
`next` daily) does not: at launch it starts `cmux-tui __dev-reaper`, which waits for the app to exit
(Cmd-Q, the end-sessions quit, `reload.sh` replacing it, a crash) and then ends every process that names
`cmux DEV <tag>.app/`, every terminal holder or host owned by it, and their descendants. `reload.sh`
also ends the old build's tree before it replaces the bundle. Set `CMUX_DEV_KEEP_HELPERS=1` in the app's
environment (and for `reload.sh`) to keep them, to test that terminals survive a quit.

```bash
./scripts/dev-build.py list                  # every tag with a process here, its owner chat and verdict
./scripts/dev-build.py stop --tag <tag>      # quit the app, end its whole tree (--dry-run to preview)
./scripts/dev-build.py stop --all-idle       # every tag with only helpers left, or whose claiming chat closed
```

`reload.sh --tag <tag> --launch` run from an agent chat claims the tag for that chat
(`dev-build.py claim`), so `stop --all-idle` ends the build once the chat is closed. A running build
nobody claimed is left alone. `scripts/cmux-next/quit-leaves-no-helpers-live.py <tag> <app>` launches a
tagged build, ends it each way and checks that nothing of the tag is left.

## Daemon edits

A change to the cmux-tui daemon or acpmux needs no app reload. Swap the tagged session's daemon for the
new build and keep its terminals and agent sessions: `<new build>/cmux-tui --session cmux-app-<tag>
server restart`, and `<new build>/cmux-tui-acpmux daemon restart` for acpmux
([cmux-tui/AGENTS.md](../../../cmux-tui/AGENTS.md#daemon-edits-swap-the-running-daemon)). Quitting the
app ends that daemon (above) unless the app runs with `CMUX_DEV_KEEP_HELPERS=1`; with it, the next
`reload.sh` launch (also run with `CMUX_DEV_KEEP_HELPERS=1`) hands the session back to the daemon bundled
in the app, unless you bundle your build with `CMUX_NEXT_TUI_BIN=<path>`.

## Cleanup

Before launching a new tagged run, quit older tagged apps you started this session and remove their stale `/tmp` sockets. Remove derived data only when no active task needs it.
