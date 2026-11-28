// `cmux.state(key, initial)`: a signal the host keeps across a reload (ABI.md, Kept state).
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const init = (state?: Record<string, unknown>) => ({ app: { id: "local/test", version: "1.0.0" }, apiVersion: "1.0.0", ...(state ? { state } : {}) })

// `open` is made by top-level code (before init seeds); `scroll` inside render.
const pane = app(`
  const [open, setOpen] = cmux.state("open", false)
  globalThis.toggle = () => setOpen((v) => !v)
  return {
    render: () => {
      const [scroll, setScroll] = cmux.state("scroll", 0)
      globalThis.down = () => setScroll((v) => v + 40)
      return VStack([Text(() => (open() ? "open" : "closed")), Text(() => "scroll " + scroll())])
    },
  }
`)

const texts = (host: FakeHost) => [...host.tree("m1").nodes.values()].filter((n) => n.type === "Text").map((n) => n.props.text)

describe("cmux.state", () => {
  test("starts at initial, mirrors each change to the host", async () => {
    const host = new FakeHost(pane, init())
    host.mount("m1", "render")
    expect(texts(host)).toEqual(["closed", "scroll 0"])
    expect(host.keptStates).toEqual([])
    host.eval(`toggle(); down()`)
    await host.settle()
    expect(texts(host)).toEqual(["open", "scroll 40"])
    // Outside a host entry each write is its own flush; the last message holds every key.
    expect(host.keptStates).toEqual([{ open: true }, { open: true, scroll: 40 }])
    // The same value again sends nothing.
    host.eval(`cmux.state("open", false)[1](true)`)
    await host.settle()
    expect(host.keptStates.length).toBe(2)
  })

  test("a host seeded with the kept values renders them, top-level signals too", async () => {
    const first = new FakeHost(pane, init())
    first.mount("m1", "render")
    first.eval(`toggle(); down()`)
    await first.settle()
    const second = new FakeHost(pane, init(first.keptStates.at(-1)))
    second.mount("m1", "render")
    expect(texts(second)).toEqual(["open", "scroll 40"])
  })

  test("a seeded key no signal reads yet stays kept", async () => {
    const host = new FakeHost(pane, init({ open: true, other: [1, 2] }))
    host.mount("m1", "render")
    host.eval(`down()`)
    await host.settle()
    expect(host.keptStates.at(-1)).toEqual({ open: true, other: [1, 2], scroll: 40 })
  })

  test("the same key is the same signal; a write with no reader still mirrors", async () => {
    const host = new FakeHost(app(`return {}`), init())
    expect(host.eval(`cmux.state("k", 1)[0] === cmux.state("k", 2)[0]`)).toBe(true)
    expect(host.eval(`cmux.state("k", 2)[0]()`)).toBe(1)
    host.eval(`cmux.state("k", 1)[1](5)`)
    await host.settle()
    expect(host.keptStates).toEqual([{ k: 5 }])
  })

  test("mirrors a restored top-level signal after init and keeps prototype keys", async () => {
    const host = new FakeHost(
      app(`
        const [count, setCount] = cmux.state("count", 0)
        globalThis.count = count
        globalThis.setCount = setCount
        return {}
      `),
      init({ count: 1, ["__proto__"]: "safe" }),
    )
    host.mount("m1", "render")
    await host.settle()
    expect(host.eval("count()")).toBe(1)
    expect(host.keptStates.at(-1)).toEqual({ count: 1, ["__proto__"]: "safe" })
    host.eval(`cmux.state("__proto__", "")[1]("kept")`)
    await host.settle()
    expect(host.keptStates.at(-1)).toEqual({ count: 1, ["__proto__"]: "kept" })
  })
})
