import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"
import { commandAssertion, hourAssertion, listValue, processes, stoppedAssertion, terminals } from "../preview/fixtures.ts"

const source = readFileSync(join(import.meta.dir, "../dist/main.js"), "utf8")
const ok = (value: unknown) => ({ ok: true, body: { value } })
const fail = (code: string) => ({ ok: false, body: { code, message: code, details: {}, retryable: false } })
type Reply = { ok: boolean; body: unknown }

/** A host with the app loaded in English, in-memory storage, fake terminals and a power owner that never touches the real Mac. */
function makeHost(settings: Record<string, unknown> = {}, opts: { assertions?: unknown[]; ops?: Record<string, (p: any, o: any) => Reply> } = {}) {
  const host = new FakeHost("", { app: { id: "cmux/caffeinate", version: "0.1.0" }, apiVersion: "1.0.0" })
  const now = Date.now()
  host.eval(`Intl.DateTimeFormat = function () { return { resolvedOptions: () => ({ locale: "en-US" }) } }; Date.now = () => ${now}`)
  host.eval(source)
  host.global.__cmuxAppInit(JSON.stringify({ app: { id: "cmux/caffeinate", version: "0.1.0" }, apiVersion: "1.0.0", settings }))
  const storage = new Map<string, unknown>()
  let assertions = (opts.assertions ?? []) as Array<Record<string, unknown>>
  let revision = 10
  host.handlers = {
    "power.assertion.list": () => ok(listValue(now, assertions, { revision: String(revision) })),
    "power.assertion.create": (p) => {
      revision += 1
      const id = `pwr_new${revision}`
      assertions = [...assertions, { assertion: id, kinds: p.kinds, reason: p.reason, created_at: new Date(now).toISOString(), expires_at: p.timeout_s ? new Date(now + p.timeout_s * 1000).toISOString() : null, until: p.until ?? null, until_label: p.until_label, owner: { actor: "user:local", origin: "user", app: "cmux/caffeinate" } }]
      return ok({ assertion: id, expires_at: p.timeout_s ? new Date(now + p.timeout_s * 1000).toISOString() : null, revision: String(revision) })
    },
    "power.assertion.release": (p) => {
      revision += 1
      const gone = p.all ? assertions.map((a) => a.assertion as string) : [p.assertion]
      assertions = assertions.filter((a) => !gone.includes(a.assertion as string))
      return ok({ released: gone, revision: String(revision) })
    },
    "terminal.list": () => ok(terminals),
    "terminal.process.get": (p) => ok(processes[p.terminal]),
    "app.storage.get": (p) => ok(storage.get(p.key) ?? null),
    "app.storage.set": (p) => (storage.set(p.key, p.value), ok(null)),
    "app.storage.delete": (p) => (storage.delete(p.key), ok(null)),
    ...opts.ops
  } as FakeHost["handlers"]
  return { host, now, storage }
}

/** Nodes reachable from the root, in order. */
function nodes(host: FakeHost, mount: string) {
  const { root, nodes: all } = host.tree(mount)
  const out: Array<{ id: string; type: string; props: Record<string, unknown> }> = []
  const walk = (id: string) => {
    const n = all.get(id)
    if (!n) return
    out.push({ id, ...n })
    n.children.forEach(walk)
  }
  walk(root)
  return out
}
const texts = (host: FakeHost, mount: string) => nodes(host, mount).flatMap((n) => [n.props.title, n.props.text, n.props.badge, n.props.subtitle, n.props.message]).filter((v): v is string => typeof v === "string" && v !== "")
type MenuItem = { title?: string; divider?: boolean; disabled?: boolean; destructive?: boolean; children?: MenuItem[] }
const menuOf = (host: FakeHost, mount: string) => (nodes(host, mount).find((n) => Array.isArray(n.props.menu))?.props.menu ?? []) as MenuItem[]
const menuNode = (host: FakeHost, mount: string) => nodes(host, mount).find((n) => Array.isArray(n.props.menu))!.id
const titles = (items: MenuItem[]) => items.map((i) => (i.divider ? "—" : i.title))
const calls = (host: FakeHost, name: string) => host.calls.filter((c) => c.name === name)
/** The id of the tappable node that shows `text` (itself or in its subtree). */
function tappable(host: FakeHost, mount: string, text: string): string {
  const { nodes: all } = host.tree(mount)
  const shows = (id: string): boolean => {
    const n = all.get(id)
    return !!n && (n.props.text === text || n.props.title === text || n.children.some(shows))
  }
  const live = new Set(nodes(host, mount).map((n) => n.id))
  for (const [id, n] of all) if (live.has(id) && n.props.onTap === true && shows(id)) return id
  throw new Error(`nothing tappable shows ${text}`)
}
const tap = async (host: FakeHost, mount: string, text: string) => {
  host.dispatch(mount, tappable(host, mount, text), "tap", { gesture: "g1" })
  await host.settle(20)
}

async function runCommand(host: FakeHost, name: string, args: unknown = {}) {
  const id = Math.floor(Math.random() * 1e6)
  host.global.__cmuxAppRunCommand(name, JSON.stringify(args), id)
  await host.settle(20)
  return host.commandResults.get(id)!
}

describe("menu variant (recommended)", () => {
  test("off: the cup says Off; the dropdown has presets, durations and running commands", async () => {
    const { host } = makeHost()
    expect(host.mount("s", "renderStatus")).toBe("")
    await host.settle(30)
    expect(texts(host, "s")).toContain("Off")
    const menu = menuOf(host, "s")
    expect(titles(menu)).toEqual(["The Mac sleeps as usual", "—", "Keep Awake Until Stopped", "Keep Awake for 1 Hour", "Keep Awake For", "Keep Awake While a Command Runs", "—", "Show Caffeinate"])
    expect(titles(menu[4]!.children!)).toEqual(["For 15 minutes", "For 30 minutes", "For 2 hours", "For 4 hours", "For 8 hours"])
    // Two terminals run a command, the third sits at its prompt.
    expect(titles(menu[5]!.children!)).toEqual(["make · api", "bun · web", "—", "Refresh List"])
    // One list read, no repeating timer.
    expect(calls(host, "power.assertion.list").length).toBe(1)
    expect([...host.timers.values()].some((x) => x.repeat)).toBe(false)
  })

  test("picking presets creates assertions through the host and the glance shows time left", async () => {
    const { host } = makeHost()
    host.mount("s", "renderStatus")
    await host.settle(30)
    host.dispatch("s", menuNode(host, "s"), "menu", { path: [3], gesture: "g1" })
    await host.settle(30)
    const create = calls(host, "power.assertion.create")
    expect(create.length).toBe(1)
    expect(create[0]!.params).toEqual({ kinds: ["display", "idle"], reason: "cmux Caffeinate: For 1 hour", timeout_s: 3600 })
    expect(create[0]!.options.gesture).toBe("g1")
    expect(texts(host, "s")).toContain("1h")
    // While a command runs: the terminal handle, never a pid.
    host.dispatch("s", menuNode(host, "s"), "menu", { path: [5, 0], gesture: "g2" })
    await host.settle(30)
    expect(calls(host, "power.assertion.create")[1]!.params).toEqual({ kinds: ["idle"], reason: "cmux Caffeinate: While make · api runs", until: { terminal: "terminal_7", end: "command" }, until_label: "make · api" })
    const menu = menuOf(host, "s")
    expect(menu[0]!.title).toBe("Keeping the Mac awake (2)")
    expect(titles(menu)).toEqual(expect.arrayContaining(["Stop: For 1 hour (1h left)", "Stop: While make · api runs", "Stop All"]))
    // Stop All is one release op, so one gesture covers every assertion.
    host.dispatch("s", menuNode(host, "s"), "menu", { path: [titles(menu).indexOf("Stop All")], gesture: "g3" })
    await host.settle(30)
    expect(calls(host, "power.assertion.release").map((c) => c.params)).toEqual([{ all: true }])
    expect(texts(host, "s")).toContain("Off")
  })

  test("the pane lists running assertions with Stop and the presets as rows", async () => {
    const { host, now } = makeHost({}, { assertions: [hourAssertion(Date.now()), commandAssertion(Date.now())] })
    host.mount("p", "renderPane")
    await host.settle(30)
    const t = texts(host, "p")
    expect(t).toEqual(expect.arrayContaining(["Keeping the Mac awake", "For 1 hour", "Display, Mac", "42m", "While make · api runs", "Until I stop it", "For 1 hour", "While a command runs"]))
    expect(t).toContain("Stop All")
    await tap(host, "p", "Until I stop it")
    expect(calls(host, "power.assertion.create")[0]!.params).toMatchObject({ kinds: ["display", "idle"] })
    expect(texts(host, "p")).toContain("Stop All")
    // Stop on one row releases that assertion only, with an idempotency key.
    const stopButtons = nodes(host, "p").filter((n) => n.type === "Button" && n.props.title === "Stop")
    expect(stopButtons.length).toBe(3)
    host.dispatch("p", stopButtons[0]!.id, "tap", { gesture: "g9" })
    await host.settle(30)
    const rel = calls(host, "power.assertion.release")
    expect(rel[0]!.params).toEqual({ assertion: "pwr_01hour" })
    expect(rel[0]!.options.idempotencyKey).toBe("release:pwr_01hour")
    expect(texts(host, "p")).not.toContain("42m")
    void now
  })

  test("watch events update every surface without another read; a finished command leaves a notice", async () => {
    const { host, now } = makeHost({}, { assertions: [commandAssertion(Date.now())] })
    host.mount("s", "renderStatus")
    host.mount("p", "renderPane")
    await host.settle(30)
    expect(texts(host, "s")).toContain("On")
    host.emit("power.assertion.watch", { type: "released", revision: "11", assertion: "pwr_02build", cause: "until" })
    await host.settle(10)
    expect(texts(host, "s")).toContain("Off")
    expect(texts(host, "p")).toContain("Finished: While make · api runs")
    host.emit("power.assertion.watch", { type: "created", revision: "12", assertion: hourAssertion(now, { id: "pwr_cli", leftMin: 3 }) })
    await host.settle(10)
    expect(texts(host, "s")).toContain("3m")
    expect(calls(host, "power.assertion.list").length).toBe(1)
  })

  test("the countdown is one one-shot timer at the next text change", async () => {
    const { host } = makeHost({}, { assertions: [hourAssertion(Date.now(), { leftMin: 42 })] })
    host.mount("s", "renderStatus")
    await host.settle(30)
    const timers = [...host.timers.values()]
    expect(timers.length).toBe(1)
    expect(timers[0]!.repeat).toBe(false)
    expect(timers[0]!.ms).toBeLessThanOrEqual(60_000 + 5)
  })
})

describe("pane variant", () => {
  test("options are explained in plain words with their flags; Keep Awake sends the chosen kinds and time", async () => {
    const { host } = makeHost({ variant: "pane" })
    host.mount("p", "renderPane")
    await host.settle(30)
    const t = texts(host, "p")
    expect(t).toEqual(
      expect.arrayContaining(["Display", "The display stays on.", "-d", "-i", "-m", "-s", "-u", "Disks do not sleep when idle.", "The Mac does not sleep at all while on power. On battery this does nothing.", "For how long", "End early when", "The Mac sleeps as usual"])
    )
    // Display and Mac are on by default; add Disks, pick 2h.
    await tap(host, "p", "Disks")
    await tap(host, "p", "2h")
    host.dispatch("p", nodes(host, "p").find((n) => n.type === "Button" && n.props.title === "Keep Awake")!.id, "tap", { gesture: "g1" })
    await host.settle(30)
    expect(calls(host, "power.assertion.create")[0]!.params).toEqual({ kinds: ["display", "idle", "disk"], reason: "cmux Caffeinate: For 2 hours", timeout_s: 7200 })
    expect(texts(host, "p")).toEqual(expect.arrayContaining(["For 2 hours", "Display, Mac, Disks", "2h"]))
  })

  test("end when a command finishes: choose a terminal; without one Keep Awake is disabled", async () => {
    const { host } = makeHost({ variant: "pane" })
    host.mount("p", "renderPane")
    await host.settle(30)
    await tap(host, "p", "Command ends")
    const start = () => nodes(host, "p").find((n) => n.type === "Button" && n.props.title === "Keep Awake")!
    expect(start().props.disabled).toBe(true)
    expect(texts(host, "p")).toEqual(expect.arrayContaining(["make · api", "bun · web"]))
    await tap(host, "p", "bun · web")
    expect(start().props.disabled).toBe(false)
    await tap(host, "p", "Until stopped")
    host.dispatch("p", start().id, "tap", { gesture: "g1" })
    await host.settle(30)
    expect(calls(host, "power.assertion.create")[0]!.params).toMatchObject({ kinds: ["display", "idle"], until: { terminal: "terminal_8", end: "command" }, until_label: "bun · web" })
    expect(calls(host, "power.assertion.create")[0]!.params.timeout_s).toBeUndefined()
  })

  test("the status item opens the pane; right-click has Stop", async () => {
    const { host } = makeHost({ variant: "pane" }, { ops: { "action.run": () => ok(null) }, assertions: [stoppedAssertion(Date.now())] })
    host.mount("s", "renderStatus")
    await host.settle(30)
    expect(titles(menuOf(host, "s"))).toEqual(["Stop: Until stopped", "—", "Open Caffeinate"])
    host.dispatch("s", nodes(host, "s").find((n) => n.props.onTap === true)!.id, "tap", { gesture: "g1" })
    await host.settle(20)
    expect(calls(host, "action.run")[0]!.params).toMatchObject({ id: "app.pane.open", args: { kind: "cmux/caffeinate#caffeinatePane" } })
    // The pane variant reads terminals only when the user picks "When a command finishes".
    expect(calls(host, "terminal.list").length).toBe(0)
  })
})

describe("states and commands", () => {
  test("no host capability: both variants say what is missing", async () => {
    for (const variant of ["menu", "pane"]) {
      const { host } = makeHost({ variant }, { ops: { "power.assertion.list": () => fail("operation.unsupported") } })
      host.mount("p", "renderPane")
      host.mount("s", "renderStatus")
      await host.settle(30)
      expect(texts(host, "p")).toEqual(expect.arrayContaining(["Keeping awake is not available", "This cmux build cannot hold power assertions yet (power.assertion.create)."]))
      if (variant === "menu") {
        expect(texts(host, "s")).toContain("—")
        expect(menuOf(host, "s")[2]!.disabled).toBe(true)
      }
    }
  })

  test("not a Mac and no permission", async () => {
    const linux = makeHost({}, { ops: { "power.assertion.list": () => ok({ revision: "1", available: false, unavailable_reason: "power.unsupported_platform", assertions: [] }) } })
    linux.host.mount("p", "renderPane")
    await linux.host.settle(30)
    expect(texts(linux.host, "p")).toContain("Only on a Mac")
    const denied = makeHost({}, { ops: { "power.assertion.list": () => ({ ok: false, body: { code: "scope.missing", message: "no", details: { scope: "power:read" }, retryable: false } }) } })
    denied.host.mount("p", "renderPane")
    await denied.host.settle(30)
    expect(texts(denied.host, "p")).toContain("Allow power:read in Settings > Apps > Caffeinate.")
  })

  test("start, list, stop and stopAll as commands (palette, CLI, MCP)", async () => {
    const { host } = makeHost()
    const started = await runCommand(host, "start", { preset: "duration", minutes: 20, kinds: ["idle"] })
    expect(started.ok).toBe(true)
    expect(started.body.value).toMatchObject({ started: true, assertion: "pwr_new11" })
    expect((await runCommand(host, "keepAwakeHour")).body.value).toMatchObject({ started: true })
    const listed = (await runCommand(host, "list")).body.value
    expect(listed.available).toBe(true)
    expect(listed.assertions.map((a: { title: string; flags: string }) => [a.title, a.flags])).toEqual([
      ["For 20 minutes", "-i"],
      ["For 1 hour", "-d -i"]
    ])
    expect((await runCommand(host, "stop", { assertion: "pwr_new11" })).body.value).toEqual({ released: true })
    expect((await runCommand(host, "stopAll")).body.value).toEqual({ released: ["pwr_new12"] })
    // Invalid input is refused before any host call.
    const before = calls(host, "power.assertion.create").length
    expect((await runCommand(host, "start", { preset: "command" })).body.value).toMatchObject({ started: false, code: "caffeinate.no_handle" })
    expect(calls(host, "power.assertion.create").length).toBe(before)
  })

  test("an agent may bind only to its own terminal and stop only its own", async () => {
    const { host } = makeHost({}, { assertions: [hourAssertion(Date.now())] })
    const agent = { invoker: { actor: "agent:a1", origin: "agent", terminal: "terminal_7" } }
    // The runtime passes {app} as the context today; the proposed ctx.invoker is exercised through the export directly.
    const exports = host.global.__cmuxAppExports
    expect(await exports.start({ preset: "untilStopped" }, agent)).toMatchObject({ started: false, code: "power.not_permitted" })
    expect(await exports.start({ preset: "command", terminal: "terminal_8" }, agent)).toMatchObject({ started: false, code: "power.not_permitted" })
    expect(await exports.start({ preset: "command", terminal: "terminal_7" }, agent)).toMatchObject({ started: true })
    expect(await exports.stop({ assertion: "pwr_01hour" }, agent)).toMatchObject({ released: false, code: "power.not_permitted" })
  })

  test("a request id becomes the idempotency key of the create", async () => {
    const { host } = makeHost()
    await runCommand(host, "start", { preset: "hour", request_id: "r-1" })
    expect(calls(host, "power.assertion.create")[0]!.options.idempotencyKey).toBe("start:r-1")
  })

  test("Next Caffeinate Variant switches the surfaces", async () => {
    const { host } = makeHost({}, { ops: { "app.settings.set": () => fail("operation.unsupported") } })
    host.mount("p", "renderPane")
    await host.settle(30)
    expect(texts(host, "p")).toContain("Until I stop it")
    const r = await runCommand(host, "cycleVariant")
    expect(r.body.value).toEqual({ variant: "pane", persisted: "storage" })
    await host.settle(10)
    expect(texts(host, "p")).toContain("For how long")
  })
})
