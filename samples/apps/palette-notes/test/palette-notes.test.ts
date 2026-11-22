import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { harness } from "@cmux/app-test"

const dir = join(import.meta.dir, "..")
const notes = [
  { id: "n1", title: "Reading list", body: "Books to read this fall", folder: "Personal", tags: ["books"], updatedAt: 3 },
  { id: "n2", title: "Groceries", body: "Milk, eggs, bread", folder: "Home", updatedAt: 2 },
  { id: "n3", title: "Meeting notes", body: "Palette rollout, then the reading group", folder: "Work", pinned: true, updatedAt: 1 },
  { id: "n4", title: "Long note", body: "x".repeat(700), updatedAt: 0 }
]
const load = (grants = ["clipboard:write"]) => harness.load(dir, { grants, storage: { notes } })
const titles = (rows: Array<{ title: string }>) => rows.map((r) => r.title)

describe("palette-notes: notes scope", () => {
  test("opens from the cached snapshot, filters on the host, drills into actions and runs the ActionRef", async () => {
    const h = await load()
    const s = await h.palette.open("notes")
    expect(s.firstPaintMs!).toBeLessThan(16)
    expect(s.chips).toEqual(["Notes"])
    // Pinned first, then most recent.
    expect(titles(s.rows)).toEqual(["Meeting notes", "Reading list", "Groceries", "Long note"])

    const vmBefore = h.vm.paletteRequests
    await s.type("rea")
    expect(titles(s.rows)).toEqual(["Reading list"])
    // Keystrokes in a snapshot scope never run app code.
    expect(h.vm.paletteRequests).toBe(vmBefore)

    await s.tab()
    expect(s.chips).toEqual(["Notes", "Actions"])
    expect(titles(s.rows)).toEqual(["Open Note", "clipboard.write"])
    await s.press("Return")
    expect(h.ops.calls).toContainEqual({ op: "app:cmux/palette-notes#open", args: { id: "n1" } })
    expect(h.storage.get("recent")).toEqual(["n1"])
    // The command wrote through ctx.cmux, so the write carries the user's gesture.
    expect(h.ops.log.find((e) => e.op === "app.storage.set")!.origin).toBe("user")

    await s.backspace()
    expect(s.chips).toEqual(["Notes"])
    expect(s.query).toBe("rea")
    expect(s.selection).toBe("n1")
  })

  test("Return on a row runs its first action; the second action copies a short body", async () => {
    const h = await load()
    const s = await h.palette.open("notes")
    await s.type("groc")
    await s.press("Return")
    expect(h.ops.calls).toContainEqual({ op: "app:cmux/palette-notes#open", args: { id: "n2" } })
    await s.tab()
    await s.press("Down")
    await s.press("Return")
    expect(h.clipboard).toBe("Milk, eggs, bread")
    expect(h.ops.log.find((e) => e.op === "clipboard.write")!.origin).toBe("user")
  })

  test("a long body is copied through the copy command", async () => {
    const h = await load()
    const s = await h.palette.open("notes")
    await s.type("long")
    await s.tab()
    expect(titles(s.rows)).toEqual(["Open Note", "Copy Text"])
    await s.press("Down")
    await s.press("Return")
    expect(h.clipboard).toBe("x".repeat(700))
  })

  test("without the clipboard grant the copy fails with scope.missing", async () => {
    const h = await load([])
    const s = await h.palette.open("notes")
    await s.type("groc")
    await s.tab()
    await s.press("Down")
    await s.press("Return")
    expect(h.clipboard).toBeNull()
    expect(h.ops.log.at(-1)).toMatchObject({ op: "clipboard.write", ok: false, code: "scope.missing" })
  })

  test("paints with the app stopped", async () => {
    const h = await load()
    h.vm.stop()
    const before = h.vm.paletteRequests
    const s = await h.palette.open("notes")
    expect(s.rows.length).toBe(4)
    expect(s.firstPaintMs!).toBeLessThan(16)
    expect(h.vm.paletteRequests).toBe(before)
  })

  test("detail renders the highlighted note", async () => {
    const h = await load()
    const s = await h.palette.open("notes")
    const detail = (await s.detail()) as { markdown: string }
    expect(detail.markdown).toBe("# Meeting notes\n\nPalette rollout, then the reading group")
  })

  test("the grep keyword enters the search child scope from notes", async () => {
    const h = await load()
    const s = await h.palette.open("notes")
    await s.type("grep")
    await s.tab()
    expect(s.chips).toEqual(["Notes", "Search Note Text"])
    expect(s.query).toBe("")
  })
})

describe("palette-notes: search scope", () => {
  test("streams title matches, then body matches; each keystroke aborts the previous query", async () => {
    const h = await load()
    const s = await h.palette.open("search")
    // minQueryLength 1: an empty query asks nothing of the app.
    expect(s.rows).toEqual([])
    const before = h.vm.paletteRequests
    await s.type("read")
    expect(h.vm.paletteRequests - before).toBe(4)
    // "bread" in the groceries body matches too.
    expect(titles(s.rows)).toEqual(["Reading list", "Meeting notes", "Groceries"])
    expect(s.rows[1]!.subtitle).toBe("Palette rollout, then the reading group")
    const last = Math.max(...h.host.paletteBatches.map((b) => b.reqId))
    expect(h.host.batchesFor(last).map((b) => [b.items.length, b.isFinal])).toEqual([
      [1, false],
      [2, false],
      [0, true]
    ])
    // Superseded requests never finished.
    expect(h.host.paletteResults.size).toBeLessThan(4)
  })
})

describe("palette-notes: item budget", () => {
  test("a huge note is clipped or dropped; it never fails the snapshot", async () => {
    const big = [
      ...notes,
      { id: "n5", title: "😀".repeat(400), body: "é".repeat(400), tags: Array.from({ length: 50 }, (_, i) => `tag-${i}-${"y".repeat(60)}`), updatedAt: 9 },
      { id: "n6", title: "Short", body: "😀".repeat(200), updatedAt: 8 }
    ]
    const h = await harness.load(dir, { grants: ["clipboard:write"], storage: { notes: big } })
    const s = await h.palette.open("notes")
    expect(s.rows.map((r) => r.id)).toEqual(["n3", "n5", "n6", "n1", "n2", "n4"])
    expect(Array.from(s.rows[1]!.title).length).toBe(120)
    // 200 emoji are 800 bytes: copied through the command, not inline.
    await s.type("short")
    await s.tab()
    expect(s.rows.map((r) => r.title)).toEqual(["Open Note", "Copy Text"])
  })
})

describe("palette-notes: new (mode form)", () => {
  test("from the CLI or MCP the command runs without a gesture: origin script", async () => {
    const h = await load()
    expect(await h.commands.run("new", { title: "From CLI" })).toEqual({ ok: true, value: { id: "n5" } })
    expect(h.ops.log.filter((e) => e.op === "app.storage.set").map((e) => e.origin)).toEqual(["script", "script"])
  })

  test("arguments are checked against the form schema, the note joins the snapshot after invalidation", async () => {
    const h = await load()
    expect(await h.commands.run("new", {})).toMatchObject({ ok: false, error: { code: "invalid_params" } })
    // The palette form submit is a user gesture.
    expect(await h.commands.run("new", { title: "Trip plan", body: "Pack the tent" }, { userGesture: true })).toEqual({ ok: true, value: { id: "n5" } })
    await h.idle()
    expect(h.dirty.has("notes")).toBe(true)
    const s = await h.palette.open("notes")
    expect(titles(s.rows)).toContain("Trip plan")
    expect(h.dirty.has("notes")).toBe(false)
    expect(h.ops.log.filter((e) => e.op === "app.storage.set").every((e) => e.origin === "user")).toBe(true)
  })

  test("the root lists the scopes and the palette command, not the action-only commands", async () => {
    const h = await load()
    const s = await h.palette.open()
    expect(s.chips).toEqual([])
    expect(titles(s.rows)).toEqual(["Notes", "Search Note Text", "New Note"])
    await s.type("notes")
    await s.tab()
    expect(s.chips).toEqual(["Notes"])
  })
})
