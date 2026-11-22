import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { harness } from "../src/index.ts"

/** Writes an app package: a manifest and a hand-packed main (the IIFE shape `cmux apps pack` produces). */
function appDir(manifest: Record<string, unknown>, body: string) {
  const dir = mkdtempSync(join(tmpdir(), "cmux-app-test-"))
  mkdirSync(join(dir, "dist"))
  writeFileSync(join(dir, "cmux-app.json"), JSON.stringify({ manifestVersion: 1, name: "T", version: "1.0.0", description: "d", engines: { cmux: "^1.0" }, main: "dist/main.js", ...manifest }))
  writeFileSync(join(dir, "dist/main.js"), `var __cmuxAppExports = (() => { ${body} })();`)
  return dir
}

const notesApp = appDir(
  {
    id: "local/notes",
    scopes: { "note:read": "List notes." },
    contributes: {
      paletteScopes: [
        { id: "notes", title: "Notes", keywords: ["notes"], source: { kind: "snapshot", export: "corpus" }, primary: "note.open" },
        { id: "remote", title: "Remote Notes", source: { kind: "op", op: "note.search", item: { id: "$.id", title: "$.name", subtitle: "$.meta.folder" } } }
      ],
      commands: [{ id: "touch", title: "Touch", run: "touch" }]
    }
  },
  `return {
    corpus: palette.snapshot(async () => (await cmux.note.list({})).map((n) => ({ id: n.id, title: n.title }))),
    touch: async (args, ctx) => { await cmux.teleport.now({}); return 1 },
  }`
)

describe("ops: fixtures, grants and unsupported ops", () => {
  test("a granted fixture answers; the design's example reads as written", async () => {
    const h = await harness.load(notesApp, { grants: ["note:read"], fixtures: { "note.list": [{ id: "n1", title: "Reading list" }, { id: "n2", title: "Groceries" }], "note.open": null } })
    const s = await h.palette.open("notes")
    expect(s.firstPaintMs!).toBeLessThan(16)
    await s.type("rea")
    expect(s.rows.map((r) => r.title)).toEqual(["Reading list"])
    await s.tab()
    expect(s.chips).toEqual(["Notes", "Actions"])
    await s.press("Return")
    expect(h.ops.calls).toContainEqual({ op: "note.open", args: { id: "n1" } })
    await s.backspace()
    expect(s.chips).toEqual(["Notes"])
  })

  test("a call outside the grants fails scope.missing; the snapshot then has no rows", async () => {
    const h = await harness.load(notesApp, { grants: [], fixtures: { "note.list": [] } })
    expect(h.ops.log[0]).toMatchObject({ op: "note.list", ok: false, code: "scope.missing" })
    const s = await h.palette.open("notes")
    expect(s.rows).toEqual([])
  })

  test("an op nobody implements fails operation.unsupported, not scope.missing", async () => {
    const h = await harness.load(notesApp, { grants: ["note:read"], fixtures: { "note.list": [] } })
    const r = await h.commands.run("touch")
    expect(r).toMatchObject({ ok: false, error: { code: "operation.unsupported" } })
  })

  test("a catalog op with no fixture says so", async () => {
    const h = await harness.load(notesApp, { grants: ["workspace:read"], fixtures: { "note.list": [] } })
    const r = await h.runAction({ id: "workspace.list", args: {} })
    expect(r).toMatchObject({ ok: false, error: { code: "fixture.missing" } })
  })

  test("op sources map fields with JSONPath-lite and need no app code", async () => {
    const h = await harness.load(notesApp, { grants: ["note:read"], fixtures: { "note.list": [], "note.search": (p: { query: string }) => [{ id: "r1", name: `hit ${p.query}`, meta: { folder: "Inbox" } }] } })
    h.vm.stop()
    const s = await h.palette.open("remote")
    await s.type("x")
    expect(s.rows).toEqual([{ id: "r1", title: "hit x", subtitle: "Inbox", kind: "item" }])
  })
})

describe("palette keys", () => {
  const prefixed = appDir(
    {
      id: "cmux/prefixed",
      repository: "https://github.com/manaflow-ai/cmux",
      contributes: { paletteScopes: [{ id: "things", title: "Things", prefix: "~", source: { kind: "snapshot", export: "things" } }] }
    },
    `return { things: palette.snapshot(() => [{ id: "a", title: "Alpha", drill: "things" }, { id: "b", title: "Beta" }]) }`
  )

  test("a first-party prefix enters from the root; Escape pops a pushed level; Escape at the root closes", async () => {
    const h = await harness.load(prefixed)
    const s = await h.palette.open()
    await s.type("~be")
    expect(s.chips).toEqual(["Things"])
    expect(s.query).toBe("be")
    expect(s.rows.map((r) => r.id)).toEqual(["b"])
    await s.escape()
    expect(s.chips).toEqual([])
    await s.escape()
    expect(s.isOpen).toBe(false)
  })

  test("an item's drill pushes its scope with the item as context; Shift-Tab pops", async () => {
    const h = await harness.load(prefixed)
    const s = await h.palette.open("things")
    expect(s.selection).toBe("a")
    await s.tab()
    expect(s.chips).toEqual(["Things", "Things"])
    await s.shiftTab()
    expect(s.chips).toEqual(["Things"])
    await s.press("Down")
    await s.tab()
    // Beta has no actions and no primary: the drill shows an empty Actions scope.
    expect(s.chips).toEqual(["Things", "Actions"])
    expect(s.rows).toEqual([])
  })
})

describe("snapshot invalidation", () => {
  const live = appDir(
    { id: "local/live", contributes: { paletteScopes: [{ id: "things", title: "Things", source: { kind: "snapshot", export: "things", invalidatedBy: ["thing.changed"] } }] } },
    `let n = 0; return { things: palette.snapshot(() => { n++; return [{ id: "t" + n, title: "Thing " + n }, { id: "tx", title: "Thing x" }] }) }`
  )

  test("an invalidating event reruns the snapshot once, however many keystrokes land meanwhile", async () => {
    const h = await harness.load(live)
    const s = await h.palette.open("things")
    expect(s.rows.map((r) => r.id)).toEqual(["t1", "tx"])
    const before = h.vm.paletteRequests
    h.emit("thing.changed")
    await s.type("thing")
    expect(h.vm.paletteRequests - before).toBe(1)
    expect(s.rows.map((r) => r.id)).toEqual(["t2", "tx"])
    expect(s.selection).toBe("t2")
    expect(h.dirty.size).toBe(0)
  })

  test("an event no scope lists changes nothing", async () => {
    const h = await harness.load(live)
    const s = await h.palette.open("things")
    const before = h.vm.paletteRequests
    h.emit("other.changed")
    await s.type("t")
    expect(h.vm.paletteRequests).toBe(before)
  })
})

describe("gestures and host-run ActionRefs", () => {
  const app = appDir(
    {
      id: "local/focus",
      scopes: { "workspace:write": "Focus tabs.", "actions:run": "Run actions." },
      contributes: {
        paletteScopes: [{ id: "rows", title: "Rows", source: { kind: "snapshot", export: "rows" } }],
        commands: [{ id: "focus", title: "Focus", run: "focus", contexts: [] }]
      }
    },
    `return {
      rows: palette.snapshot(() => [
        { id: "mine", title: "Mine", actions: [act("app:local/focus#focus", {})] },
        { id: "theirs", title: "Theirs", actions: [act("app:local/other#steal", {})] },
        { id: "inner", title: "Inner", actions: [act("action.run", { id: "app:local/other#steal", args: {} })] }
      ]),
      focus: async (args, ctx) => {
        await ctx.cmux.storage.set("k", 1)
        await ctx.cmux.tab.focus({ tab: "tab_1" })
        await ctx.cmux.tab.focus({ tab: "tab_2" })
        return ctx.cmux.gesture()
      }
    }`
  )
  const fixtures = { "tab.focus": null, "action.run": null }
  const origins = (h: { ops: { log: Array<{ op: string; origin: string }> } }) => h.ops.log.filter((e) => e.op !== "app.storage.get").map((e) => `${e.op} ${e.origin}`)

  test("a palette Return mints one token: app-private writes keep it, the first view change spends it", async () => {
    const h = await harness.load(app, { fixtures })
    const s = await h.palette.open("rows")
    await s.press("Return")
    // The command's own log entry lands when it settles.
    expect(origins(h)).toEqual(["app.storage.set user", "tab.focus user", "tab.focus script", "app:local/focus#focus user"])
  })

  test("ctx.cmux.gesture() returns the invocation token", async () => {
    const h = await harness.load(app, { fixtures })
    expect(await h.commands.run("focus", {}, { userGesture: true })).toEqual({ ok: true, value: "g-1" })
  })

  test("the CLI and MCP path mints no token", async () => {
    const h = await harness.load(app, { fixtures })
    expect(await h.commands.run("focus")).toEqual({ ok: true, value: null })
    expect(origins(h)).toEqual(["app.storage.set script", "tab.focus script", "tab.focus script"])
  })

  test("a row cannot run another app's command, directly or through action.run", async () => {
    const h = await harness.load(app, { fixtures })
    const s = await h.palette.open("rows")
    await s.press("Down")
    await s.press("Return")
    expect(h.ops.log.at(-1)).toMatchObject({ op: "app:local/other#steal", ok: false, code: "operation.forbidden" })
    await s.press("Down")
    await s.press("Return")
    expect(h.ops.log.at(-1)).toMatchObject({ op: "action.run", ok: false, code: "operation.forbidden" })
  })
})

