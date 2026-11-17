// cmux.watch("http.json", {url, everySeconds?}) (ABI.md, Signals): a JSON read through the daemon's
// shared HTTP cache (net.fetch with cache: "shared"), against the fake host.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const URL_A = "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current=temperature_2m"
const ok = (value: unknown) => ({ ok: true, body: { value } })
const fetches = (host: FakeHost) => host.calls.filter((c) => c.name === "net.fetch")

/** Two views of one app, each watching `params` (JS source); each shows the temperature and the status. */
const twoViews = (a: string, b: string) =>
  app(`
    const view = (params) => () => {
      const w = cmux.watch("http.json", params)
      globalThis.w = w
      return VStack([Text(() => "t=" + (w.value()?.current?.temperature_2m ?? "-")), Text(() => "status=" + w.status())])
    }
    return { one: view(${a}), two: view(${b}) }`)

const texts = (host: FakeHost, mount: string) => [...host.tree(mount).nodes.values()].map((n) => n.props.text).filter(Boolean)

function weatherHost(source: string, reply: () => { status: number; body: string } = () => ({ status: 200, body: JSON.stringify({ current: { temperature_2m: 21.5 } }) })) {
  const host = new FakeHost(source)
  host.handlers["net.fetch"] = () => ok({ headers: {}, cache: { shared: true }, ...reply() })
  return host
}

describe("cmux.watch http.json", () => {
  test("reads the URL once through the shared cache and parses the JSON", async () => {
    const host = weatherHost(twoViews(`{ url: ${JSON.stringify(URL_A)} }`, `{ url: ${JSON.stringify(URL_A)}, everySeconds: 600 }`))
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    // everySeconds paces the reader; it is not part of what is read, so both views share one entry.
    expect(fetches(host)).toHaveLength(1)
    expect(fetches(host)[0]!.params).toEqual({ url: URL_A, method: "GET", headers: {}, body: null, cache: "shared" })
    expect(texts(host, "a")).toEqual(["t=21.5", "status=fresh"])
    expect(texts(host, "b")).toEqual(["t=21.5", "status=fresh"])
    expect(host.timers.size).toBe(1)
    expect([...host.timers.values()][0]!.ms).toBe(300_000)
  })

  test("everySeconds under the 60 s floor is refused at the watch call", async () => {
    const host = weatherHost(app(`return { render: () => { try { cmux.watch("http.json", { url: ${JSON.stringify(URL_A)}, everySeconds: 5 }); return Text("ok") } catch (e) { return Text(e.code) } } }`))
    host.mount("a", "render")
    await host.settle()
    expect(texts(host, "a")).toEqual(["signal.params"])
    expect(fetches(host)).toHaveLength(0)
  })

  test("a non-2xx answer is the watch's error; a body that is not JSON too", async () => {
    let reply = { status: 503, body: "busy" }
    const host = weatherHost(twoViews(`{ url: ${JSON.stringify(URL_A)} }`, `{ url: ${JSON.stringify(URL_A)} }`), () => reply)
    host.mount("a", "one")
    await host.settle()
    expect(texts(host, "a")).toEqual(["t=-", "status=error"])
    const w = (host.ctx as any).w
    expect(w.error().code).toBe("upstream.failed")
    expect(w.error().details.status).toBe(503)
    reply = { status: 200, body: "<html>" }
    await w.refresh()
    expect(w.error().message).toContain("not JSON")
  })

  test("a refused grant is scope.missing and is not retried", async () => {
    const host = new FakeHost(twoViews(`{ url: "https://elsewhere.example/x" }`, `{}`))
    host.handlers["net.fetch"] = () => ({ ok: false, body: { code: "scope.missing", message: "the app holds no net:elsewhere.example grant", retryable: false } })
    host.mount("a", "one")
    await host.settle()
    expect(texts(host, "a")).toEqual(["t=-", "status=error"])
    expect((host.ctx as any).w.error().code).toBe("scope.missing")
    expect(host.timers.size).toBe(0)
  })

  test("a pace that changes in params moves the timer, not the entry", async () => {
    const source = app(`
      const [every, setEvery] = signal(600)
      globalThis.setEvery = setEvery
      return { render: () => {
        const w = cmux.watch("http.json", () => ({ url: ${JSON.stringify(URL_A)}, everySeconds: every() }))
        return Text(() => "t=" + (w.value()?.current?.temperature_2m ?? "-"))
      } }`)
    const host = weatherHost(source)
    host.mount("a", "render")
    await host.settle()
    expect([...host.timers.values()].map((t) => t.ms)).toEqual([300_000])
    ;(host.ctx as any).setEvery(60)
    await host.settle()
    expect([...host.timers.values()].map((t) => t.ms)).toEqual([60_000])
    expect(fetches(host)).toHaveLength(1)
  })

  test("polling stops when the last view unmounts", async () => {
    const host = weatherHost(twoViews(`{ url: ${JSON.stringify(URL_A)} }`, `{ url: ${JSON.stringify(URL_A)} }`))
    host.mount("a", "one")
    host.mount("b", "two")
    await host.settle()
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("a")
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("b")
    expect(host.timers.size).toBe(0)
    expect(fetches(host)).toHaveLength(1)
  })
})
