import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const source = readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const hints = [
  { label: "a", text: "Home", href: "https://example.com/" },
  { label: "sa", text: "Docs", href: "https://example.com/docs" },
  { label: "sd", text: "Blog", href: "https://example.com/blog" }
]

function host() {
  const h = new FakeHost(source, { app: { id: "cmux/link-hints", version: "1.0.0" }, apiVersion: "1.0.0" })
  h.handlers["page.hints"] = (p) => ok({ tab: "tab_3", hints: p.action === "show" ? hints : [] })
  h.handlers["page.follow"] = (p) => {
    const hit = hints.find((x) => x.label === p.label)
    return ok({ tab: p.tab ?? "tab_3", followed: !!hit, href: hit?.href ?? null })
  }
  return h
}
/** The nodes reachable from the root (a replaced subtree may stay in the map). */
function live(h: FakeHost, mount: string) {
  const { root, nodes } = h.tree(mount)
  const out: Array<[string, { type: string; props: Record<string, unknown> }]> = []
  const walk = (id: string) => {
    const n = nodes.get(id)
    if (!n) return
    out.push([id, n])
    n.children.forEach(walk)
  }
  walk(root)
  return out
}
const texts = (h: FakeHost, mount: string) => live(h, mount).map(([, n]) => n).flatMap((n) => [n.props.text, n.props.title, n.props.message, n.props.badge]).filter((t) => typeof t === "string")
const calls = (h: FakeHost, name: string) => h.calls.filter((c) => c.name === name)
const field = (h: FakeHost) => live(h, "m").find(([, n]) => n.type === "TextField")?.[0]

describe("link-hints", () => {
  test("Link hints shows labels, typing a complete label follows it", async () => {
    const h = host()
    h.mount("m", "renderHints")
    await h.settle()
    expect(field(h)).toBeUndefined()
    h.runCommand("show", {}, 1, { gesture: "g-1" })
    await h.settle(10)
    expect(h.commandResults.get(1)).toMatchObject({ ok: true })
    const show = calls(h, "page.hints")[0]!
    expect([show.params, show.options.gesture]).toEqual([{ action: "show" }, "g-1"])
    expect(texts(h, "m")).toEqual(expect.arrayContaining(["Home", "Docs", "Blog", "sa", "Type a label to follow it"]))
    const f = field(h)!
    expect(h.tree("m").nodes.get(f)!.props.autofocus).toBe(true)
    // "s" is a prefix of two labels: no follow yet, the rows narrow.
    h.dispatch("m", f, "edit", { text: "s", gesture: "k-1" })
    await h.settle()
    expect(calls(h, "page.follow")).toEqual([])
    expect(texts(h, "m")).not.toContain("Home")
    h.dispatch("m", f, "edit", { text: "sd", gesture: "k-2" })
    await h.settle(10)
    const follow = calls(h, "page.follow")
    expect(follow.map((c) => [c.params, c.options.gesture])).toEqual([[{ tab: "tab_3", label: "sd", new_split: false }, "k-2"]])
    // The picker closes; nothing is cleared, the page dropped its labels when it followed.
    expect(field(h)).toBeUndefined()
    expect(calls(h, "page.hints").length).toBe(1)
  })

  test("open in new split follows with new_split, from a row click", async () => {
    const h = host()
    h.mount("m", "renderHints")
    h.runCommand("showSplit", {}, 2, { gesture: "g-2" })
    await h.settle(10)
    expect(texts(h, "m")).toContain("Type a label to open it in a new split")
    const row = h.findNode("m", (n) => n.type === "Row" && n.props.title === "Docs")!
    h.dispatch("m", row, "tap", { gesture: "t-1" })
    await h.settle(10)
    expect(calls(h, "page.follow").map((c) => c.params)).toEqual([{ tab: "tab_3", label: "sa", new_split: true }])
  })

  test("Escape clears the labels", async () => {
    const h = host()
    h.mount("m", "renderHints")
    h.runCommand("show", {}, 3)
    await h.settle(10)
    h.dispatch("m", field(h)!, "cancel", { gesture: "esc" })
    await h.settle(10)
    const clear = calls(h, "page.hints").at(-1)!
    expect([clear.params, clear.options.gesture]).toEqual([{ tab: "tab_3", action: "clear" }, "esc"])
    expect(calls(h, "page.follow")).toEqual([])
    expect(field(h)).toBeUndefined()
    expect(texts(h, "m")).toContain("Show link hints")
  })

  test("Return on an unknown label keeps the picker and says so", async () => {
    const h = host()
    h.mount("m", "renderHints")
    h.runCommand("show", {}, 4)
    await h.settle(10)
    h.dispatch("m", field(h)!, "submit", { text: "zz" })
    await h.settle(10)
    expect(calls(h, "page.follow")).toEqual([])
    expect(texts(h, "m")).toContain("No link labeled zz")
    expect(field(h)).toBeDefined()
  })

  test("the follow and clear commands reach the page ops (CLI and MCP path)", async () => {
    const h = host()
    h.runCommand("follow", { label: "a", new_split: true }, 5, { gesture: "g-5" })
    h.runCommand("clear", {}, 6)
    await h.settle(10)
    expect(h.commandResults.get(5)).toEqual({ ok: true, body: { value: { tab: "tab_3", followed: true, href: "https://example.com/" } } })
    expect(calls(h, "page.follow").map((c) => c.params)).toEqual([{ label: "a", new_split: true }])
    expect(calls(h, "page.hints").map((c) => c.params)).toEqual([{ action: "clear" }])
  })
})
