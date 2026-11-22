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
examples/customize-demo/demo.sh --nightly --auto 8  # all 76 looks in installed NIGHTLY, then revert
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

### Every customization we built, one at a time

Leo, 2026-11-22: "just go one at a time each". Each row is one `--only` step, in `--list` order.
The thirteen demo looks go past color: each theme's `density` sets the sidebar's width, its row and
tab corners and gaps, and each look picks its sidebar look and text size, the corner style,
whether the top right buttons and the tab bar's plus show always or on hover, and whether Session
Info pushes the chat or floats over it.

`gallery/` bundles every setup folder under [examples/looks](../looks) and the
[starters](../gallery) (`gallery/bundle.py`); `showcase/` bundles
[customize-showcase](../customize-showcase) and the [Leo collection](../customize/leo)
(`showcase/bundle.py`). Rebuild with `python3 examples/customize-demo/gallery/bundle.py` (or
`showcase/bundle.py`) after changing a source. A setup's `actions` and `extensions` come only with
`cmux setup install`; the preview applies its settings, theme files, keybindings, styles and views,
and `demo.sh` names what install would add.

| `--only` | From | Applied | What changes |
| --- | --- | --- | --- |
| `looks/claude.json` | [looks/claude](looks/claude) | yes | Claude app: clay accent, 288 pt sidebar, 10 pt tab and row corners, Claude sidebar look, Session Info pushes the chat |
| `looks/codex.json` | [looks/codex](looks/codex) | yes | Codex app: 300 pt sidebar, 14 pt tabs, 12 pt rows, larger sidebar text, top right buttons always, Session Info overlay |
| `looks/studio.json` | [looks/studio](looks/studio) | yes | Studio: compact, 232 pt sidebar, 3 pt corners, tight flush corners, 24 pt rows with no gap |
| `looks/hosts.json` | [looks/hosts](looks/hosts) | yes | Hosts rail: 320 pt sidebar, 8 pt corners, gooey flush corners, larger status dots |
| `last-demo/cockpit.json` | [last-demo](last-demo) | yes | Cockpit on glass, its own density, buttons and Session Info |
| `last-demo/collection.json` | [last-demo](last-demo) | yes | Collection on glass |
| `last-demo/focus.json` | [last-demo](last-demo) | yes | Focus on glass |
| `last-demo/tiling.json` | [last-demo](last-demo) | yes | Tiling on glass |
| `glass/chrome.json` | [glass](glass) | yes | Glass on the controls only |
| `glass/liquid.json` | [glass](glass) | yes | Clear Liquid Glass over a painting |
| `glass/mica.json` | [glass](glass) | yes | Frosted Mica desktop |
| `glass/tinted.json` | [glass](glass) | yes | Stained glass over the live desktop |
| `widgets/widgets.json` | [widgets](widgets) | yes | Time, weather, agents, usage and PRs; top right buttons and plus always, Session Info overlay |
| `gallery/material.json` | [looks/material](../looks/material) | yes | Material 3 gooey tabs: comfortable, 300 pt sidebar, 20 pt pill rows, 12 pt tabs, gooey tails into the pane, two tones |
| `gallery/shadcn.json` | [looks/shadcn](../looks/shadcn) | yes | shadcn/ui new-york neutral |
| `gallery/apple.json` | [looks/apple](../looks/apple) | yes | After Notes, Mail and Xcode |
| `gallery/codex-sidebar.json` | [looks/codex/sidebar](../looks/codex/sidebar) | yes | A Codex app sidebar, 340 pt |
| `gallery/codex-threads.json` | [looks/codex/threads](../looks/codex/threads) | yes | Agent chats as a threads section |
| `gallery/claude-code-sidebar.json` | [looks/claude-code/sidebar](../looks/claude-code/sidebar) | yes | 284 pt sidebar by project folder, nested sessions |
| `gallery/claude-code-session-recents.json` | [looks/claude-code/session-recents](../looks/claude-code/session-recents) | yes | Recents section with pins and archive |
| `gallery/claude-code-project-picker.json` | [looks/claude-code/project-picker](../looks/claude-code/project-picker) | yes | Folder picker beside the sidebar's plus |
| `gallery/claude-code-transcript.json` | [looks/claude-code/transcript](../looks/claude-code/transcript) | yes | 800 pt reply column, folded tools |
| `gallery/claude-code-composer.json` | [looks/claude-code/composer](../looks/claude-code/composer) | yes | Charcoal prompt field, context ring |
| `gallery/claude-code-session-worktree.json` | [looks/claude-code/session-worktree](../looks/claude-code/session-worktree) | yes | Worktrees in .claude/worktrees |
| `gallery/claude-code-whole.json` | [looks/claude-code/whole](../looks/claude-code/whole) | yes | The whole Claude Code look |
| `gallery/rex-whole.json` | [looks/rex/whole](../looks/rex/whole) | yes | The whole rex set |
| `gallery/hairline.json` | [looks/hairline](../looks/hairline) | yes | Hairline whole look |
| `gallery/basalt.json` | [looks/basalt](../looks/basalt) | yes | Dense agent-first editor look |
| `gallery/claude-code-agents.json` | [looks/claude-code/agents](../looks/claude-code/agents) | partly | Action `claude-code-agents` comes with install |
| `gallery/claude-code-cli.json` | [looks/claude-code/cli](../looks/claude-code/cli) | partly | Actions `claude-code-start`, `claude-code-resume` come with install |
| `gallery/claude-code-cloud.json` | [looks/claude-code/cloud](../looks/claude-code/cloud) | partly | Actions `claude-code-desktop-continue`, `claude-code-teleport` come with install |
| `gallery/claude-code-composer-controls.json` | [looks/claude-code/composer-controls](../looks/claude-code/composer-controls) | yes | Model picker and command menu keys |
| `gallery/claude-code-export.json` | [looks/claude-code/export](../looks/claude-code/export) | yes | Copy the chat as Markdown |
| `gallery/claude-code-inactive-archive.json` | [looks/claude-code/inactive-archive](../looks/claude-code/inactive-archive) | yes | Archive chats idle seven days |
| `gallery/claude-code-modes.json` | [looks/claude-code/modes](../looks/claude-code/modes) | partly | Action `claude-code-plan` comes with install |
| `gallery/claude-code-notification-levels.json` | [looks/claude-code/notification-levels](../looks/claude-code/notification-levels) | yes | Banners, badges, no task-complete alerts |
| `gallery/claude-code-side-question.json` | [looks/claude-code/side-question](../looks/claude-code/side-question) | yes | Side question on Command-Semicolon |
| `gallery/claude-code-transcript-width.json` | [looks/claude-code/transcript-width](../looks/claude-code/transcript-width) | yes | Narrow transcript, folded thoughts |
| `gallery/docket.json` | [looks/docket](../looks/docket) | yes | Issue-tracker look |
| `gallery/ember.json` | [looks/ember](../looks/ember) | yes | Keyboard-launcher look |
| `gallery/folio.json` | [looks/folio](../looks/folio) | yes | Docs-editor look |
| `gallery/hush.json` | [looks/hush](../looks/hush) | yes | Calm assistant-browser look |
| `gallery/kerf.json` | [looks/kerf](../looks/kerf) | yes | Fast native editor look |
| `gallery/linen.json` | [looks/linen](../looks/linen) | yes | Consumer chat app look |
| `gallery/paper.json` | [looks/paper](../looks/paper) | yes | Paper whole look |
| `gallery/prism.json` | [looks/prism](../looks/prism) | yes | Vertical-tab browser look |
| `gallery/rex-activity.json` | [looks/rex/activity](../looks/rex/activity) | yes | Activity view |
| `gallery/rex-appearance.json` | [looks/rex/appearance](../looks/rex/appearance) | yes | Three palettes, sidebar groups |
| `gallery/rex-hosts.json` | [looks/rex/hosts](../looks/rex/hosts) | yes | Hosts view |
| `gallery/rex-new-tab.json` | [looks/rex/new-tab](../looks/rex/new-tab) | yes | New Tab: terminal or a machine |
| `gallery/rex-palette.json` | [looks/rex/palette](../looks/rex/palette) | yes | Palette, tab picker, rename |
| `gallery/rex-pane-operations.json` | [looks/rex/pane-operations](../looks/rex/pane-operations) | yes | Pane operations |
| `gallery/rex-panes.json` | [looks/rex/panes](../looks/rex/panes) | yes | Splits, focus, swaps, zoom |
| `gallery/rex-preferences.json` | [looks/rex/preferences](../looks/rex/preferences) | yes | Larger sidebar rows, banners, Dock count |
| `gallery/rex-session-operations.json` | [looks/rex/session-operations](../looks/rex/session-operations) | yes | Workspace cycling, rename, close |
| `gallery/rex-session-picker.json` | [looks/rex/session-picker](../looks/rex/session-picker) | yes | Sessions view |
| `gallery/rex-tabs.json` | [looks/rex/tabs](../looks/rex/tabs) | yes | Tab navigation keys |
| `gallery/rex-terminal.json` | [looks/rex/terminal](../looks/rex/terminal) | yes | Terminal font, copy mode, find |
| `gallery/rex-toolbar.json` | [looks/rex/toolbar](../looks/rex/toolbar) | yes | Inset panes, top tabs, split and zoom buttons |
| `gallery/starter-actions-and-keys.json` | [gallery/actions-and-keys](../gallery/actions-and-keys) | partly | Keys apply; actions `starter-tests`, `starter-dev`, `starter-claude` come with install |
| `gallery/starter-chat-style.json` | [gallery/chat-style](../gallery/chat-style) | yes | Chat and Markdown type |
| `gallery/starter-sidebar-view.json` | [gallery/sidebar-view](../gallery/sidebar-view) | yes | A hover card view |
| `gallery/starter-theme-file.json` | [gallery/theme-file](../gallery/theme-file) | yes | The smallest theme file |
| `gallery/studio.json` | [looks/studio](../looks/studio) | yes | Studio whole look: Studio, Studio Light, Studio Ember |
| `gallery/tachyon.json` | [looks/tachyon](../looks/tachyon) | yes | Block-terminal look |
| `gallery/tandem.json` | [looks/tandem](../looks/tandem) | yes | Agent-workspace look |
| `showcase/cockpit.json` | [customize-showcase/cockpit](../customize-showcase/cockpit) | yes | Mission control, original |
| `showcase/collection.json` | [customize-showcase/collection](../customize-showcase/collection) | yes | The collection, original |
| `showcase/focus.json` | [customize-showcase/focus](../customize-showcase/focus) | yes | One thing at a time, original |
| `showcase/ide.json` | [customize-showcase/ide](../customize-showcase/ide) | yes | Vertical tabs, splits, editor shape |
| `showcase/leo-daylight.json` | [customize/leo](../customize/leo) | yes | Leo collection, light |
| `showcase/leo-dusk.json` | [customize/leo](../customize/leo) | yes | Leo collection, dusk |
| `showcase/leo-neon.json` | [customize/leo](../customize/leo) | yes | Leo collection, neon |
| `showcase/right-handed.json` | [customize-showcase/right-handed](../customize-showcase/right-handed) | yes | The window mirrored |
| `showcase/tiling.json` | [customize-showcase/tiling](../customize-showcase/tiling) | yes | Scrolling tiling, original |

Not a step yet: [gallery/thinking-dots](../gallery/thinking-dots) sets
`agentPane.display.thinking.glyph`, which cmux#47525 adds to the settings schema; until then a
preview refuses it. `gallery/bundle.py` holds it in `WAITING`, and `--check` fails once the schema
has the key until it is bundled, so it joins the demo when cmux#47525 lands.

Not a step yet: [looks/claude-code/open-in-editor](../looks/claude-code/open-in-editor) sets
`agentPane.links.openCitationsInEditor`, a row the schema keeps to you (`agent_settable: false`), so
`customize use` refuses the profile ("one only you can change"). Turn it on in Settings > Agent
chat. It is in `WAITING` too and joins the demo once a profile may set that row.

Not a step: [examples/extensions](../extensions) are store apps (`cmux app install`), not profiles;
the widgets look above shows the clock, weather, usage and PR views they offer.

Recorded in NIGHTLY, look by look: [VIDEO.md](VIDEO.md).

There are 76 profiles in the recording order. `check.py` fails if a look is missing from the
demo, a bundle is stale, a profile has no declared feature surface, a density token is not in the
Density Playground's catalog, a demo look leaves its sidebar, top right buttons or Session Info at
the defaults, or Claude, Codex, studio, hosts and Material share a tabs and sidebar shape:

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
Resets between profiles count against the 60-step limit, so every look needs its own state.
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
