# What you can customize in cmux NEXT, and how (state of the API and SDK, rechecked 2026-11-24)

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
| Extensions (apps) | `cmux ext new NAME [--kind K]`, `cmux ext dev [--once --json]`, `cmux ext shot`, `cmux ext list/remove`; `cmux apps list/place/run/reload` | manifest v2 `cmux-tui/crates/cmux-app-host/schema/v2/`, validator `cmux-app-manifest`, sandboxed QuickJS host `cmux-app-host`, CLI `cmux-tui/src/cli/ext/` | yes: `ext dev` reloads one extension per save and keeps the last good version on a load error | interfaces carry a major (`cmux.section/1`); manifest `engines.cmux`; runtime `1.2.0` |
| Places an extension can draw | sidebar section (`cmux.section/1`), sidebar row decorations (`cmux.sidebar.rows/1`), hover cards, Session Info section, pane (`cmux.pane/1`, scene), a view over the New Tab composer the person picks (`cmux.newtab/1` with `tabs.newTabApp`), widgets (`cmux.widget/1`: the interface, its manifest rules, the daemon's layout, refresh budget and ticks, drawn on the New Tab grid and in the sidebar with Add Widget and edit mode, #45106), palette scope, diff renderer and source, terminal backend | `cmux-app-host/interfaces/`, drawn natively (`CmuxNextApps/Manifest/AppImplementation.swift`) or by the React `SceneRenderer` | yes | `/1` each, drafts until an outside app proves them |
| Live data | `cmux.watch(...)` on 8 signals (`github.pulls`, `github.changes`, `http.json`, `workspace.list`, `agent.list`, `chat.list`, `media.now_playing`, `system_calendar.events`); `cmux.live(op)`; `cmux.events.on("workspace.changed" \| "pane.changed" \| "tab.changed" \| "terminal.changed" \| "agent.changed" \| "screen.changed")` ; what plays: `cmux.watch("media.now_playing")` (`media:read`, pushed by `media.changed`) and `cmux.media.control({command})` on a tap (`media:control`) | `schema/v2/signals.json`, `cmux-tui-core/src/apps/routing.rs`; what plays: `CmuxNextApps/Operations/MediaAppOps.swift` | pushed, cached, budgeted | signal names are drafts |
| Socket API and client SDKs | `cmux raw operation OP`, and the clients in TypeScript (npm `cmux-sdk`; 1.0.0 in the repo, the registry still serves `0.0.0-bootstrap.0`), Python, Go, Rust (crates.io `cmux-sdk`, same), Java, C++, Zig | catalog `cmux-tui/spec/resource-operations-v2.json`, `cmux-tui/bindings/` | n/a | `cmux.protocol/2`; ops are additive; `api-compat` gate |
| Agent hooks | `cmux agent hook install [provider]`, `cmux agent hook status` | `cmux-tui/crates/cmux-tui-hooks`, `cmux-tui/docs/agent-hooks.md` | n/a | n/a |
| Themes | `~/.config/cmux/themes/NAME.json` + `cmux settings set appearance.themeFile NAME`; Ghostty themes; theme slots (`chat.thinkingIndicator`, `chat.jumpToBottom`) | `cmux-theme-tokens`, `schemas/theme/`, `webviews/src/slots/` | yes, repaints live | slot ids are drafts |
| Safety | `cmux safe-mode on`, `CMUX_SAFE_MODE=1`, crash-loop entry, per-app rollback | `docs/cmux-next/extensions/safe-mode.md` | n/a | n/a |

The typed API an extension codes against is one generated file,
`cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts` ("cmux app API 1.0.0", 500+ ops, the scene
DSL, signals), made by `tools/gen-cmux-global.ts` and checked with `--check`. `cmux ext new` copies
it into each new extension.

## What is missing, worst first

Rechecked 2026-11-24 at feat-cmux-next `5745678b611` for ask-66b237e9ad (Leo, 2026-11-24: "what kinds of
APIs and SDKs do we have? And like, how good are they? How ergonomic are they?"). Of the 2026-11-14 list,
the capability table (#41615), budgets (#41554), chat ops and events (#41582), sharing (#42068, `cmux ext
add/share/search`) and theme import (#41549) merged, and the extension SDK exists
(`cmux-tui/crates/cmux-extension-sdk`, TypeScript and Rust, 1.0.0, with `examples/extensions/activity` built only
against it). `cmux ext new NAME --kind section` makes a 15-file folder in 0.5 s that vendors the SDK
(`file:./sdk`) and reaches into no repo path. What is left:

1. **Nothing is published.** `cmux-extension-sdk` is not on npm or crates.io (both 404 on 2026-11-24), and no
   workflow publishes it (`sdk-publish-npm.yml` and `sdk-publish-crates.yml` carry only `cmux-sdk`). The
   socket clients on npm and crates.io (`cmux-sdk`) are still the `0.0.0-bootstrap.0` placeholder from
   2026-08-05 while the repo is at 1.0.0. An outside author installs from a checkout or relies on the copy
   `cmux ext new` vendors, which drifts from the app it runs in.
2. **The samples do not copy out.** The repo's extension samples carry 36 `../../../` references in their
   `package.json` and `tsconfig.json`; a sample copied out of the repo does not build. Only the scaffold is
   self-contained.
3. **Places with no drawer.** 29 interfaces live in `cmux-app-host/interfaces/`. Seven have no client or daemon
   consumer at all (`contact.provider`, `credential.provider`, `diff.renderer`, `diff.source`, `feed.source`,
   `fs.provider`, `search.provider`), and six are routed by the daemon with no drawn surface outside gallery
   fixtures (`chat.action`, `composer.toolbar`, `composer.model.picker`, `signal.source`, `terminal.backend`,
   `terminal.connector`). A grep, not a render test, decided which; `interfaces/README.md` should say per place
   whether it is drawn, daemon-only or a draft.
4. **Events carry no payload.** `workspace.changed` and the rest are invalidations; an extension re-reads after
   each one.
5. **Scaffold kinds stop at six** (sidebar, session-info, pane, newtab, widget, command): no `--kind` for a chat
   widget or a composer chip.
6. **The client SDKs cover a third of the catalog.** The seven socket clients expose handwritten handles over
   the reviewed 125-operation public catalog (`cmux-tui/bindings/ERGONOMICS.md`); the full catalog
   (`cmux-tui/spec/resource-operations-v2.json`) has 384 operations and the extension typings
   (`generated/cmux-app.d.ts`) type 514. An outside client reaches the other 259 only through `raw`.

## Next, in order

Publish `cmux-sdk` 1.0.0 (`cmux-sdk-v1.0.0`, `cmux-tui/bindings/RELEASING.md`) and add `cmux-extension-sdk` to
the npm and crates publish workflows; then point `cmux ext new` and every sample at the published version
instead of a vendored copy. Then the per-place drawn/daemon-only/draft table, payload-carrying events, and chat
widget and composer chip scaffolds. The whole surface, measured against its theoretical best, is cmuxterm-hq
`docs/design/surface-map-vs-optimal.md` (team only).
