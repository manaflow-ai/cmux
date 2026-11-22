# The customization demo

Leo, 2026-11-18: "those are extremely lame customizations. we want to show the claude/codex/studio
ones. plus the previous ones that were made for the last demo, looking better. plus glass stuff. plus
the widgets. this is not enough as a demo"

Each setup here changes the whole window, live, from one profile file: a theme, the chrome, and views
of its own (a New Tab page, sidebar sections, Session Info cards). Nothing is on until you use it,
and one command puts your own setup back.

```sh
examples/customize-demo/demo.sh --nightly --only looks/claude.json  # one look; Enter reverts
examples/customize-demo/demo.sh            # every setup in order, Enter for the next
examples/customize-demo/demo.sh --auto 12  # 12 s each, no keys (for a recording)
examples/customize-demo/demo.sh --nightly --auto 8  # all 13 looks in installed NIGHTLY, then revert
examples/customize-demo/demo.sh --list     # the order
examples/customize-demo/demo.sh reset      # your setup back
```

To show the looks one at a time, use `--only` with a path from `--list`. The selected look stays
on screen until Enter; then the script restores your setup. Run the next look only after that
reset completes. `--auto` is the optional unattended tour, with one look visible at a time.

`--nightly` selects `/Applications/cmux NIGHTLY.app` explicitly and clears inherited app socket
and customization-root overrides. It does not restart the app. `--only` and `--auto` can be combined.
The script checks for an existing preview, hand edits or try-on before changing anything; keep or
discard those changes first. Each look starts from your applied setup, so settings from the previous look cannot
leak into the next one. Normal completion, Ctrl-C, and command failures restore the applied setup;
a failed restore returns an error with the recovery command. This demo needs Python 3 for its
status check.

The demo's chat typography is sans-serif, including when the existing chat or Markdown reading
preset is serif. Each profile explicitly selects the system preset; leaving it unset otherwise
inherits the existing preset. Code fonts stay separate. Discard restores the
previous font settings along with the rest of the setup. The regression detector is
`webviews/test/customization-demo-fonts.test.ts`: it resolves every bundled profile over existing
serif settings and checks both prompt and reply measurement fonts.

Or one at a time: `cmux customize use examples/customize-demo/looks/claude.json`, then
`cmux customize discard` (off) or `cmux customize apply` (keep it; `rollback` takes it off later).

| Part | Setups | What they show |
| --- | --- | --- |
| [App looks](looks) | `claude`, `codex`, `hosts`, `studio` | The window as the Claude app (clay accent, Claude's home on every New Tab, usage in the sidebar, a Claude Code status line in Session Info), as the Codex app (white page, gray sidebar, threads by project, Codex's rate limits like `/status`), as a hosts/session rail (hosts grouped with live status and a session picker), and as a calm studio (thread list with status chips, a start page with one button per agent and every account's usage) |
| [The last demo, redone](last-demo) | `cockpit`, `collection`, `focus`, `tiling` | The showcase setups from the last demo (#44064, #44134), each now on glass over a painting with designed cards and pages |
| [Glass](glass) | `liquid`, `chrome`, `mica`, `tinted` | Native Liquid Glass and Mica through the theme file, no rebuild: clear glass over a painting, glass on the controls only, a frosted desktop, stained glass over the live desktop. [NOTES.md](glass/NOTES.md) says which part is native and which is CSS |
| [Widgets](widgets) | `widgets` | The time and weather, your agents at a glance, usage left on every Claude and Codex account (where the cmux shares its Usage app with views), and your pull requests, in the sidebar, Session Info and on every New Tab. "Widgets" is our reading: nothing in cmux NEXT defines it as one surface yet ([README](widgets/README.md)) |

Recorded in NIGHTLY, look by look: [VIDEO.md](VIDEO.md).

There are 13 profiles in the recording order. `check.py` fails if a profile is missing from the
demo or has no declared feature surface:

```sh
python3 examples/customize-demo/check.py
```

Each folder's `bundle.py` rebuilds its profile files from their sources (`--check` exits 1 while a
bundle is stale). `looks/check` previews any profile file on a fresh home and fails on a problem:

```sh
CARGO_TARGET_DIR=/tmp/demo-check cargo run -q --manifest-path examples/customize-demo/looks/check/Cargo.toml -- \
  examples/customize-demo/*/*.json
```

The Claude Code packages reuse the Claude demo’s New Tab, usage and status views. Install the [whole look](../looks/claude-code/whole) or pick the [sidebar](../looks/claude-code/sidebar), [project picker](../looks/claude-code/project-picker), [transcript](../looks/claude-code/transcript) or [composer](../looks/claude-code/composer) on its own.

One setup at a time: each brings its own `local/customize` app, so the next one replaces its views.
Views that read the network or run actions say which scope to turn on in Settings > Apps.

`record-steps.py` writes the same order for an isolated copy of the published NIGHTLY. The
capture has a fresh home and does not copy this checkout. Pass a **pushed full commit SHA**;
the steps fetch those profile files on the capture Mac and wait for the download to finish.
An examples-only PR has no web or daemon layer, so `hot-verify --look` can skip its capture.
Use the NIGHTLY capture route for these profiles:

```sh
python3 examples/customize-demo/record-steps.py --ref "$(git rev-parse HEAD)" \
  --output-dir /tmp/demo-states
cmux-ci capture --nightly latest --state /tmp/demo-states/looks-hosts.json
```

Every profile explicitly opens and focuses `newTab.page`, so its own start page appears even
when your default new tab is a terminal. The capture runner's action steps pass `focus: true`.
The directory contains one
state per look, each with a reset shot. Run each state once and retain its capture receipt.
The library status before and after is recorded too; `discard` resets
the profile, but does not turn off library overlays. Inspect those answers and every step's
`ok` result, as the runner continues after a failed step.
The default route queues on a fleet display worker through the controller from a lane VM;
it does not require a direct SSH route from the lane to the Mac.

For a short video **per look**, generate a state directory with `--video`. Each state records a
separately named clip. Use a new directory for each published head, so a receipt cannot be
mistaken for a capture of newer code. The runner limits each clip to
120 seconds and each state to 60 steps. A video records the whole display on an isolated fleet
lease, so inspect it for private content before posting it:

```sh
python3 examples/customize-demo/record-steps.py --ref "$(git rev-parse HEAD)" --video --hold 8 \
  --output-dir /tmp/demo-videos
cmux-ci capture --nightly latest --state /tmp/demo-videos/looks-claude.json --on fleet
```

Without `--output-dir`, stdout is one state; select a subset with repeated `--only` options.
Resets between profiles count against the 60-step limit, so all 13 need separate states.
Generating states does not record videos: each fleet capture must complete successfully before
its clip can be reviewed and linked in a PR.

`--root /absolute/path` uses profiles already staged on the capture Mac instead of downloading
them. Set `CMUX_AGENT_ID` to your session identity when the fleet capture asks for a lease owner.
These shots prove the New Tab and visible sidebar; feature verification also needs Session
Info, hover cards, and the actions and data sources each profile promises. The manifest check
and fixture renderer alone are not proof that those features work in NIGHTLY.

Hosts pages its host and session lists, so a large fleet does not exceed the app runtime's
execution budget. Previous/Next controls keep every host and session reachable; the picker
searches the whole inventory before paging. The regression suite reverses activity timestamps
to ensure hosts stay on the same page. Hosts are
ordered by name with This Mac first. The Hosts profile uses the thin sidebar rail; open its full
sidebar with `cmux action run toggleSidebar` to exercise the sidebar's own paging controls.
Sidebar session pagers use compact chevrons with `Previous sessions`/`Next sessions` help labels,
and a count that keeps its intrinsic width. In the sidebar, the pager sits below the host header
before its session rows, so it remains reachable in a short section.
The regression detector in
`looks/check/views.test.ts` mounts all four app looks and exercises Hosts with 100 and 3,000
sessions, navigation, search, and a shrinking inventory. To compare scene counts and fixture
render times before/after, set `DEMO_BEFORE_HOSTS` to a saved earlier Hosts `main.js` when running
that test in a separate process: the old source can fail at the runtime's node limit. Run the
regression suite without that variable; a known-broken baseline must not contaminate its verdict.
The fake scene store removes descendants with their parent, as required by the scene protocol;
`js/test/runtime.test.ts` detects stale subtree accounting after repeated list and dynamic-view
replacement. This fixture does not replace a NIGHTLY capture.
