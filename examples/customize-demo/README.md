# The customization demo

Leo, 2026-11-18: "those are extremely lame customizations. we want to show the claude/codex/studio
ones. plus the previous ones that were made for the last demo, looking better. plus glass stuff. plus
the widgets. this is not enough as a demo"

Each setup here changes the whole window, live, from one profile file: a theme, the chrome, and views
of its own (a New Tab page, sidebar sections, Session Info cards). Nothing is on until you use it,
and one command puts your own setup back.

```sh
examples/customize-demo/demo.sh            # every setup in order, Enter for the next
examples/customize-demo/demo.sh --auto 12  # 12 s each, no keys (for a recording)
examples/customize-demo/demo.sh --list     # the order
examples/customize-demo/demo.sh reset      # your setup back
```

Or one at a time: `cmux customize use examples/customize-demo/looks/claude.json`, then
`cmux customize discard` (off) or `cmux customize apply` (keep it; `rollback` takes it off later).

| Part | Setups | What they show |
| --- | --- | --- |
| [App looks](looks) | `claude`, `codex`, `studio` | The window as the Claude app (clay accent, serif replies, Claude's home on every New Tab, usage in the sidebar, a Claude Code status line in Session Info), as the Codex app (white page, gray sidebar, threads by project, Codex's rate limits like `/status`), and a calm studio (thread list with status chips, a start page with one button per agent and every account's usage) |
| [The last demo, redone](last-demo) | `cockpit`, `collection`, `focus`, `tiling` | The showcase setups from the last demo (#44064, #44134), each now on glass over a painting with designed cards and pages |
| [Glass](glass) | `liquid`, `chrome`, `mica`, `tinted` | Native Liquid Glass and Mica through the theme file, no rebuild: clear glass over a painting, glass on the controls only, a frosted desktop, stained glass over the live desktop. [NOTES.md](glass/NOTES.md) says which part is native and which is CSS |
| [Widgets](widgets) | `widgets` | The time and weather, your agents at a glance, usage left on every Claude and Codex account, and your pull requests, in the sidebar, Session Info and on every New Tab. "Widgets" is our reading: nothing in cmux NEXT defines it as one surface yet ([README](widgets/README.md)) |

Each folder's `bundle.py` rebuilds its profile files from their sources (`--check` exits 1 while a
bundle is stale). `looks/check` previews any profile file on a fresh home and fails on a problem:

```sh
CARGO_TARGET_DIR=/tmp/demo-check cargo run -q --manifest-path examples/customize-demo/looks/check/Cargo.toml -- \
  examples/customize-demo/*/*.json
```

One setup at a time: each brings its own `local/customize` app, so the next one replaces its views.
Views that read the network or run actions say which scope to turn on in Settings > Apps.

`record-steps.py` writes the same order as a hot-verify steps file, for a recording in a copy of
NIGHTLY (`cmux-ci hot-verify PR --look --video --state FILE`).
