---
name: cmux-extension-author
description: "Write a cmux NEXT extension: a sidebar section, a live section on a signal, a Session Info section, a pane, a New Tab page, a widget, a command (palette, CLI and agent tool), or a composer slash command or @ mention. The loop is cmux ext new, cmux ext dev --once --json, read the result, fix, repeat; one recipe page per kind, each validated in CI."
---

# Write a cmux extension

An extension is a folder: `cmux-app.json` (what it is, where it shows, the scopes it asks for)
and, for a view or a command, `src/main.ts` on `cmux-extension-sdk`. `cmux ext dev` loads the
folder into the running cmux and reloads it on every save. This skill extends
[cmux-customization](../cmux-customization/SKILL.md), which owns the person's own
`~/.config/cmux/customize` app and `cmux-next.json`; use this one for an extension of its own.

## The loop

1. `cmux ext new NAME --kind sidebar|session-info|pane|newtab|widget|command` makes a working
   folder (with `sdk/`, types and `DESIGN.md`); or copy a recipe below into an empty folder.
2. Edit `src/main.ts` or `cmux-app.json`.
3. `cmux ext dev --once --json`: validate, build, load, render once. Read `exitCode`, `errors`
   (file, line, field) and `scene` (an outline of what rendered). Exit 0 is done; 4 is the
   manifest, 5 the build, 1 the load, 3 no cmux running.
4. Fix what `errors` names; repeat. Before saying it works, `cmux ext shot --json` and look at
   `shot.path`.

The whole loop, exit codes and sharing: `docs/cmux-next/extensions/dev-loop.md`.

## Recipes

One page per kind, each a folder you can copy as written, ending with the `cmux ext dev` line
that proves it. Each page's files are checked in CI against the validator cmux runs
(`cmux-tui/crates/cmux-app-manifest/tests/recipes.rs`) and, with bun, loaded and rendered by the
real app host (`cmux-tui/crates/cmux-tui/src/cli/ext/recipes_tests.rs`).

| Make | Recipe | Interface |
| --- | --- | --- |
| A sidebar section | [section.md](recipes/section.md) | `cmux.section/1` |
| A section on live data, no timer | [live-section.md](recipes/live-section.md) | `cmux.section/1` + `cmux.watch` |
| A section in a chat's Session Info | [session-info.md](recipes/session-info.md) | `cmux.session.info.section/1` |
| A view in a tab | [pane.md](recipes/pane.md) | `cmux.pane/1` |
| A whole New Tab page | [newtab.md](recipes/newtab.md) | `cmux.newtab/1` |
| A widget (New Tab grid, sidebar) | [widget.md](recipes/widget.md) | `cmux.widget/1` |
| A command: palette, `cmux NAME ...`, agent tool | [command.md](recipes/command.md) | `catalog.json` |
| A `/` command in the agent composer | [composer-command.md](recipes/composer-command.md) | `cmux.composer.command/1` |
| An `@` mention provider | [composer-mention.md](recipes/composer-mention.md) | `cmux.composer.mention/1` |

Every interface and its options: `cmux-tui/crates/cmux-app-host/interfaces/` (one
`<name>/<major>.json` each; see its README). Every op with its scope:
`cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts`. The SDK:
`cmux-tui/crates/cmux-extension-sdk/README.md`. Bigger working examples:
`examples/extensions/` (`activity` is built only on the SDK).

Not yet worth building: `cmux.status/1` and `cmux.chat.widget/1` validate but cmux does not
draw them yet; `--kind menu` is refused until `cmux.context_menu/1` lands.

## Do not

- **No per-frame work.** No `cmux.timer.every` to redraw or poll; repeating timers are floored
  at 1 s anyway. Time comes from a widget's `ctx.now()`; data from `cmux.watch(name)` or the
  SDK's `workspaces()`, `agents()`, `chats()`, which cmux reads once, caches and pushes.
- **No raw sizes or colors.** Use the kit (`Panel`, `Row`, `Button`, `EmptyState`, the widget
  helpers) and `cmux.theme` tones; follow the folder's `DESIGN.md`.
- **No focus, placement or navigation of your own.** A view cannot take focus or place itself;
  actions run from a click (`cmux.actions.run`, scope `actions:run`, which the person turns on).
- **No network or file access you did not declare.** `cmux.net.fetch` needs `net:<host>` in
  `scopes`; read scopes are granted at install, the rest the person turns on.
- **Do not skip the proof.** A recipe or a change is done when `cmux ext dev --once --json`
  exits 0 and the `scene` shows what you meant.

## The cold-model test

`scripts/cmux-next/ext-recipe-cold-model.py` gives each recipe page to a small model (Haiku) in
a fresh folder and checks its result with `cmux ext dev --once --json`. A recipe a small model
fails is a docs bug or an API bug. It is opt-in: it needs `claude` and a running cmux.
