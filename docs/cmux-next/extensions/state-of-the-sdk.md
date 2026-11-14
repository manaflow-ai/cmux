# What you can customize in cmux NEXT, and how (state of the API and SDK, 2026-11-14)

Leo, 2026-11-14: "for 3 its supposed to be customization in general likr our apis/sdks for people
who wanted to do whatever". Standing: customization and hot reload first; widgets are made by the
community, not bundled, so cmux ships the primitive and the recipe, not a widget set.

This page is the map: each way in, the files behind it, whether it reloads live, and what is still
missing. Design: `plans/cmux-next/extensibility-DESIGN.md` (rules R1-R7, steps) and cmuxterm-hq
`plans/cmux-next/extensions/DESIGN.md` (the platform: places, signals, slots, safe mode, registry).

## What works today

| Way in | How a person uses it | Implemented in | Live reload | Versioned |
| --- | --- | --- | --- | --- |
| Settings file | `~/.config/cmux/cmux-next.json`: `actions`, `commands`, `sidebar`, `shortcuts`, `ui`, `terminal`, `notifications`, `browser`, `agents`, `packs`; `cmux settings set/validate/reload-configuration` | `cmux-tui/crates/cmux-config` (`watch/` inotify and kqueue), schema `web/data/cmux.schema.json`, `schemas/settings/` | yes, on save; a bad value names file, line and column and the last good config stays | `schemaVersion` only |
| Your own views | `~/.config/cmux/customize/` (the `local/customize` app); `cmux customize save/use/generations/rollback` | `cmux-tui/crates/cmux-customize`, templates in `skills/cmux-customization/templates/` | yes, on save | 100 generations, portable profiles |
| Extensions (apps) | `cmux ext new NAME`, `cmux ext dev [--once --json]`, `cmux ext shot`, `cmux ext list/remove`; `cmux apps list/place/run/reload` | manifest v2 `cmux-tui/crates/cmux-app-host/schema/v2/`, validator `cmux-app-manifest`, sandboxed QuickJS host `cmux-app-host`, CLI `cmux-tui/src/cli/ext/` | yes: `ext dev` reloads one extension per save and keeps the last good version on a load error | interfaces carry a major (`cmux.section/1`); manifest `engines.cmux`; runtime `1.2.0` |
| Places an extension can draw | sidebar section (`cmux.section/1`), sidebar row decorations (`cmux.sidebar.rows/1`), hover cards, Session Info section, pane (`cmux.pane/1`, scene), palette scope, diff renderer and source, terminal backend | `cmux-app-host/interfaces/`, drawn natively (`CmuxNextApps/Manifest/AppImplementation.swift`) or by the React `SceneRenderer` | yes | `/1` each, drafts until an outside app proves them |
| Live data | `cmux.watch("github.pulls" \| "workspace.list" \| "agent.list")`; `cmux.live(op)`; `cmux.events.on("workspace.changed" \| "pane.changed" \| "tab.changed" \| "terminal.changed" \| "agent.changed" \| "screen.changed")` | `schema/v2/signals.json`, `cmux-tui-core/src/apps/routing.rs` | pushed, cached, budgeted | signal names are drafts |
| Socket API and client SDKs | `cmux raw operation OP`, and the clients in TypeScript (npm `cmux-sdk` 1.0.0), Python, Go, Rust (crates.io `cmux-sdk`), Java, C++, Zig | catalog `cmux-tui/spec/resource-operations-v2.json`, `cmux-tui/bindings/` | n/a | `cmux.protocol/2`; ops are additive; `api-compat` gate |
| Agent hooks | `cmux agent hook install [provider]`, `cmux agent hook status` | `cmux-tui/crates/cmux-tui-hooks`, `cmux-tui/docs/agent-hooks.md` | n/a | n/a |
| Themes | `~/.config/cmux/themes/NAME.json` + `cmux settings set appearance.themeFile NAME`; Ghostty themes; theme slots (`chat.thinkingIndicator`, `chat.jumpToBottom`) | `cmux-theme-tokens`, `schemas/theme/`, `webviews/src/slots/` | yes, repaints live | slot ids are drafts |
| Safety | `cmux safe-mode on`, `CMUX_SAFE_MODE=1`, crash-loop entry, per-app rollback | `docs/cmux-next/extensions/safe-mode.md` | n/a | n/a |

The typed API an extension codes against is one generated file,
`cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts` ("cmux app API 1.0.0", 500+ ops, the scene
DSL, signals), made by `tools/gen-cmux-global.ts` and checked with `--check`. `cmux ext new` copies it, and
`cmux-extension-sdk` as this cmux was built with it (`sdk/`, no registry), into each new extension.

## What is missing, worst first

1. **No public, versioned extension SDK package.** An outside author gets the types only as a
   copied `cmux-app.d.ts` or a path into this repo (`examples/extensions/pr-list` reaches four
   folders up into `cmux-tui/`). npm `cmux-sdk` and crates.io `cmux-sdk` are socket clients: they
   drive cmux from outside and know nothing of manifests, places, the scene DSL or events. There is
   no Rust crate for an extension's own server (the ssh-terminal sample mirrors the interface by
   hand in `server/src/iface.rs`).
2. **No public example built only against that SDK.** Every sample builds against in-repo files, so
   nothing proves an outsider can do it, and nothing breaks when the public surface drifts.
3. **Chat events.** An extension can react to workspaces, panes, tabs, terminals and agents, but not
   to chats: no `chat.list`, no `chat.changed`, and `agent_chat.changed` is handled in
   `apps/subscriptions.rs` but not declared in the catalog, so it is untyped (#41582 adds them).
4. **Places not built:** `render: web` panes, new tab widgets (`cmux.newtab.widget/1` is not in
   `cmux-app-manifest/src/interfaces.rs`), chat widgets, status items (validated, never drawn),
   right sidebar panels. `cmux ext new` scaffolds a sidebar section, a pane or a command.
5. **Sharing.** Extensions install from a local folder only; `cmux ext add/share/search` is #42068.
6. **Budgets.** The batch-rate ladder (Slowed, Paused) is designed but not enforced (#41554); the
   node cap is checked in the VM, not the host.
7. **One capability table.** Scopes and the gesture and escalation rules are split between the
   catalog and `grants.rs`; #41615 makes one Rust table and serves it to the CLI and `ext dev`.

## Next, in order

#41615 (capability table), then #41554 (budgets), #41582 (chat ops and events), #42068 (add, share,
search), #41549 (16-color theme import and export). Then the SDK: a versioned TypeScript package
and a Rust crate generated from the same schema, a `chat.changed`/`workspace.changed` events API
in both, and one example extension, built only against the published package, that changes the
sidebar, adds a pane and reacts to chat and workspace events, reloaded live in a fleet-built app.
