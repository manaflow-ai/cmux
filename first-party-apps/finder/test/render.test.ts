import { describe, expect, test } from "bun:test"
import type { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { answer, callsOf, fixture, makeHost, tap, texts, visible } from "./harness.ts"

const M = "m1"

async function mountPane(fixture: string, settings: Record<string, unknown> = {}, overrides: Record<string, unknown> = {}) {
  const host = makeHost(fixture, settings, overrides)
  expect(host.mount(M, "renderFinder", {})).toBe("")
  await host.settle(20)
  return host
}

async function tapSymbol(host: FakeHost, symbol: string, nth = 0) {
  const { nodes } = host.tree(M)
  const parentOf = new Map<string, string>()
  for (const [id, n] of nodes) for (const c of n.children) parentOf.set(c, id)
  const icons = visible(host, M).filter(([, n]) => n.type === "Icon" && n.props.symbol === symbol)
  let id: string | undefined = icons[nth]?.[0]
  while (id && !nodes.get(id)!.props.onTap) id = parentOf.get(id)
  if (!id) throw new Error(`no tappable ${symbol}`)
  host.dispatch(M, id, "tap", { gesture: "gst_test" })
  await host.settle(10)
}

async function pickMenu(host: FakeHost, rowText: string, title: string) {
  const { nodes } = host.tree(M)
  const parentOf = new Map<string, string>()
  for (const [id, n] of nodes) for (const c of n.children) parentOf.set(c, id)
  let id = visible(host, M).find(([, n]) => n.props.text === rowText)?.[0]
  while (id && !nodes.get(id)!.props.menu) id = parentOf.get(id)
  if (!id) throw new Error(`no menu on ${rowText}`)
  const menu = nodes.get(id)!.props.menu as Array<{ title?: string }>
  const index = menu.findIndex((m) => m.title === title)
  host.dispatch(M, id, "menu", { path: [index], gesture: "gst_test" })
  await host.settle(10)
}

describe("list + preview variant", () => {
  test("lists the first root through fs.list with the owner-side sort, hidden files filtered", async () => {
    const host = await mountPane("listPreview")
    const t = texts(host, M)
    expect(t).toContain("Desktop")
    expect(t).toContain("notes.md")
    expect(t).not.toContain(".config")
    const [list] = callsOf(host, "fs.list")
    expect(list!.params).toMatchObject({ conn: "conn_local01", root: "root_home01", path: "", limit: 200, sort: { key: "name", dir: "asc", dirs_first: true } })
    // The watch is subscribed for exactly this folder.
    expect([...host.subscriptions.values()].find((s) => s.stream === "fs.watch")?.filter).toEqual({ conn: "conn_local01", root: "root_home01", path: "" })
  })

  test("tap selects and previews; a second tap opens the document with the gesture", async () => {
    const host = await mountPane("listPreview")
    await tap(host, M, "notes.md")
    expect(callsOf(host, "fs.read")[0]!.params).toMatchObject({ path: "notes.md", max_bytes: 32768 })
    expect(texts(host, M)).toContain("Release notes draft")
    await tap(host, M, "notes.md")
    const open = callsOf(host, "document.open")[0]!
    expect(open.params).toMatchObject({ conn: "conn_local01", root: "root_home01", path: "notes.md" })
    expect(open.options.gesture).toBe("gst_test")
  })

  test("watch events update rows without a relist", async () => {
    const host = await mountPane("listPreview")
    const before = callsOf(host, "fs.list").length
    host.emit("fs.watch", { conn: "conn_local01", root: "root_home01", path: "", event: { kind: "created", revision: "1043", entry: { name: "fresh.txt", kind: "file", size: 3, mtime: 1 } } })
    host.emit("fs.watch", { conn: "conn_local01", root: "root_home01", path: "", event: { kind: "deleted", revision: "1044", name: "todo.txt" } })
    await host.settle(10)
    expect(texts(host, M)).toContain("fresh.txt")
    expect(texts(host, M)).not.toContain("todo.txt")
    expect(callsOf(host, "fs.list").length).toBe(before)
    host.emit("fs.watch", { conn: "conn_local01", root: "root_home01", path: "", event: { kind: "overflow", revision: "1045" } })
    await host.settle(10)
    expect(callsOf(host, "fs.list").length).toBe(before + 1)
  })

  test("opening a folder lists it and updates the path bar", async () => {
    const host = await mountPane("listPreview")
    await tap(host, M, "src")
    await tap(host, M, "src")
    expect(callsOf(host, "fs.list").at(-1)!.params).toMatchObject({ path: "src" })
  })

  test("context menu sends typed items to the terminal, never a path string", async () => {
    const host = await mountPane("listPreview", {}, { "terminal.drop": { action: "insert_path" } })
    await pickMenu(host, "notes.md", "Insert Path in Terminal")
    const call = callsOf(host, "terminal.drop")[0]!
    expect(call.params.items).toEqual([{ kind: "file", ref: { conn: "conn_local01", root: "root_home01", path: "notes.md" }, display: "~/notes.md", name: "notes.md", dir: false }])
    expect(call.options.gesture).toBe("gst_test")
  })

  test("large directories page through cursor batches", async () => {
    const first = fixture("large").ops["fs.list"] as { entries: unknown[] }
    const second = { listing: "lst_big01", entries: Array.from({ length: 200 }, (_, i) => ({ name: `trace-${String(i + 201).padStart(6, "0")}.log`, kind: "file", size: 1, mtime: 1 })), cursor: "cur_0400", total: 100_000, revision: "1042" }
    const host = await mountPane("large", {}, { "fs.list": { $sequence: [first, second] } })
    expect(texts(host, M)).toContain("1–22 of 100,000")
    // Paging inside the loaded 200 rows asks the owner for nothing.
    for (let i = 0; i < 8; i++) await tapSymbol(host, "chevron.right")
    expect(callsOf(host, "fs.list")).toHaveLength(1)
    expect(texts(host, M)).toContain("177–198 of 100,000")
    // The page that reaches past them fetches the next batch with the cursor.
    await tapSymbol(host, "chevron.right")
    expect(callsOf(host, "fs.list")[1]!.params).toMatchObject({ cursor: "cur_0200", listing: "lst_big01" })
    expect(texts(host, M)).toContain("199–220 of 100,000")
    expect(texts(host, M)).toContain("trace-000201.log")
  })
})

describe("states", () => {
  test("missing platform ops show what is missing", async () => {
    const host = await mountPane("missing")
    expect(texts(host, M)).toContain("File access is not available yet")
  })

  test("errors keep a retry", async () => {
    const host = await mountPane("error")
    expect(texts(host, M)).toContain("You do not have permission to see this folder")
    const before = callsOf(host, "fs.list").length
    await tap(host, M, "Try Again")
    expect(callsOf(host, "fs.list").length).toBe(before + 1)
  })

  test("a connecting host lists only once the connection is up", async () => {
    const host = await mountPane("connecting")
    expect(texts(host, M)).toContain("Connecting to build-box…")
    expect(callsOf(host, "fs.list")).toHaveLength(0)
    host.emit("host.watch", { conn: { conn: "conn_ssh01", host: null, kind: "ssh", label: "build-box", state: "connected" } })
    await host.settle(20)
    expect(callsOf(host, "fs.list")[0]!.params).toMatchObject({ conn: "conn_ssh01", root: "root_ssh01" })
  })

  test("empty folder", async () => {
    const host = await mountPane("empty")
    expect(texts(host, M)).toContain("Folder is empty")
  })
})

describe("jobs", () => {
  test("progress, conflicts and undo follow the fs.job stream", async () => {
    const host = await mountPane("copy", {}, { "fs.job.resolve": {}, "fs.undo": {} })
    expect(texts(host, M)).toContain("Copying 3 items to acme team VM")
    expect(texts(host, M)).toContain("“deploy-checklist.md” already exists in studio")
    await tap(host, M, "Replace")
    expect(callsOf(host, "fs.job.resolve")[0]!.params).toEqual({ job: "job_copy02", choice: "replace", apply_to_all: false })
    host.emit("fs.job", { job: "job_copy01", event: { kind: "progress", seq: 42, bytes_done: 2_010_000_000, items_done: 2, eta_s: 30 } })
    await host.settle(10)
    expect(texts(host, M)).toContain("2.0 GB of 4.0 GB · 30 s left · between hosts")
    host.emit("fs.job", { job: "job_copy01", event: { kind: "done", seq: 43, undo: "undo_c1" } })
    await host.settle(10)
    expect(texts(host, M)).toContain("Copied 3 items to acme team VM")
    await tap(host, M, "Undo")
    expect(callsOf(host, "fs.undo")[0]!.params).toEqual({ undo: "undo_c1" })
  })
})

describe("columns variant", () => {
  test("each folder opens a column to the right", async () => {
    const host = await mountPane("columns", { variant: "columns" })
    await tap(host, M, "src")
    await tap(host, M, "orbit")
    const paths = callsOf(host, "fs.list").map((c) => c.params.path)
    expect(paths).toEqual(["", "src", "src/orbit"])
    expect(texts(host, M)).toContain("Package.swift")
  })
})

describe("dual pane variant", () => {
  test("copies the left selection to the right host through fs.copy", async () => {
    const host = await mountPane("dualPane", { variant: "dualPane" }, { "fs.copy": { job: "job_new01", subject: "build.log", destination: "acme team VM", cross_host: true } })
    const roots = callsOf(host, "fs.list").map((c) => c.params.root)
    expect(roots).toEqual(["root_home01", "root_team01"])
    await tap(host, M, "build.log")
    await tap(host, M, "Copy →")
    const copy = callsOf(host, "fs.copy")[0]!
    expect(copy.params).toMatchObject({ from: { conn: "conn_local01", root: "root_home01", paths: ["build.log"] }, to: { conn: "conn_team01", root: "root_team01", path: "" }, conflict: "ask" })
    expect(copy.options.gesture).toBe("gst_test")
    expect(texts(host, M)).toContain("Copying build.log to acme team VM")
  })
})

describe("sidebar and commands", () => {
  test("sidebar lists favorites, hosts and recent; Connect opens the host's sheet", async () => {
    const host = makeHost("listPreview", {}, { "host.connect": { conn: { conn: "conn_ssh02", host: null, kind: "ssh", label: "gpu-box", state: "connecting" } } })
    expect(host.mount("s1", "renderFiles", {})).toBe("")
    await host.settle(20)
    const t = texts(host, "s1")
    for (const s of ["Home", "acme team VM", "build-box", "Connect to Host…", "Recent", "Sources"]) expect(t).toContain(s)
    await tap(host, "s1", "Connect to Host…")
    expect(callsOf(host, "host.connect")[0]!.options.gesture).toBe("gst_test")
    expect(texts(host, "s1")).toContain("gpu-box")
  })

  test("cycleVariant switches the pane design even when settings cannot be saved", async () => {
    const host = await mountPane("columns")
    expect(texts(host, M)).toContain("Date Modified")
    const cb = 7
    host.global.__cmuxAppRunCommand("cycleVariant", "{}", cb)
    await host.settle(20)
    expect(host.commandResults.get(cb)?.body.value).toMatchObject({ variant: "columns" })
    expect(texts(host, M)).not.toContain("Date Modified")
  })

  test("unknown op answers stay inside the app (no throw)", () => {
    expect(answer({ $error: { code: "x" } })()).toEqual({ ok: false, body: { code: "x" } })
  })
})
