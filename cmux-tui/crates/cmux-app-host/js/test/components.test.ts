// The finished components (RFD 0009 slice 4) in the fake host: Stat and Chart are scene nodes the
// host draws from data, every finished component carries `.variant(...)` and `.state(...)` as
// props, and the SDK's Gauge and RowList pass a state through to the node it is about.
//
// It also records the scenes the gallery draws (webviews/src/apps/scene/Components.gallery.tsx):
//   CMUX_RECORD_COMPONENTS=1 bun test cmux-tui/crates/cmux-app-host/js/test/components.test.ts
// rewrites webviews/src/apps/scene/fixtures/components-scenes.json, which the Rust design check's
// tests read back with no findings (design_tests.rs, `the_components_gallery_passes_the_design_check`).
import { beforeAll, describe, expect, test } from "bun:test"
import { existsSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { app, FakeHost, type Op } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")
const fixture = join(root, "webviews/src/apps/scene/fixtures/components-scenes.json")

let built = ""
beforeAll(async () => {
  built = await pack(join(import.meta.dir, "components"), { sdk })
})

type Drawn = { type: string; props: Record<string, unknown> }
/** The nodes drawn from the root (a removed subtree's records can linger in the fake host's map). */
function nodes(host: FakeHost, mount: string): Drawn[] {
  const tree = host.tree(mount)
  const out: Drawn[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.push(n)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}
const ofType = (host: FakeHost, mount: string, type: string) => nodes(host, mount).filter((n) => n.type === type)

/** The ops that draw the mount's current tree, in one batch: what the gallery's SceneStore applies. */
function snapshot(host: FakeHost, mount: string): Op[] {
  const tree = host.tree(mount)
  const ids: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    ids.push(id)
    n.children.forEach(walk)
  }
  walk(tree.root)
  const ops: Op[] = ids.map((id) => {
    const n = tree.nodes.get(id)!
    const props = Object.fromEntries(Object.entries(n.props).filter(([k]) => !k.startsWith("on") && k !== "menu"))
    return { op: "create", id, type: n.type, props }
  })
  for (const id of ids) {
    const n = tree.nodes.get(id)!
    if (n.children.length) ops.push({ op: "children", id, children: n.children })
  }
  ops.push({ op: "root", id: tree.root })
  return ops
}

describe("Stat and Chart", () => {
  test("Stat is one node with its value as text, a label, a delta and a trend", () => {
    const host = new FakeHost(app(`return { render: () => Stat(1284, { label: "Requests", delta: "+12%", trend: "up", goodTrend: "down" }) }`))
    host.mount("m", "render")
    expect(ofType(host, "m", "Stat")[0]!.props).toEqual({ value: "1284", label: "Requests", delta: "+12%", trend: "up", goodTrend: "down" })
  })

  test("a bound Stat value redraws as text", async () => {
    const host = new FakeHost(app(`
      const [n, setN] = signal(1)
      globalThis.bump = () => setN(2)
      return { render: () => Stat(n, { label: "n" }) }`))
    host.mount("m", "render")
    host.eval("bump()")
    await host.settle()
    expect(ofType(host, "m", "Stat")[0]!.props.value).toBe("2")
  })

  test("Chart sends finite numbers only, the last 64, and draws a line unless told bar", () => {
    const host = new FakeHost(app(`
      const many = Array.from({ length: 70 }, (_, i) => i)
      return { render: () => VStack([Chart([1, NaN, 2, Infinity, "3", 4]), Chart(many, { kind: "bar", color: "warning" })]) }`))
    host.mount("m", "render")
    const [line, bar] = ofType(host, "m", "Chart")
    expect(line!.props).toEqual({ values: [1, 2, 4], kind: "line" })
    expect(bar!.props.kind).toBe("bar")
    expect(bar!.props.color).toBe("warning")
    expect(bar!.props.values).toEqual(Array.from({ length: 64 }, (_, i) => i + 6))
  })
})

describe("variant and state", () => {
  test("are props on the node, and a bound state goes back to null to draw the component", async () => {
    const host = new FakeHost(app(`
      const [s, setS] = signal("loading")
      globalThis.done = () => setS(null)
      return { render: () => VStack([Badge("3", "accent").variant("prominent"), Row({ title: "Build" }).state(s, "Fetching")]) }`))
    host.mount("m", "render")
    expect(ofType(host, "m", "Badge")[0]!.props.variant).toBe("prominent")
    const row = ofType(host, "m", "Row")[0]!
    expect([row.props.state, row.props.stateMessage]).toEqual(["loading", "Fetching"])
    host.eval("done()")
    await host.settle()
    expect(ofType(host, "m", "Row")[0]!.props.state ?? null).toBeNull()
  })

  test("Gauge puts its state on the bar; RowList draws an EmptyState in it in place of the rows", async () => {
    const host = new FakeHost(built)
    host.mount("s", "renderStates")
    const bars = ofType(host, "s", "ProgressView")
    expect(bars.map((b) => b.props.state)).toEqual(["empty"])

    host.mount("l", "renderList")
    await host.settle()
    expect(ofType(host, "l", "EmptyState").map((n) => n.props.state)).toEqual(["loading"])
    expect(ofType(host, "l", "Text").map((n) => n.props.text)).toEqual(["Today"])
    host.eval("setListState(null)")
    await host.settle()
    expect(ofType(host, "l", "EmptyState")).toEqual([])
    expect(ofType(host, "l", "Text").map((n) => n.props.text)).toEqual(expect.arrayContaining(["Standup", "Review"]))
    host.eval(`setListState("error")`)
    await host.settle()
    const empty = ofType(host, "l", "EmptyState")
    expect(empty.map((n) => [n.props.state, n.props.stateMessage])).toEqual([["error", "Calendar is offline"]])
    expect(ofType(host, "l", "Text").map((n) => n.props.text)).toEqual(["Today"])
  })
})

describe("the gallery's scenes", () => {
  const scenes: Record<string, Op[]> = {}
  const renders = { stats: "renderStats", charts: "renderCharts", variants: "renderVariants", states: "renderStates" } as const

  for (const [name, render] of Object.entries(renders)) {
    test(`${name}: every variant and state set is one the components draw`, async () => {
      const host = new FakeHost(built)
      expect(host.mount("m", render)).toBe("")
      await host.settle()
      for (const n of nodes(host, "m")) {
        if (n.props.variant !== undefined) expect(["standard", "prominent", "subtle"]).toContain(n.props.variant as string)
        if (n.props.state != null) expect(["loading", "error", "empty"]).toContain(n.props.state as string)
      }
      scenes[name] = snapshot(host, "m")
    })
  }

  test("each scene shows what it is named for", () => {
    const types = (name: string) => scenes[name]!.filter((o) => o.op === "create").map((o) => (o as { type: string }).type)
    expect(types("stats").filter((t) => t === "Stat")).toHaveLength(6)
    expect(types("charts").filter((t) => t === "Chart")).toHaveLength(6)
    for (const t of ["Badge", "Button", "Row", "ProgressView"]) expect(types("variants").filter((x) => x === t)).toHaveLength(3)
    const states = scenes.states!.filter((o) => o.op === "create").map((o) => (o as { props: Record<string, unknown> }).props.state).filter(Boolean)
    expect(states).toHaveLength(9)
  })

  test("the record writes the gallery's fixture when asked", () => {
    if (!process.env.CMUX_RECORD_COMPONENTS) return
    expect(Object.keys(scenes).sort()).toEqual(["charts", "states", "stats", "variants"])
    writeFileSync(fixture, `${JSON.stringify(scenes, null, 2)}\n`)
    const vp = join(root, "webviews/node_modules/.bin/vp")
    if (existsSync(vp)) expect(Bun.spawnSync([vp, "fmt", fixture], { cwd: join(root, "webviews") }).exitCode).toBe(0)
  })
})
