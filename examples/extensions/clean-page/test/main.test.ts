// Clean this page in the fake host: the command's whole flow, and the sidebar's Restore.
import { beforeAll, describe, expect, test } from "bun:test"
import { join } from "node:path"
import { FakeHost, pack } from "cmux-extension-sdk/testing"

const dir = join(import.meta.dir, "..")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const fail = (code: string, message = code) => ({ ok: false, body: { code, message, retryable: false } })
let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

const read = {
  tab: "t1",
  url: "https://news.test/story",
  origin: "https://news.test",
  title: "A story",
  candidates: [
    { selector: "#ad-top", tag: "div", label: "Advertisement", width: 728, height: 90, fixed: false, area: 0.05 },
    { selector: "#cookie", tag: "div", text: "We use cookies", width: 1280, height: 120, fixed: true, area: 0.1 },
    { selector: "header.site", tag: "header", width: 1280, height: 64, fixed: true, area: 0.05 },
    { selector: "article.story", tag: "article", width: 700, height: 2000, fixed: false, area: 0.6 }
  ],
  truncated: false
}

function host(reply = '```json\n{"hide": ["#ad-top", "#cookie", "#invented", "article.story"], "unstick": ["header.site"]}\n```') {
  const h = new FakeHost(built, { app: { id: "local/showcase-clean-page", version: "1.0.0" }, apiVersion: "1.0.0" })
  const store = new Map<string, unknown>()
  const styles = new Map<string, unknown>()
  h.handlers = {
    "page.read": () => ok(read),
    "agent.ask": () => ok({ text: reply, ms: 900 }),
    "page.style.set": (p) => {
      styles.set(p.origin, p)
      return ok({ origin: p.origin, rules: p.hide.length + p.unstick.length })
    },
    "toast.show": () => ok(null),
    "app.storage.get": (p) => ok(store.get(p.key) ?? null),
    "app.storage.set": (p) => (store.set(p.key, p.value), ok(null)),
    "app.storage.delete": (p) => (store.delete(p.key), ok(null)),
    "app.storage.keys": () => ok([...store.keys()])
  }
  return { h, store, styles }
}

const toasts = (h: FakeHost) => h.calls.filter((c) => c.name === "toast.show").map((c) => c.params)
const named = (h: FakeHost, name: string) => h.calls.filter((c) => c.name === name)
async function run(h: FakeHost, cb: number, args: unknown = {}) {
  h.runCommand("clean", args, cb, { gesture: `g-${cb}` })
  await h.settle(30)
  return h.commandResults.get(cb)
}

describe("local/showcase-clean-page", () => {
  test("reads the page, asks the agent with the gesture, keeps only listed selectors, saves and says so", async () => {
    const { h, store, styles } = host()
    const result = await run(h, 1)
    expect(result).toEqual({ ok: true, body: { value: { origin: "https://news.test", hide: ["#ad-top", "#cookie"], unstick: ["header.site"] } } })
    const ask = named(h, "agent.ask")[0]!
    expect(ask.options.gesture).toBe("g-1")
    expect(ask.params.prompt).toContain("#ad-top | div | 728x90")
    expect(ask.params.prompt).not.toContain("article.story")
    expect(styles.get("https://news.test")).toEqual({ origin: "https://news.test", hide: ["#ad-top", "#cookie"], unstick: ["header.site"] })
    expect(store.get("site:https://news.test")).toMatchObject({ origin: "https://news.test", hide: ["#ad-top", "#cookie"], unstick: ["header.site"] })
    expect(toasts(h).at(-1)).toEqual({ title: "Cleaned 3 elements on news.test", tone: "success" })
  })

  test("a site already clean: the first run says so, the next one cleans it fresh", async () => {
    const { h } = host()
    await run(h, 1)
    const second = await run(h, 2)
    expect(second!.body.value).toEqual({ origin: "https://news.test", already: true, rules: 3 })
    expect(named(h, "agent.ask").length).toBe(1)
    expect(toasts(h).at(-1)!.title).toBe("news.test is already clean")
    await run(h, 3)
    expect(named(h, "agent.ask").length).toBe(2)
    expect(toasts(h).at(-1)!.title).toBe("Cleaned 3 elements on news.test")
  })

  test("again: true cleans at once", async () => {
    const { h } = host()
    await run(h, 1)
    await run(h, 2, { again: true })
    expect(named(h, "agent.ask").length).toBe(2)
  })

  test("no browser tab: says to open one, asks nothing", async () => {
    const { h } = host()
    h.handlers["page.read"] = () => fail("page.none", "No browser tab is open")
    await run(h, 1)
    expect(named(h, "agent.ask")).toEqual([])
    expect(toasts(h)).toEqual([{ title: "Open a web page first", tone: "warning" }])
  })

  test("an answer with no list saves nothing", async () => {
    const { h, store } = host("I can't tell which parts are ads.")
    await run(h, 1)
    expect(named(h, "page.style.set")).toEqual([])
    expect(store.size).toBe(0)
    expect(toasts(h).at(-1)).toMatchObject({ title: "Couldn't clean news.test", tone: "danger" })
  })

  test("the agent failing says why", async () => {
    const { h } = host()
    h.handlers["agent.ask"] = () => fail("app.busy","Another ask is running")
    await run(h, 1)
    expect(toasts(h).at(-1)).toEqual({ title: "Couldn't clean news.test", message: "Another ask is running", tone: "danger" })
  })

  test("the sidebar lists cleaned sites, and Restore puts one back", async () => {
    const { h, store, styles } = host()
    store.set("site:https://old.test", { origin: "https://old.test", hide: ["#x"], unstick: [], at: 1 })
    h.mount("m", "renderSites")
    await h.settle(10)
    // Rows in drawn order (the tree walked from its root).
    const titles = () => {
      const tree = h.tree("m")
      const out: unknown[][] = []
      const walk = (id: string) => {
        const n = tree.nodes.get(id)
        if (!n) return
        if (n.type === "Row") out.push([n.props.title, n.props.subtitle])
        n.children.forEach(walk)
      }
      walk(tree.root)
      return out
    }
    expect(titles()).toEqual([["old.test", "1 hidden"]])
    await run(h, 1)
    expect(titles()).toEqual([["news.test", "2 hidden · 1 unstuck"], ["old.test", "1 hidden"]])
    const tree = h.tree("m")
    const row = [...tree.nodes.values()].find((n) => n.type === "HStack" && n.children.some((id) => tree.nodes.get(id)?.props.title === "old.test"))!
    const restore = row.children.find((id) => tree.nodes.get(id)?.type === "Button")!
    h.dispatch("m", restore, "tap", { gesture: "g-tap" })
    await h.settle(10)
    expect(styles.get("https://old.test")).toEqual({ origin: "https://old.test", hide: [], unstick: [] })
    expect(store.has("site:https://old.test")).toBe(false)
    expect(titles()).toEqual([["news.test", "2 hidden · 1 unstuck"]])
  })

  test("with nothing cleaned the sidebar says how to start", async () => {
    const { h } = host()
    h.mount("m", "renderSites")
    await h.settle(10)
    const empty = [...h.tree("m").nodes.values()].find((n) => n.type === "EmptyState")
    expect(empty?.props.title).toBe("No sites cleaned")
  })
})
