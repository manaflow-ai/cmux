import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const source = readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const article = {
  tab: "tab_7",
  url: "https://example.com/post",
  title: "A post · Example",
  article: {
    title: "A post",
    byline: "Ada Lovelace",
    site: "Example",
    blocks: [
      { kind: "heading", text: "Intro", level: 2 },
      { kind: "paragraph", text: "First paragraph." },
      { kind: "list_item", text: "One item" },
      { kind: "quote", text: "A quote." },
      { kind: "code", text: "let x = 1" },
      { kind: "image", text: "A chart", src: "https://example.com/chart.png" }
    ]
  },
  links: [{ text: "Home", href: "https://example.com/" }]
}

function host() {
  const h = new FakeHost(source, { app: { id: "cmux/reader-mode", version: "1.0.0" }, apiVersion: "1.0.0" })
  h.handlers["app.storage.get"] = () => ok(null)
  h.handlers["app.storage.set"] = () => ok(null)
  h.handlers["page.read"] = () => ok(article)
  h.handlers["action.run"] = () => ok(null)
  h.fallback = (name) => (name.startsWith("action") ? ok(null) : { ok: false, body: { code: "operation.unsupported", message: name, retryable: false } })
  return h
}
const texts = (h: FakeHost, mount: string) => [...h.tree(mount).nodes.values()].flatMap((n) => [n.props.text, n.props.title, n.props.message]).filter((t) => typeof t === "string")

describe("reader-mode", () => {
  test("the pane starts empty with Read this page", async () => {
    const h = host()
    h.mount("m", "renderReader")
    await h.settle()
    expect(texts(h, "m")).toEqual(expect.arrayContaining(["Read this page", "No page read yet"]))
    expect(h.calls.some((c) => c.name === "page.read")).toBe(false)
  })

  test("the command reads the page, opens the pane and the pane renders every block", async () => {
    const h = host()
    h.mount("m", "renderReader")
    h.runCommand("open", {}, 3, { gesture: "g-1" })
    await h.settle(10)
    const result = h.commandResults.get(3)!
    expect(result.ok).toBe(true)
    expect(result.body.value).toMatchObject({ title: "A post", url: "https://example.com/post", blocks: 6 })
    const read = h.calls.find((c) => c.name === "page.read")!
    expect(read.params).toEqual({})
    expect(read.options.gesture).toBe("g-1")
    expect(h.calls.find((c) => c.name === "app.storage.set")!.params).toMatchObject({ key: "last" })
    const t = texts(h, "m")
    expect(t).toEqual(expect.arrayContaining(["A post", "Ada Lovelace · Example", "Intro", "First paragraph.", "One item", "A quote.", "let x = 1", "A chart", "Links (1)", "Home"]))
    expect(t).not.toContain("No page read yet")
    const opened = h.calls.find((c) => c.name === "action.run")!
    expect([opened.params, opened.options.gesture]).toEqual([{ id: "app.open", args: { app: "cmux/reader-mode" } }, "g-1"])
  })

  test("Read this page in the pane reads again; a failure shows its message", async () => {
    const h = host()
    h.handlers["page.read"] = () => ({ ok: false, body: { code: "page.no_browser", message: "No browser tab is focused", retryable: false } })
    h.mount("m", "renderReader")
    await h.settle()
    const button = h.findNode("m", (n) => n.type === "Button" && n.props.title === "Read this page")!
    h.dispatch("m", button, "tap", { gesture: "g-2" })
    await h.settle(10)
    expect(texts(h, "m")).toEqual(expect.arrayContaining(["Cannot read this page", "No browser tab is focused"]))
    h.handlers["page.read"] = () => ok(article)
    h.dispatch("m", button, "tap", { gesture: "g-3" })
    await h.settle(10)
    expect(texts(h, "m")).toContain("First paragraph.")
    expect(texts(h, "m")).not.toContain("Cannot read this page")
  })

  test("a reload shows the stored article without reading the page", async () => {
    const h = host()
    h.handlers["app.storage.get"] = () => ok(article)
    h.mount("m", "renderReader")
    await h.settle(10)
    expect(texts(h, "m")).toContain("A quote.")
    expect(h.calls.some((c) => c.name === "page.read")).toBe(false)
  })
})
