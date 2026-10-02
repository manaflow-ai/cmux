import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const scopes = [
  { id: "notes", source: { kind: "snapshot", export: "corpus" }, detail: { export: "noteDetail" } },
  { id: "search", source: { kind: "query", export: "search" } },
  { id: "plain", source: { kind: "query", export: "plain" } },
  { id: "wrong", source: { kind: "query", export: "corpus" } }
]
const init = { app: { id: "local/palette", version: "1.0.0" }, apiVersion: "1.0.0", paletteScopes: scopes }
const host = (body: string) => new FakeHost(app(body), init)

describe("act", () => {
  test("builds a typed ActionRef", () => {
    const h = host(`return {}`)
    expect(h.eval(`JSON.stringify(act("note.open", { id: "n1" }, { title: "Open", symbol: "doc" }))`)).toBe(JSON.stringify({ id: "note.open", args: { id: "n1" }, title: "Open", symbol: "doc" }))
    expect(h.eval(`cmux.act === act && cmux.palette === palette`)).toBe(true)
  })
  test("refuses closures in args and an empty id", () => {
    const h = host(`return {}`)
    expect(() => h.eval(`act("x", { f: () => 1 })`)).toThrow(/function/)
    expect(() => h.eval(`act("", {})`)).toThrow(/action id/)
  })
})

describe("snapshot sources", () => {
  test("send every item in batches of at most 200, the last one final", async () => {
    const h = host(`return { corpus: palette.snapshot(async () => Array.from({ length: 450 }, (_, i) => ({ id: "n" + i, title: "Note " + i, actions: [act("note.open", { id: "n" + i })] }))) }`)
    expect(h.paletteOpen("notes", "snapshot", "", 1, 7)).toBe("")
    await h.settle()
    const batches = h.batchesFor(7)
    expect(batches.map((b) => b.items.length)).toEqual([200, 200, 50])
    expect(batches.map((b) => b.isFinal)).toEqual([false, false, true])
    expect(batches.map((b) => b.replace)).toEqual([true, false, false])
    expect(batches[0]!.generation).toBe(1)
    expect(batches[0]!.items[0]).toEqual({ id: "n0", title: "Note 0", actions: [{ id: "note.open", args: { id: "n0" } }] })
    expect(h.paletteResults.get(7)).toEqual({ ok: true, body: { count: 450 } })
  })

  test("an empty snapshot still sends one final batch", async () => {
    const h = host(`return { corpus: palette.snapshot(() => []) }`)
    h.paletteOpen("notes", "snapshot", "", 3, 1)
    await h.settle()
    expect(h.batchesFor(1)).toEqual([{ reqId: 1, generation: 3, items: [], isFinal: true, replace: true }])
  })

  test("reject closures, oversize items and oversize snapshots", async () => {
    const cases: Array<[string, string]> = [
      [`[{ id: "a", title: "A", run: () => 1 }]`, "palette.invalid"],
      [`[{ id: "a", title: "x".repeat(3000) }]`, "palette.limit"],
      [`Array.from({ length: 10001 }, (_, i) => ({ id: String(i), title: "t" }))`, "palette.limit"],
      [`[{ title: "no id" }]`, "palette.invalid"],
      [`[{ id: "a", title: "A", actions: ["note.open"] }]`, "palette.invalid"]
    ]
    for (const [items, code] of cases) {
      const h = host(`return { corpus: palette.snapshot(() => ${items}) }`)
      h.paletteOpen("notes", "snapshot", "", 1, 1)
      await h.settle()
      expect(h.batchesFor(1)).toEqual([])
      expect(h.paletteResults.get(1)?.ok).toBe(false)
      expect(h.paletteResults.get(1)?.body.code).toBe(code)
    }
  })

  test("items are checked in their serialized form: toJSON cannot slip past the checks", async () => {
    // A getter that answers the checks with a small value and the serializer with a big one.
    const h = host(`return { corpus: palette.snapshot(() => { let n = 0; return [{ id: "a", get title() { return n++ === 0 ? "A" : "x".repeat(4000) } }] }) }`)
    h.paletteOpen("notes", "snapshot", "", 1, 1)
    await h.settle()
    expect(h.batchesFor(1)).toEqual([])
    expect(h.paletteResults.get(1)?.body.code).toBe("palette.limit")
    const h2 = host(`return { corpus: palette.snapshot(() => { let n = 0; return [{ title: "A", get id() { return n++ === 0 ? "a" : undefined } }] }) }`)
    h2.paletteOpen("notes", "snapshot", "", 1, 1)
    await h2.settle()
    expect(h2.paletteResults.get(1)?.body.code).toBe("palette.invalid")
  })

  test("a snapshot can read app storage through the host", async () => {
    const h = host(`return { corpus: palette.snapshot(async () => ((await cmux.storage.get("notes")) ?? []).map((n) => ({ id: n.id, title: n.title }))) }`)
    h.handlers["app.storage.get"] = () => ({ ok: true, body: { value: [{ id: "n1", title: "Reading list" }] } })
    h.paletteOpen("notes", "snapshot", "", 1, 1)
    await h.settle()
    expect(h.batchesFor(1)[0]!.items).toEqual([{ id: "n1", title: "Reading list" }])
  })
})

describe("query sources", () => {
  const streaming = `
    globalThis.release = null
    return {
      search: palette.query(async function* (q, ctx) {
        globalThis.lastCtx = { scope: ctx.scope, generation: ctx.generation, session: ctx.session, filter: ctx.filter, context: ctx.context }
        yield palette.cached()
        yield [{ id: q + "-1", title: "first " + q }]
        await new Promise((r) => { globalThis.release = r; ctx.signal.addEventListener("abort", () => { globalThis.aborted = (globalThis.aborted ?? 0) + 1; r() }) })
        if (ctx.signal.aborted) return
        yield [{ id: q + "-2", title: "second " + q }]
      })
    }`

  test("each yield is a batch; completion sends one final empty batch and done", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "re", 4, 9, { session: "L2", filter: "pinned", context: "row1" })
    await h.settle()
    expect(h.batchesFor(9).map((b) => b.items.map((i: any) => i.id))).toEqual([["re-1"]])
    expect(h.eval("JSON.stringify(lastCtx)")).toBe(JSON.stringify({ scope: "search", generation: 4, session: "L2", filter: "pinned", context: "row1" }))
    h.eval("release()")
    await h.settle()
    expect(h.batchesFor(9).map((b) => [b.items.map((i: any) => i.id), b.isFinal, b.replace])).toEqual([[["re-1"], false, true], [["re-2"], false, false], [[], true, false]])
    expect(h.paletteResults.get(9)).toEqual({ ok: true, body: { count: 2 } })
  })

  test("a new query for the same session aborts the old generator", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "r", 1, 1, { session: "L2" })
    await h.settle()
    h.paletteOpen("search", "query", "re", 2, 2, { session: "L2" })
    await h.settle()
    expect(h.eval("aborted")).toBe(1)
    h.eval("release()")
    await h.settle()
    // Nothing more for the superseded request, and no done either.
    expect(h.batchesFor(1).map((b) => b.items.map((i: any) => i.id))).toEqual([["r-1"]])
    expect(h.paletteResults.has(1)).toBe(false)
    expect(h.batchesFor(2).at(-1)!.isFinal).toBe(true)
  })

  test("requests in different sessions run side by side", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "a", 1, 1, { session: "w1" })
    h.paletteOpen("search", "query", "b", 1, 2, { session: "w2" })
    await h.settle()
    expect(h.eval("globalThis.aborted ?? 0")).toBe(0)
  })

  test("cancel aborts and silences the request", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "x", 1, 5)
    await h.settle()
    h.paletteCancel(5)
    await h.settle()
    expect(h.eval("aborted")).toBe(1)
    expect(h.batchesFor(5).length).toBe(1)
    expect(h.paletteResults.has(5)).toBe(false)
  })

  test("palette.cached() replays the last complete result of the longest cached prefix", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "re", 1, 1)
    await h.settle()
    h.eval("release()")
    await h.settle()
    h.paletteOpen("search", "query", "rea", 2, 2)
    await h.settle()
    // First the cached result for "re" (provisional), then the live first batch replaces it.
    expect(h.batchesFor(2).map((b) => [b.items.map((i: any) => i.id), b.replace])).toEqual([[["re-1", "re-2"], true], [["rea-1"], true]])
  })

  test("palette.cached() is per session, drilled row and filter", async () => {
    const h = host(streaming)
    h.paletteOpen("search", "query", "re", 1, 1, { session: "L1", filter: "pinned" })
    await h.settle()
    h.eval("release()")
    await h.settle()
    // Another filter, another drilled row or another level sees no cached rows.
    const first: string[][] = []
    for (const [id, ctx] of [[2, { session: "L1", filter: "all" }], [3, { session: "L1", filter: "pinned", context: "row9" }], [4, { session: "L2", filter: "pinned" }], [5, { session: "L1", filter: "pinned" }]] as const) {
      h.paletteOpen("search", "query", "rea", 1, id, ctx)
      await h.settle()
      first.push(h.batchesFor(id)[0]!.items.map((i: any) => i.id))
    }
    expect(first).toEqual([["rea-1"], ["rea-1"], ["rea-1"], ["re-1", "re-2"]])
  })

  test("a query request stops at 1000 rows in total and says it was truncated", async () => {
    const h = host(`return { search: palette.query(async function* () {
      for (let b = 0; b < 8; b++) yield Array.from({ length: 200 }, (_, i) => ({ id: b + "-" + i, title: "t" }))
      globalThis.ranOn = true
    }) }`)
    h.paletteOpen("search", "query", "", 1, 1)
    await h.settle()
    const batches = h.batchesFor(1)
    expect(batches.reduce((n, b) => n + b.items.length, 0)).toBe(1000)
    expect(batches.at(-1)!.isFinal).toBe(true)
    expect(h.paletteResults.get(1)).toEqual({ ok: true, body: { count: 1000, truncated: true } })
    expect(h.eval("globalThis.ranOn ?? false")).toBe(false)
  })

  test("an op called with ctx.signal rejects with aborted on cancel", async () => {
    const h = host(`return { search: palette.query(async function* (q, { signal }) {
      try { yield await cmux.note.search({ q }, { signal }) } catch (e) { globalThis.code = e.code; throw e }
    }) }`)
    h.handlers["note.search"] = () => new Promise(() => {})
    h.paletteOpen("search", "query", "x", 1, 1)
    await h.settle()
    expect(h.calls[0]!.options).toEqual({})
    h.paletteCancel(1)
    await h.settle()
    expect(h.eval("code")).toBe("aborted")
  })

  test("more than 200 items in one yield fails the request", async () => {
    const h = host(`return { search: palette.query(async function* () { yield Array.from({ length: 201 }, (_, i) => ({ id: String(i), title: "t" })) }) }`)
    h.paletteOpen("search", "query", "", 1, 1)
    await h.settle()
    expect(h.paletteResults.get(1)?.body.code).toBe("palette.limit")
  })

  test("a plain async function is one final batch", async () => {
    const h = host(`return { plain: palette.query(async (q) => [{ id: "only", title: q }]) }`)
    h.paletteOpen("plain", "query", "z", 1, 1)
    await h.settle()
    expect(h.batchesFor(1)).toEqual([{ reqId: 1, generation: 1, items: [{ id: "only", title: "z" }], isFinal: true, replace: true }])
  })

  test("a ctxJSON that is not an object still ends the request", () => {
    const h = host(`return { corpus: palette.snapshot(() => []) }`)
    expect(h.global.__cmuxAppPaletteOpen("notes", "snapshot", "", 1, "nope", 4)).toContain("ctxJSON")
    expect(h.paletteResults.get(4)?.body.code).toBe("palette.invalid")
  })

  test("unknown scope, missing export and kind mismatch fail with done", async () => {
    const h = host(`return { corpus: palette.snapshot(() => []) }`)
    expect(h.paletteOpen("nope", "query", "", 1, 1)).toContain("nope")
    expect(h.paletteOpen("search", "query", "", 1, 2)).toContain("search")
    expect(h.paletteOpen("wrong", "query", "", 1, 3)).toContain("snapshot")
    expect([1, 2, 3].map((id) => h.paletteResults.get(id)?.body.code)).toEqual(["palette.scope", "export.missing", "palette.kind"])
  })
})

describe("detail", () => {
  test("answers with paletteDone and the detail JSON", async () => {
    const h = host(`return { corpus: palette.snapshot(() => []), noteDetail: palette.detail(async (id) => ({ markdown: "# " + id, metadata: [{ label: "Folder", value: "Inbox" }], actions: [act("note.pin", { id })] })) }`)
    h.paletteDetail("notes", "n1", 11)
    await h.settle()
    expect(h.paletteResults.get(11)).toEqual({ ok: true, body: { markdown: "# n1", metadata: [{ label: "Folder", value: "Inbox" }], actions: [{ id: "note.pin", args: { id: "n1" } }] } })
  })
  test("a scope without a detail export fails", async () => {
    const h = host(`return { corpus: palette.snapshot(() => []) }`)
    h.paletteDetail("search", "n1", 1)
    await h.settle()
    expect(h.paletteResults.get(1)?.body.code).toBe("export.missing")
  })
})

describe("command gesture", () => {
  const cmd = app(`return {
    run: async (args, ctx) => {
      await ctx.cmux.storage.set("a", 1)
      await cmux.storage.set("b", 2)
      await cmux.call("app.storage.set", { key: "c", value: 3 }, { gesture: ctx.gesture })
      await ctx.cmux.note.open({ id: "n1" })
      globalThis.later = ctx.cmux
      return { gesture: ctx.gesture ?? null, app: ctx.app.id }
    }
  }`)

  test("ctx.cmux carries the gesture; the global cmux only when it is passed explicitly", async () => {
    const h = new FakeHost(cmd, init)
    h.fallback = () => ({ ok: true, body: { value: null } })
    h.runCommand("run", {}, 1, { gesture: "g-1" })
    await h.settle()
    expect(h.commandResults.get(1)).toEqual({ ok: true, body: { value: { gesture: "g-1", app: "local/palette" } } })
    expect(h.calls.map((c) => [c.name, c.params.key ?? c.params.id, c.options.gesture ?? null])).toEqual([
      ["app.storage.set", "a", "g-1"],
      ["app.storage.set", "b", null],
      ["app.storage.set", "c", "g-1"],
      ["note.open", "n1", "g-1"]
    ])
  })

  test("the gesture ends when the command settles", async () => {
    const h = new FakeHost(cmd, init)
    h.fallback = () => ({ ok: true, body: { value: null } })
    h.runCommand("run", {}, 1, { gesture: "g-1" })
    await h.settle()
    h.eval(`later.storage.set("d", 4)`)
    await h.settle()
    expect(h.calls.at(-1)!.options).toEqual({})
  })

  test("without a ctx the command runs as before", async () => {
    const h = new FakeHost(cmd, init)
    h.fallback = () => ({ ok: true, body: { value: null } })
    h.runCommand("run", {}, 2)
    await h.settle()
    expect(h.commandResults.get(2)!.body.value.gesture).toBeNull()
    expect(h.calls.every((c) => c.options.gesture === undefined)).toBe(true)
  })
})
