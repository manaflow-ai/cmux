import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const root = join(import.meta.dir, "..")
const main = readFileSync(join(root, "dist/main.js"), "utf8")
const fixture = (name: string) => JSON.parse(readFileSync(join(root, "preview", name), "utf8")).ops as Record<string, any>

function host(variant: string, fixtureName = "full.json") {
  const h = new FakeHost(main, { app: { id: "cmux/search", version: "0.1.0" }, apiVersion: "1.0.0", settings: { variant } })
  const ops = fixture(fixtureName)
  for (const [op, v] of Object.entries(ops)) {
    h.handlers[op] = () => (v && typeof v === "object" && "$error" in v ? { ok: false, body: v.$error } : { ok: true, body: { value: v && typeof v === "object" && "$sequence" in v ? null : v } })
  }
  for (const op of ["tab.focus", "workspace.focus", "action.run", "terminal.viewport.reveal", "app.storage.set", "app.storage.delete"]) h.handlers[op] ??= () => ({ ok: true, body: { value: null } })
  return h
}

/** Text of every node reachable from the root (FakeHost keeps removed subtrees' children in its map). */
function reachable(h: FakeHost, mount = "m") {
  const { root, nodes } = h.tree(mount)
  const out: Array<[string, { type: string; props: Record<string, unknown>; children: string[] }]> = []
  const walk = (id: string) => {
    const n = nodes.get(id)
    if (!n) return
    out.push([id, n])
    n.children.forEach(walk)
  }
  walk(root)
  return out
}
const texts = (h: FakeHost, mount = "m") => reachable(h, mount).map(([, n]) => String(n.props.title ?? n.props.text ?? "")).filter(Boolean)
const field = (h: FakeHost, mount = "m") => h.findNode(mount, (n) => n.type === "TextField")!

async function type(h: FakeHost, text: string, mount = "m") {
  h.dispatch(mount, field(h, mount), "submit", { text })
  await h.settle(10)
}

describe("search app renders", () => {
  test("grouped: grouped native rows; a tap shows the tab with origin user", async () => {
    const h = host("grouped")
    expect(h.mount("m", "renderSection", { contribution: "cmux/search#sidebar" })).toBe("")
    await h.settle()
    expect(texts(h)).toContain("Search Everything")
    await type(h, "auth")
    const shown = texts(h)
    for (const s of ["Workspaces", "Terminals", "Browser", "Apps", "Files", "auth tests", "auth migration", "Auth rollout plan", "auth.ts"]) expect(shown).toContain(s)
    const top = h.findNode("m", (n) => n.type === "Row" && n.props.title === "auth tests")!
    expect(h.tree("m").nodes.get(top)!.props.selected).toBe(true)
    h.dispatch("m", top, "tap")
    await h.settle()
    expect(h.calls.find((c) => c.name === "tab.focus")!.params).toEqual({ tab: "tab_2", workspace: "workspace_api" })
    expect(h.calls.find((c) => c.name === "app.storage.set" && c.params.key === "recent")!.params.value).toEqual(["auth"])
  })

  test("grouped: Return on current results opens the top hit; Escape clears", async () => {
    const h = host("grouped")
    h.mount("m", "renderSection")
    await type(h, "auth")
    await type(h, "auth")
    expect(h.calls.filter((c) => c.name === "tab.focus")).toHaveLength(1)
    h.dispatch("m", field(h), "cancel")
    await h.settle()
    expect(texts(h)).not.toContain("auth tests")
  })

  test("typing debounces with one one-shot timer", async () => {
    const h = host("grouped")
    h.mount("m", "renderSection")
    await h.settle()
    h.dispatch("m", field(h), "edit", { text: "au" })
    h.dispatch("m", field(h), "edit", { text: "auth" })
    expect([...h.timers.values()]).toEqual([{ ms: 150, repeat: false }])
    expect(h.calls.some((c) => c.name === "session.snapshot")).toBe(false)
    h.global.__cmuxAppTimer([...h.timers.keys()][0])
    await h.settle(10)
    expect(h.calls.filter((c) => c.name === "session.snapshot")).toHaveLength(1)
    expect(texts(h)).toContain("auth tests")
  })

  test("preview: a tap selects and previews; Open reveals the matched terminal row", async () => {
    const h = host("preview")
    h.mount("m", "renderPane", { contribution: "cmux/search#pane" })
    await type(h, "auth")
    for (const s of ["All", "Terminals", ".*", "Everywhere", "Open"]) expect(texts(h)).toContain(s)
    const zsh = h.findNode("m", (n) => n.type === "Row" && n.props.title === "zsh")!
    h.dispatch("m", zsh, "tap")
    await h.settle()
    expect(h.tree("m").nodes.get(zsh)!.props.selected).toBe(true)
    expect(texts(h)).toContain("/refresh 401 Unauthorized (token expired) 12ms")
    expect(texts(h).filter((x) => x === "Open")).toHaveLength(1)
    expect(h.calls.some((c) => c.name === "tab.focus")).toBe(false)
    h.dispatch("m", reachable(h).find(([, n]) => n.type === "Button" && n.props.title === "Open")![0], "tap")
    await h.settle()
    expect(h.calls.find((c) => c.name === "tab.focus")!.params).toEqual({ tab: "tab_1", workspace: "workspace_api" })
    expect(h.calls.find((c) => c.name === "terminal.viewport.reveal")!.params).toEqual({ terminal: "terminal_1", row: "row_8812" })
  })

  test("preview: a source chip narrows the search to that source", async () => {
    const h = host("preview")
    h.mount("m", "renderPane")
    await type(h, "auth")
    const before = h.calls.length
    h.dispatch("m", h.findNode("m", (n) => n.type === "Text" && n.props.text === "Files")!, "tap")
    await h.settle(10)
    const ops = h.calls.slice(before).map((c) => c.name)
    expect(ops).toContain("fs.search")
    expect(ops).not.toContain("terminal.search")
    expect(texts(h)).not.toContain("auth tests")
  })

  test("palette: one ranked list with highlights; a tap runs the item's open action", async () => {
    const h = host("palette")
    h.mount("m", "renderSection")
    await type(h, "auth")
    expect(texts(h)).toContain("↩ Open  ⎋ Clear")
    expect(texts(h)).not.toContain("Terminals")
    const note = h.findNode("m", (n) => n.type === "Text" && n.props.text === "Auth")!
    expect(h.tree("m").nodes.get(note)!.props.color).toBe("accent")
    const row = reachable(h).find(([, n]) => n.type === "HStack" && n.props.onTap && n.props.help === "Notes · edited yesterday")![0]
    h.dispatch("m", row, "tap")
    await h.settle()
    expect(h.calls.find((c) => c.name === "action.run")!.params).toEqual({ id: "app.cmux/notes#openNote", args: { id: "note_17" } })
  })

  test("today (no proposed ops): visible screens, names, and what is missing", async () => {
    const h = host("grouped", "today.json")
    h.mount("m", "renderSection")
    await type(h, "auth")
    const shown = texts(h)
    expect(shown).toContain("auth tests")
    expect(shown).toContain("File search needs fs.search")
    expect(shown).toContain("Terminal history needs terminal.search (searched visible screens only)")
    expect(h.calls.filter((c) => c.name === "terminal.screen.read").length).toBe(3)
  })

  test("the search command returns JSON and never moves focus", async () => {
    const h = host("grouped")
    h.global.__cmuxAppRunCommand("search", JSON.stringify({ query: "t: auth", limit: 2 }), 7)
    await h.settle(10)
    const r = h.commandResults.get(7)!
    expect(r.ok).toBe(true)
    expect(r.body.value.results).toHaveLength(2)
    expect(r.body.value.results.every((x: { source: string }) => x.source === "terminals")).toBe(true)
    expect(h.calls.some((c) => ["tab.focus", "workspace.focus", "action.run"].includes(c.name))).toBe(false)
  })

  test("Next Search Variant switches the mounted design and remembers it", async () => {
    const h = host("grouped")
    h.mount("m", "renderSection")
    await type(h, "auth")
    expect(texts(h)).toContain("Workspaces")
    h.global.__cmuxAppRunCommand("cycleVariant", "{}", 1)
    await h.settle(10)
    expect(h.commandResults.get(1)!.body.value).toEqual({ variant: "preview" })
    expect(h.calls.find((c) => c.name === "app.storage.set" && c.params.key === "variant")!.params.value).toBe("preview")
    expect(texts(h)).toContain(".*")
  })
})
