import { describe, expect, test } from "bun:test"
import { FOCUS_OPS, findVisible, makeHost, menu, nodesOf, run, tap, texts, visible } from "./harness.ts"

const focusCalls = (host: ReturnType<typeof makeHost>["host"]) => host.calls.filter((c) => FOCUS_OPS.includes(c.name))
const rowTitles = (host: ReturnType<typeof makeHost>["host"], m = "m") => nodesOf(host, m, "Row").map(([, n]) => n.props.title)
const PAD = "note_pad0000000000000"
const LIST = "note_a000000000000000"

describe("agent tools (commands forward to the notes server's ops)", () => {
  test("create, list, read, append, capture, search; list never returns bodies; no focus op", async () => {
    const { host, server } = makeHost({ seeds: [] })
    const created = await run(host, "create", { title: "Deploy", body: "step 1", workspace: "current" })
    expect(created.ok).toBe(true)
    expect(host.calls.find((c) => c.name === "note.create")!.params).toEqual({ title: "Deploy", body: "step 1", workspace: "current", pinned: false })
    const id = created.body.value.id
    expect(created.body.value.body).toBeUndefined()
    expect(created.body.value.workspace).toEqual({ id: "workspace_api", name: "api" })
    expect((await run(host, "append", { id, text: "step 2" })).body.value.lines).toBe(2)
    const listed = (await run(host, "list", {})).body.value.notes
    expect(listed).toHaveLength(1)
    expect(listed[0].body).toBeUndefined()
    expect((await run(host, "read", { id })).body.value.body).toBe("step 1\nstep 2")
    expect(host.calls.find((c) => c.name === "note.get")!.params).toEqual({ note: id })
    const captured = (await run(host, "capture", { text: "Call the vendor\nabout invoices" })).body.value
    expect(captured.title).toBe("Call the vendor")
    expect((await run(host, "search", { query: "vendor" })).body.value.results.map((r: { id: string }) => r.id)).toEqual([captured.id])
    expect(server.notes.size).toBe(2)
    expect(focusCalls(host)).toEqual([])
    expect(host.calls.some((c) => c.name.startsWith("app.storage"))).toBe(false)
  })

  test("append by workspace goes to its scratchpad (the server creates it once)", async () => {
    const { host, server } = makeHost({ seeds: [] })
    await run(host, "append", { workspace: "web", text: "one" })
    await run(host, "append", { workspace: "workspace_web", text: "two" })
    const pads = [...server.notes.values()].filter((n) => n.scratchpad)
    expect(pads).toHaveLength(1)
    expect(pads[0]!.body).toBe("one\ntwo")
    expect(host.calls.filter((c) => c.name === "note.append").map((c) => c.params)).toEqual([
      { workspace: "web", text: "one" },
      { workspace: "workspace_web", text: "two" }
    ])
  })

  test("errors carry stable codes", async () => {
    const { host } = makeHost()
    expect((await run(host, "read", { id: "note_missing0000000" })).body.code).toBe("selector.not_found")
    expect((await run(host, "append", { text: "x" })).body.code).toBe("invalid_params")
    expect((await run(host, "append", { id: "a", workspace: "api", text: "x" })).body.code).toBe("invalid_params")
    expect((await run(host, "capture", {})).body.code).toBe("invalid_params")
    expect((await run(host, "create", { body: "x", workspace: "nope" })).body.code).toBe("selector.not_found")
  })

  test("without the notes server the tools answer operation.unsupported", async () => {
    const { host } = makeHost({ unavailable: true })
    expect((await run(host, "list", {})).body.code).toBe("operation.unsupported")
  })
})

describe("surfaces follow the server's stream", () => {
  test("scratchpad variant: this workspace's scratchpad open on top, other notes below", async () => {
    const { host } = makeHost({ settings: { variant: "scratchpad" } })
    expect(host.mount("m", "renderNotes", { contribution: "cmux/notes#notes", surface: "sidebarSection" })).toBe("")
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["api", "check flaky test", "port 3001 busy", "Release checklist", "Ideas"]))
    expect(rowTitles(host)).not.toContain("api")
    expect(host.timers.size).toBe(0) // no polling
    expect([...host.subscriptions.values()].map((s) => s.stream)).toEqual(expect.arrayContaining(["note.watch", "workspace.changed"]))
    expect(host.calls.some((c) => c.name.startsWith("app.storage"))).toBe(false)
  })

  test("an agent's write arrives through note.watch without moving focus or selection", async () => {
    const { host, server, emit } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    tap(host, "m", findVisible(host, "m", (n) => n.type === "Row" && n.props.title === "Ideas")!)
    await host.settle(20)
    emit(server.append({ note: PAD, text: "deploy at 5pm" }, "agent").events[0])
    emit(server.external(LIST, "- [x] tag\n- [x] notes\n- [ ] announce"))
    await host.settle(20)
    const pad = nodesOf(host, "m", "Row").find(([, n]) => n.props.title === "api")!
    expect(pad[1].props.symbol).toBe("sparkles")
    expect(String(pad[1].props.subtitle)).toContain("deploy at 5pm")
    expect(nodesOf(host, "m", "Row").find(([, n]) => n.props.selected === true)![1].props.title).toBe("Ideas")
    expect(focusCalls(host)).toEqual([])
  })

  test("a duplicate or older event changes nothing", async () => {
    const { host, server, emit } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const ev = server.external("note_b000000000000000", "Ideas v2\nfaster search")
    emit(ev, ev)
    await host.settle(20)
    expect(rowTitles(host)).toContain("Ideas v2")
    expect(host.calls.filter((c) => c.name === "note.list")).toHaveLength(1)
  })

  test("typing in the scratchpad field appends through note.append", async () => {
    const { host, server } = makeHost({ settings: { variant: "scratchpad" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const field = findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Note for this workspace")!
    host.dispatch("m", field, "submit", { text: "buy coffee" })
    await host.settle(20)
    expect(host.calls.find((c) => c.name === "note.append")!.params).toEqual({ workspace: "workspace_api", text: "buy coffee" })
    expect(server.get(PAD).body.endsWith("buy coffee")).toBe(true)
    expect(texts(host, "m")).toContain("buy coffee")
  })

  test("a checkbox tap edits the note's document at its revision; a conflict rebases onto the current text", async () => {
    const { host, server } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    tap(host, "m", findVisible(host, "m", (n) => n.type === "Row" && n.props.title === "Release checklist")!)
    await host.settle(20)
    expect(texts(host, "m")).toEqual(expect.arrayContaining(["tag", "notes", "announce"]))
    // Another device inserts a line above before the tap lands.
    server.external(LIST, "- [ ] write changelog\n- [x] tag\n- [ ] notes\n- [ ] announce", "user")
    const checks = visible(host, "m").filter(([, n]) => n.type === "HStack" && n.props.onTap)
    tap(host, "m", checks[1]![0]) // "notes", line 1 of the revision the view showed
    await host.settle(30)
    const edits = host.calls.filter((c) => c.name === "document.edit").map((c) => c.params)
    expect(edits[0]).toEqual({ doc: "doc_a000000000000000", base_revision: 1, edits: [{ start: 13, end: 14, text: "x" }] })
    expect(edits[1]).toMatchObject({ base_revision: 2 })
    expect(server.get(LIST).body).toBe("- [ ] write changelog\n- [x] tag\n- [x] notes\n- [ ] announce")
  })

  test("editor variant: a click opens the note's document in the native editor pane, with the tap's gesture", async () => {
    const { host } = makeHost({ settings: { variant: "editor" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    expect(nodesOf(host, "m", "TextField").map(([, n]) => n.props.placeholder)).toEqual(["Search notes"])
    const row = findVisible(host, "m", (n) => n.type === "Row" && n.props.title === "Ideas")!
    tap(host, "m", row)
    const call = host.calls.find((c) => c.name === "app.pane.open")!
    expect(call.params).toEqual({ contribution: "cmux/notes#editor", input: { doc: "doc_b000000000000000" }, placement: "right" })
    expect(call.options.gesture).toBe(`g_${row}`)
  })

  test("search asks the server; the latest query wins", async () => {
    const { host } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const search = findVisible(host, "m", (n) => n.type === "TextField" && n.props.placeholder === "Search notes")!
    host.dispatch("m", search, "edit", { text: "expo" })
    host.dispatch("m", search, "edit", { text: "export" })
    await host.settle(20)
    expect(host.calls.filter((c) => c.name === "note.list").at(-1)!.params).toEqual({ query: "export", limit: 50 })
    expect(rowTitles(host)).toEqual(["Ideas"])
  })

  test("New Note (user command) selects the new note in a mounted surface", async () => {
    const { host } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const r = await run(host, "newNote")
    await host.settle(20)
    expect(nodesOf(host, "m", "Row").find(([, n]) => n.props.selected === true)).toBeDefined()
    expect(r.body.value.id).toMatch(/^note_/)
  })

  test("no notes server: the section says so; empty server: onboarding", async () => {
    const missing = makeHost({ settings: { variant: "list" }, unavailable: true }).host
    missing.mount("m", "renderNotes", {})
    await missing.settle(20)
    expect(texts(missing, "m")).toContain("Notes are not available yet")
    const empty = makeHost({ settings: { variant: "list" }, seeds: [] }).host
    empty.mount("m", "renderNotes", {})
    await empty.settle(20)
    expect(texts(empty, "m")).toContain("No notes")
  })
})

describe("markdown export and import through picked handles", () => {
  const moreMenu = (host: ReturnType<typeof makeHost>["host"]) => visible(host, "m").find(([, n]) => n.type === "Button" && n.props.help === "More")!

  test("Export All writes one .md per note under the picked folder handle, never a raw path", async () => {
    const { host, server } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const [id, node] = moreMenu(host)
    const items = (node.props.menu as Array<{ title?: string }>).map((m) => m.title)
    menu(host, "m", id, [items.indexOf("Export All Notes as Markdown…")])
    await host.settle(30)
    const pick = host.calls.find((c) => c.name === "fs.pick")!
    expect(pick.params).toEqual({ mode: "folder", purpose: "export", create: true })
    expect(pick.options.gesture).toBe(`g_${id}`)
    expect(server.written.map((w) => w.path)).toEqual(["release-checklist.md", "ideas.md", "check-flaky-test.md"])
    expect(server.written.every((w) => w.root === "root_export1")).toBe(true)
    expect(server.written[0]!.text).toBe("# Release checklist\n\n- [x] tag\n- [ ] notes\n- [ ] announce\n")
    expect(host.calls.filter((c) => c.name === "fs.write").every((c) => c.params.exists === "unique")).toBe(true)
    expect(texts(host, "m")).toContain("Exported 3 notes to Notes export")
  })

  test("a row's Export as Markdown writes that note only", async () => {
    const { host, server } = makeHost({ settings: { variant: "list" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const [id, row] = visible(host, "m").find(([, n]) => n.type === "Row" && n.props.title === "Ideas")!
    const items = (row.props.menu as Array<{ title?: string }>).map((m) => m.title)
    menu(host, "m", id, [items.indexOf("Export as Markdown…")])
    await host.settle(30)
    expect(server.written.map((w) => w.path)).toEqual(["ideas.md"])
  })

  test("Import reads each picked file through its handle and creates one note each, once", async () => {
    const { host, server } = makeHost({ settings: { variant: "list" }, pickFiles: { "runbook.md": "# Runbook\n\nrestart the worker", "todo.md": "- [ ] ship" } })
    host.mount("m", "renderNotes", {})
    await host.settle(20)
    const [id, node] = moreMenu(host)
    const items = (node.props.menu as Array<{ title?: string }>).map((m) => m.title)
    menu(host, "m", id, [items.indexOf("Import Markdown Files…")])
    await host.settle(30)
    expect(host.calls.find((c) => c.name === "fs.pick")!.params).toEqual({ mode: "files", purpose: "import", accept: [".md", ".markdown", ".txt"], multiple: true })
    const creates = host.calls.filter((c) => c.name === "note.create")
    expect(creates.map((c) => c.params)).toEqual([{ title: "Runbook", body: "restart the worker" }, { body: "- [ ] ship" }])
    expect(creates.map((c) => c.options.idempotencyKey)).toEqual(["import:root_import1:runbook.md", "import:root_import1:todo.md"])
    expect(server.notes.size).toBe(5)
    expect(rowTitles(host)).toEqual(expect.arrayContaining(["Runbook", "ship"]))
    expect(texts(host, "m")).toContain("Imported 2 notes")
  })

  test("from the palette (no gesture) the panel is refused and nothing is written", async () => {
    const { host, server } = makeHost()
    expect((await run(host, "exportNotes", {})).body.code).toBe("gesture.required")
    expect((await run(host, "importNotes", {})).body.code).toBe("gesture.required")
    expect(server.written).toEqual([])
  })
})

describe("settings", () => {
  test("Next Notes Variant writes the setting through the config layer", async () => {
    const { host } = makeHost({ settings: { variant: "list" } })
    expect((await run(host, "cycleVariant")).body.value).toEqual({ variant: "editor" })
    expect(host.calls.find((c) => c.name === "app.settings.set")!.params).toEqual({ values: { variant: "editor" } })
  })
})
