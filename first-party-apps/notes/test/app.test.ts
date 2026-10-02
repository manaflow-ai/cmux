import { describe, expect, test } from "bun:test"
import { FOCUS_OPS, findVisible, makeHost, nodesOf, run, texts, visible } from "./harness.ts"

const seeded = {
  "notes.v1": {
    version: 1,
    notes: [
      { id: "note_a", title: "Release checklist", body: "- [x] tag\n- [ ] notes\n- [ ] announce", pinned: true, scratchpad: false, workspace: null, createdAt: 1, updatedAt: 10, revision: 3, lastEdit: { via: "ui" } },
      { id: "note_b", title: "", body: "Ideas\nfaster search\nexport to folder", pinned: false, scratchpad: false, workspace: null, createdAt: 2, updatedAt: 20, revision: 1, lastEdit: { via: "ui" } },
      { id: "note_pad", title: "", body: "check flaky test\nport 3001 busy", pinned: false, scratchpad: true, workspace: { id: "workspace_api", name: "api" }, createdAt: 3, updatedAt: 30, revision: 2, lastEdit: { via: "command", actor: "agent:claude" } }
    ]
  }
}

describe("commands (agent tools)", () => {
  test("create, list, read, append; list never returns bodies; everything persists", async () => {
    const { host, kv } = makeHost()
    const created = await run(host, "create", { title: "Deploy", body: "step 1", workspace: "current" })
    expect(created.ok).toBe(true)
    const id = created.body.value.id
    expect(created.body.value.workspace).toEqual({ id: "workspace_api", name: "api" })
    const appended = await run(host, "append", { id, text: "step 2" })
    expect(appended.body.value.lines).toBe(2)
    const listed = await run(host, "list", {})
    expect(listed.body.value.notes).toHaveLength(1)
    expect(listed.body.value.notes[0].body).toBeUndefined()
    expect(listed.body.value.notes[0].preview).toBe("step 1 · step 2")
    expect(listed.body.value.storage).toBe("local")
    const read = await run(host, "read", { id })
    expect(read.body.value.body).toBe("step 1\nstep 2")
    expect((kv.get("notes.v1") as { notes: unknown[] }).notes).toHaveLength(1)
    expect(host.calls.filter((c) => FOCUS_OPS.includes(c.name))).toEqual([])
  })

  test("append by workspace creates the scratchpad once, then appends to it", async () => {
    const { host } = makeHost()
    await run(host, "append", { workspace: "web", text: "one" })
    await run(host, "append", { workspace: "workspace_web", text: "two" })
    const listed = (await run(host, "list", { workspace: "web" })).body.value.notes
    expect(listed).toHaveLength(1)
    expect(listed[0].scratchpad).toBe(true)
    expect((await run(host, "read", { id: listed[0].id })).body.value.body).toBe("one\ntwo")
  })

  test("capture: first line is the title", async () => {
    const { host } = makeHost()
    const r = await run(host, "capture", { text: "Call the vendor\nabout invoices" })
    expect(r.body.value.title).toBe("Call the vendor")
    expect(r.body.value.preview).toBe("about invoices")
  })

  test("errors carry stable codes", async () => {
    const { host } = makeHost()
    expect((await run(host, "read", { id: "note_missing" })).body.code).toBe("note.not_found")
    expect((await run(host, "append", { text: "x" })).body.code).toBe("invalid_params")
    expect((await run(host, "append", { id: "a", workspace: "api", text: "x" })).body.code).toBe("invalid_params")
    expect((await run(host, "capture", {})).body.code).toBe("invalid_params")
    expect((await run(host, "create", { body: "x", workspace: "nope" })).body.code).toBe("workspace.not_found")
  })

  test("search answers in the search-provider shape", async () => {
    const { host } = makeHost({}, seeded)
    const r = (await run(host, "search", { query: "flaky" })).body.value.results
    expect(r).toHaveLength(1)
    expect(r[0]).toMatchObject({ id: "note_pad", snippet: "check flaky test", subtitle: "api", open: { command: "cmux/notes#open", args: { id: "note_pad" } } })
  })

  test("export returns markdown files with unique names", async () => {
    const { host } = makeHost({}, seeded)
    const files = (await run(host, "exportNotes", {})).body.value.files
    expect(files.map((f: { name: string }) => f.name)).toEqual(["release-checklist.md", "ideas.md", "check-flaky-test.md"])
    expect(files[0].text).toBe("# Release checklist\n\n- [x] tag\n- [ ] notes\n- [ ] announce\n")
  })

  test("cycleVariant falls back to a session override without app.settings.set", async () => {
    const { host } = makeHost({ variant: "list" })
    const r = await run(host, "cycleVariant")
    expect(r.body.value).toEqual({ variant: "split", persisted: false })
    expect(host.calls.some((c) => c.name === "app.settings.set")).toBe(true)
  })
})

describe("document store backend (proposed ops)", () => {
  test("uses document.* when the host has them and replays an op after a conflict", async () => {
    const { host } = makeHost()
    const server = new Map<string, { revision: number; data: Record<string, unknown> }>()
    server.set("note_x", { revision: 4, data: { title: "", body: "from phone", pinned: false, scratchpad: false, workspace: null, createdAt: 1, updatedAt: 1, lastEdit: { via: "ui" } } })
    let conflictOnce = true
    host.handlers["document.list"] = () => ({ ok: true, body: { value: { documents: [...server].map(([id, d]) => ({ id, revision: String(d.revision), data: d.data })) } } })
    host.handlers["document.get"] = (p) => {
      const d = server.get(p.id)
      return { ok: true, body: { value: d ? { id: p.id, revision: String(d.revision), data: d.data } : null } }
    }
    host.handlers["document.put"] = (p) => {
      const d = server.get(p.id)
      if (conflictOnce && d) {
        // Another device appended first.
        conflictOnce = false
        server.set(p.id, { revision: d.revision + 1, data: { ...d.data, body: `${d.data.body}\nfrom laptop` } })
        return { ok: false, body: { code: "revision.conflict", message: "stale base" } }
      }
      if ((d?.revision ?? 0) !== Number(p.base_revision)) return { ok: false, body: { code: "revision.conflict", message: "stale" } }
      server.set(p.id, { revision: (d?.revision ?? 0) + 1, data: p.data })
      return { ok: true, body: { value: { revision: String((d?.revision ?? 0) + 1) } } }
    }
    const r = await run(host, "append", { id: "note_x", text: "from agent" })
    expect(r.ok).toBe(true)
    expect(server.get("note_x")!.data.body).toBe("from phone\nfrom laptop\nfrom agent")
    expect(server.get("note_x")!.revision).toBe(6)
    expect((await run(host, "list", {})).body.value.storage).toBe("documents")
    expect(host.calls.some((c) => c.name.startsWith("app.storage"))).toBe(false)
    expect(host.subscriptions.size).toBeGreaterThan(0)
  })
})

describe("surfaces", () => {
  test("scratchpad variant: current workspace's scratchpad, then other notes", async () => {
    const { host } = makeHost({ variant: "scratchpad" }, seeded)
    expect(host.mount("m", "renderNotes", { contribution: "cmux/notes#notes", surface: "sidebarSection" })).toBe("")
    await host.settle(10)
    const shown = texts(host, "m")
    expect(shown).toEqual(expect.arrayContaining(["api", "check flaky test", "port 3001 busy", "Release checklist", "Ideas"]))
    expect(nodesOf(host, "m", "Row").map(([, n]) => n.props.title)).not.toContain("api") // this workspace's scratchpad is open above, not a row
    expect(host.timers.size).toBe(0) // no polling
    expect([...host.subscriptions.values()].map((s) => s.stream)).toContain("workspace.changed")
  })

  test("an agent append updates the mounted section without any focus op", async () => {
    const { host } = makeHost({ variant: "scratchpad" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    await run(host, "append", { workspace: "current", text: "deploy at 5pm" })
    expect(texts(host, "m")).toContain("deploy at 5pm")
    expect(host.calls.filter((c) => FOCUS_OPS.includes(c.name))).toEqual([])
  })

  test("typing in the scratchpad field appends a line", async () => {
    const { host, kv } = makeHost({ variant: "scratchpad" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    const field = findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Note for this workspace")!
    host.dispatch("m", field, "submit", { text: "buy coffee" })
    await host.settle(10)
    expect(texts(host, "m")).toContain("buy coffee")
    const pad = (kv.get("notes.v1") as { notes: Array<{ id: string; body: string }> }).notes.find((n) => n.id === "note_pad")!
    expect(pad.body.endsWith("buy coffee")).toBe(true)
  })

  test("list variant: tapping a row opens it inline; tapping a checkbox toggles it", async () => {
    const { host, kv } = makeHost({ variant: "list" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    expect(texts(host, "m")).not.toContain("tag")
    const row = findVisible(host, "m", (n) => n.type === "Row" && n.props.title === "Release checklist")!
    host.dispatch("m", row, "tap")
    await host.settle(5)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["tag", "notes", "announce"]))
    const notesLine = visible(host, "m").find(([, n]) => n.type === "HStack" && n.props.onTap)!
    host.dispatch("m", notesLine[0], "tap")
    await host.settle(10)
    const saved = (kv.get("notes.v1") as { notes: Array<{ id: string; body: string }> }).notes.find((n) => n.id === "note_a")!
    expect(saved.body).toBe("- [ ] tag\n- [ ] notes\n- [ ] announce")
  })

  test("list variant: search filters rows", async () => {
    const { host } = makeHost({ variant: "list" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    const search = findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Search notes")!
    host.dispatch("m", search, "edit", { text: "export" })
    await host.settle(5)
    const rows = nodesOf(host, "m", "Row").map(([, n]) => n.props.title)
    expect(rows).toEqual(["Ideas"])
  })

  test("split variant: tap shows the editor in place; back returns to the list", async () => {
    const { host } = makeHost({ variant: "split" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    const row = findVisible(host, "m", (n) => n.type === "Row" && n.props.title === "Ideas")!
    host.dispatch("m", row, "tap")
    await host.settle(5)
    expect(nodesOf(host, "m", "Row")).toHaveLength(0)
    const title = findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Ideas")!
    host.dispatch("m", title, "submit", { text: "Product ideas" })
    await host.settle(10)
    expect((await run(host, "read", { id: "note_b" })).body.value.title).toBe("Product ideas")
    const back = findVisible(host, "m", (n) => n.type === "Button" && n.props.help === "Back")!
    host.dispatch("m", back, "tap")
    await host.settle(5)
    expect(nodesOf(host, "m", "Row").map(([, n]) => n.props.title)).toContain("Product ideas")
  })

  test("pane: list and editor side by side, empty editor until a note is chosen", async () => {
    const { host } = makeHost({}, seeded)
    expect(host.mount("p", "renderNotesPane", { surface: "pane" })).toBe("")
    await host.settle(10)
    expect(texts(host, "p")).toEqual(expect.arrayContaining(["Release checklist", "Select a note"]))
  })

  test("New Note (user command) selects the new note in a mounted surface", async () => {
    const { host } = makeHost({ variant: "split" }, seeded)
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    await run(host, "newNote")
    await host.settle(5)
    expect(nodesOf(host, "m", "Row")).toHaveLength(0) // the editor replaced the list
    expect(findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Title")).toBeDefined()
  })

  test("empty and error states", async () => {
    const { host } = makeHost({ variant: "list" })
    host.mount("m", "renderNotes", {})
    await host.settle(10)
    expect(texts(host, "m")).toContain("No notes")
    const broken = makeHost({ variant: "list" }).host
    broken.handlers["app.storage.get"] = () => ({ ok: false, body: { code: "storage.unavailable", message: "disk full" } })
    broken.mount("m", "renderNotes", {})
    await broken.settle(10)
    expect(texts(broken, "m")).toContain("Cannot load notes")
  })
})
