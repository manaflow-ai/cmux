# @cmux/app-test

Test harness for cmux apps (`private`, never published). It loads an app directory into the reference fake host (`../js/test/fake-host.ts`, the same runtime `dist/cmux-app-runtime.js` every host loads), answers ops from fixtures under the app's grants, and drives palette scopes through a TypeScript port of the palette navigation reducer. Design: `plans/cmux-next/palette-scopes.md` sections 4 and 6.6. Runtime ABI: `../js/ABI.md`.

```ts
import { harness } from "@cmux/app-test"
const h = await harness.load(".", { grants: ["note:read"], fixtures: { "note.list": notes } })
const s = await h.palette.open("notes")              // first paint from the cached snapshot
expect(s.firstPaintMs).toBeLessThan(16)
await s.type("rea"); expect(s.rows.map((r) => r.title)).toEqual(["Reading list"])
await s.tab(); expect(s.chips).toEqual(["Notes", "Actions"])
await s.press("Return"); expect(h.ops.calls).toContainEqual({ op: "note.open", args: { id: "n1" } })
await s.backspace(); expect(s.chips).toEqual(["Notes"])
```

Samples import it through a `tsconfig.json` path (`samples/apps/palette-notes/tsconfig.json`).

## Loading

`harness.load(dir, {grants?, fixtures?, settings?, storage?, warm?, validate?})` validates the package like `cmux apps validate` (throws on errors), loads `main`, and, unless `warm: false`, runs every snapshot source once to stand in for the supervisor's cache from an earlier run.

- `grants`: scopes the user granted. Default: every key of the manifest's `scopes` and `optionalScopes`.
- `fixtures`: `{"note.list": value | (params, {origin}) => value}`; a function may throw `{code, message}`.
- `storage`: the app's local storage before the run (`app.storage.*` needs no grant).

## Ops

Every op the VM calls, and every ActionRef the palette runs, is recorded in `h.ops.calls` as `{op, args}` and in `h.ops.log` as `{op, args, origin, ok, code?}`. Answers, in order:

| Case | Answer |
| --- | --- |
| op in `generated/scopes.json` `never` | `operation.forbidden` |
| no fixture, not in the generated catalog, not a host op | `operation.unsupported` |
| the op's scope is not granted | `scope.missing` (`details.scope`) |
| fixture | its value |
| `app.storage.*`, `clipboard.write` | in memory (`h.storage`, `h.clipboard`); storage writes emit `app.storage.changed {key}` |
| catalog op without a fixture | `fixture.missing` |

The scope of an op comes from `generated/scopes.json`; for an op outside the catalog (an app server op) it is `<family>:read` for `list|get|search|query|read|count|counts|find|show|info|status` verbs, else `<family>:write`. `net.fetch` needs `net:<host>` (or `net:*.<domain>`); `integration.request` needs `integration:<provider>`, or `integration:<provider>:read` for GET.

Origin is `user` for ActionRefs run from the palette and for calls a command makes through `ctx.cmux` while it runs (the harness mints a gesture per command); every other call is `script`.

## Commands and the VM

- `h.commands.run(id, args)` checks `args` against the command's `arguments` schema (`invalid_params`), then runs it with a gesture. Returns `{ok, value}` or `{ok: false, error}`.
- `h.runAction(ref)` runs an ActionRef the way the palette does: `app:<this app>#<cmd>` runs the command; anything else is an op.
- `h.vm.stop()` / `h.vm.start()`; `h.vm.paletteRequests` counts calls into palette sources. Snapshot scopes still paint from the cache when the VM is stopped.
- `h.emit(event, payload)` marks snapshot scopes that list `event` in `invalidatedBy` dirty, refreshes open sessions on them, and delivers the event to the app's subscriptions. A dirty snapshot reruns on the next load (paint from cache first, then the fresh snapshot).
- `h.idle()` lets promises, streamed batches and commands settle; every session method awaits it.

## Palette sessions

`h.palette.open(scope?, {query?})` opens the palette on the root, or on a scope above the root (entry `opened`, like a shortcut). `scope` is the manifest id (`notes`) or a full id. The scope graph is the root, the app's scopes (`app:<id>#<scope>`, parents `root`, plus the scopes that list them in `children`) and the `actions` drill scope.

Session methods: `type(text)` (one `setQuery` per character, so prefixes enter scopes), `backspace()`, `tab()`, `shiftTab()`, `escape()`, `press("Return" | "Up" | "Down" | "Tab" | "Escape")`, `click(rowId)`, `select(rowId)`, `detail()`, `close()`. State: `rows` (`{id, title, subtitle?, symbol?, kind}`), `chips` (titles above the root), `scopePath` (ids including `root`), `query`, `selection` (row id), `isOpen`, `isLoading`, `firstPaintMs`, `ran` (ActionRefs run), `actionsMenu` (row whose Actions menu Tab opened), `errors`, `effects`.

Loads are answered by kind: the root lists the app's scopes and its palette commands; snapshot scopes rank the cached snapshot here with `rank.ts` (membership and the obvious first row match the macOS ranker; fine ordering does not); query scopes stream batches from the VM (`minQueryLength` short queries ask nothing); op scopes call the op (a fixture) with `{query, context?}` and map fields with JSONPath-lite (`$.a.b`, `$.tags[0]`); `actions` lists the drilled row's ActionRefs, or the scope's `primary` with `{id}`. Return on an item runs its first ActionRef (else `primary`).

## palette-nav-vectors.json

Shared vectors for `PaletteNavReducer.swift` and `src/nav.ts`; both implementations must pass every case. Hand-derived from the Swift rules and example tests; each case names the rules it covers (`rule`, palette-scopes.md section numbers).

```jsonc
{
  "format": 1,
  "cases": [{
    "name": "unique name",
    "rule": "4.3.2 P6",
    "config": { "prefixEntry": true, "keywordEntry": true, "maxDepth": 8 },   // optional, these defaults
    "graph": {
      "rootEmptyQuerySelection": 0,                                           // optional
      "scopes": [{ "id": "tabs", "prefix": "@", "keywords": ["tabs"], "parents": "root", "emptyQuerySelection": 1 }]
    },
    "rowsByScope": { "root": [{ "id": "cmd.a", "drills": "actions" }] },
    "events": [ { "event": "open", "scope": null, "query": "" }, { "event": "setQuery", "text": "@" } ],
    "expect": { "isOpen": true, "chips": ["root", "tabs"], "query": "", "selection": "tab.previous" }
  }]
}
```

Graph: scopes in registration order (the graph's collision rules apply: a later scope loses a colliding prefix or keyword). Omitted fields: `prefix` null, `keywords` [], `parents` `"root"`, `emptyQuerySelection` 0. `parents` is `"root"`, `"anywhere"`, or an array of scope ids (Swift `.only(set)`; `[]` means only by drill or row). The root descriptor is implicit.

Rows: `{id, enters?, drills?, isEnabled?}` (`isEnabled` defaults to true), the fields of `PaletteNavRow`.

Driver (the `PaletteNavDriver` of `PaletteNavFixtures.swift`): after each event, every `load` effect it produced is answered at once with `results(levelID, generation, rowsByScope[scope] ?? [], replace: true, isFinal: true)`, recursively, unless the event has `"answer": false`. A step `{"driver": "setRows", "scope": "root", "rows": [...]}` replaces that scope's rows for later answers and is not a reducer event.

Events: `event` is the `PaletteNavEvent` case name; associated values use the Swift labels, with unlabeled ones named here:

| event | fields |
| --- | --- |
| `open` | `scope` (id or null), `query` |
| `close`, `backspaceOnEmpty`, `tab`, `shiftTab`, `escape`, `refresh` | none |
| `setQuery` | `text` |
| `popTo` | `index` |
| `activate` | `rowID` (id or null) |
| `push` | `scope`, `row` (id or null) |
| `move` | `delta` |
| `select` | `rowID` |
| `results` | `levelID`, `generation`, `rows`, `replace`, `isFinal` |

Level ids start at 1 and generations at 1 per level, so explicit `results` events can name them.

Expect, on the final state (`top` is the last level). Required: `isOpen`, `chips` (scope ids of all levels, root first; `[]` when closed), `query` and `selection` of the top level (null when closed). Optional, checked only when present: `queries` and `selections` (per level, root first), `topEntry` (`{"entry": "root" | "opened" | "prefix" | "keyword" | "row" | "drill" | "command", "value"?}`, `value` present for every case with an associated value, null for `command(nil)`), `topRows` (row ids), `topContext` (the level's `context`), `isLoading`, `graphProblems` (count of `PaletteScopeGraph.problems`), `lastEffects` (exactly the effects the last event produced, including the driver's answers, in order), `lastEffectsInclude` (each must appear in them).

Effects: `effect` is the `PaletteNavEffect` case name: `{"effect": "load", "levelID", "scope", "query", "generation", "context"}` (`context` null when absent), `{"effect": "cancel", "levelID"}`, `{"effect": "run", "levelID", "rowID"}`, `{"effect": "openActions", "rowID"}`, `{"effect": "dismiss"}`, `{"effect": "announceEntered", "scope"}`, `{"effect": "announceLeft", "to"}`, `{"effect": "refused", "reason": "depthLimit"}`, `{"effect": "refused", "reason": "unknownScope", "scope"}`.

Prefix characters are single graphemes in both implementations; vectors use ASCII only.
