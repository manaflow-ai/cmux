// Design systems (`cmux.design/1`, cmux-extension-sdk's design.ts): defineDesign merges a person's
// system over cmux's and refuses an entry that does not hold, naming the fix; the example
// extension examples/extensions/design-system draws DesignSystemView in the fake host, for cmux's
// system and its own, with a line limit on every Text and every gap on the system's scale.
//
// It also records the two scenes the gallery draws (webviews/src/apps/scene/DesignSystem.gallery.tsx):
//   CMUX_RECORD_DESIGN_SYSTEM=1 bun test cmux-tui/crates/cmux-app-host/js/test/design.test.ts
// rewrites webviews/src/apps/scene/fixtures/design-system-scenes.json.
import { beforeAll, describe, expect, test } from "bun:test"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import * as views from "../src/view.ts"
import { FakeHost, type Op } from "./fake-host.ts"

type Sdk = typeof import("../../../cmux-extension-sdk/typescript/src/index.ts")
type DesignSpec = import("../../../cmux-extension-sdk/typescript/src/index.ts").DesignSpec
// The SDK reads the runtime's view builders from the sandbox's globals when it loads, so it is
// imported after they are set: a static import here would load it, for every test file in this
// run, with `Text` and the rest undefined.
Object.assign(globalThis, views, { cmux: {} })
const { cmuxDesign, defineDesign, SPACE, TYPE_ROLES }: Sdk = await import("../../../cmux-extension-sdk/typescript/src/index.ts")

const root = join(import.meta.dir, "../../../../..")
const example = join(root, "examples/extensions/design-system")
const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")
const fixture = join(root, "webviews/src/apps/scene/fixtures/design-system-scenes.json")
const spec = JSON.parse(readFileSync(join(example, "cmux-design.json"), "utf8")) as DesignSpec

let built = ""
beforeAll(async () => {
  built = await pack(example, { sdk })
})

const throws = (patch: Record<string, unknown>) => () => defineDesign({ design: "cmux.design/1", ...patch } as DesignSpec)

describe("defineDesign", () => {
  test("cmuxDesign is TYPE_ROLES and SPACE, the color roles themselves, 4 roles and 2 accents a view", () => {
    expect(cmuxDesign.name).toBe("cmux")
    for (const [role, style] of Object.entries(TYPE_ROLES)) expect(cmuxDesign.type[role]).toEqual({ size: style.size, weight: style.weight })
    expect(cmuxDesign.space).toEqual(Object.values(SPACE))
    expect(cmuxDesign.colors.accent).toBe("accent")
    expect(Object.keys(cmuxDesign.colors)).toHaveLength(8)
    expect(cmuxDesign.limits).toEqual({ typeRoles: 4, accents: 2 })
  })

  test("a person's file overrides and adds roles, replaces the scale, names colors and moves limits; the rest is cmux's", () => {
    const d = defineDesign(spec)
    expect(d.name).toBe("Leo's widgets")
    expect(d.type.numeral).toEqual({ size: 40, weight: "bold" })
    expect(d.type.heading).toEqual({ size: 22, weight: "bold" })
    expect(d.type.code).toEqual({ size: 12, weight: "regular", monospaced: true })
    expect(d.type.caption).toEqual(cmuxDesign.type.caption!)
    expect(Object.keys(d.type)).toHaveLength(8)
    expect(d.space).toEqual([0, 4, 8, 12, 16, 24, 32])
    expect(d.color("brand")).toBe("accent")
    expect(d.color("muted")).toBe("secondary")
    expect(d.color("danger")).toBe("danger")
    expect(d.limits).toEqual({ typeRoles: 5, accents: 2 })
    // A file that sets only its format is cmux's system.
    const bare = defineDesign({ design: "cmux.design/1" })
    expect([bare.type, bare.space, bare.colors, bare.limits]).toEqual([cmuxDesign.type, cmuxDesign.space, cmuxDesign.colors, cmuxDesign.limits])
    // cmux's own is not changed by a merge.
    expect(cmuxDesign.type.numeral).toEqual({ size: 34, weight: "semibold" })
  })

  test("an entry that does not hold throws, naming the field and the fix", () => {
    expect(() => defineDesign({ design: "cmux.design/2" })).toThrow(`"design" must be "cmux.design/1"`)
    expect(throws({ type: { huge: { size: 80 } } })).toThrow("type.huge.size must be a number of points, 9 to 64")
    expect(throws({ type: { body: { size: 13, weight: "thin" } } })).toThrow("type.body.weight must be one of regular, medium, semibold, bold")
    const many = Object.fromEntries(Array.from({ length: 6 }, (_, i) => [`extra${i}`, { size: 14 }]))
    expect(throws({ type: many })).toThrow("13 type roles in all; a system has 12 at most")
    expect(throws({ space: [4, 8] })).toThrow(`"space" must start at 0 and go up, 2 to 16 steps`)
    expect(throws({ space: [0, 8, 4] })).toThrow(`"space" must start at 0 and go up`)
    expect(throws({ space: [0, 100] })).toThrow("space steps must be numbers of points, 0 to 64")
    expect(throws({ colors: { brand: "#ff0000" } })).toThrow("colors.brand must name a cmux color role: primary, secondary")
    expect(throws({ limits: { typeRoles: 9 } })).toThrow("limits.typeRoles must be 1 to 8")
    expect(throws({ limits: { accents: 0 } })).toThrow("limits.accents must be 1 to 4")
    const d = defineDesign(spec)
    expect(() => d.text("display", "x")).toThrow(`no type role "display" in Leo's widgets; use one of numeral`)
    expect(() => d.color("brandy")).toThrow(`no color "brandy" in Leo's widgets`)
  })
})

// The scene from its root, in drawn order.
function drawn(host: FakeHost, mount: string) {
  const tree = host.tree(mount)
  const out: Array<{ type: string; props: Record<string, unknown> }> = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.push(n)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

/** The ops that draw the mount's current tree, in one batch: what the gallery's SceneStore applies. */
function snapshot(host: FakeHost, mount: string): Op[] {
  const tree = host.tree(mount)
  const ops: Op[] = []
  const ids: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    ids.push(id)
    n.children.forEach(walk)
  }
  walk(tree.root)
  for (const id of ids) {
    const n = tree.nodes.get(id)!
    // Handlers are live wiring, not drawing: the gallery's scene has nothing to call.
    const props = Object.fromEntries(Object.entries(n.props).filter(([k]) => !k.startsWith("on") && k !== "menu"))
    ops.push({ op: "create", id, type: n.type, props })
  }
  for (const id of ids) {
    const n = tree.nodes.get(id)!
    if (n.children.length) ops.push({ op: "children", id, children: n.children })
  }
  ops.push({ op: "root", id: tree.root })
  return ops
}

async function shown(which: "cmux" | "yours") {
  const host = new FakeHost(built, { app: { id: "local/showcase-design-system", version: "1.0.0" }, settings: {}, apiVersion: "1.0.0" })
  expect(host.mount("m", "renderDesign")).toBe("")
  await host.settle()
  if (which === "cmux") {
    host.dispatch("m", host.findNode("m", (n) => n.type === "Button" && n.props.title === "cmux")!, "tap", { gesture: "g1" })
    await host.settle()
  }
  return host
}

describe("DesignSystemView in the fake host", () => {
  const scenes: Record<string, Op[]> = {}

  for (const [which, system, state] of [["yours", defineDesign(spec), "custom"], ["cmux", cmuxDesign, "cmux"]] as const) {
    test(`${which}: every role as a specimen, every step, every color, the components and limits, all drawn with the system`, async () => {
      const host = await shown(which)
      const nodes = drawn(host, "m")
      const texts = nodes.filter((n) => n.type === "Text")
      const words = texts.map((n) => String(n.props.text))
      expect(words).toContain(system.name)
      for (const title of ["Type", "Spacing", "Color", "Components", "Limits"]) expect(words).toContain(title)
      for (const [role, style] of Object.entries(system.type)) {
        expect(words).toContain(role)
        const specimen = texts.find((n) => n.props.text === "The quick brown fox" && n.props.font === style.size && n.props.weight === style.weight)
        expect(specimen).toBeDefined()
      }
      for (const name of Object.keys(system.colors)) expect(words).toContain(name)
      // Every Text has a line limit and a size of one of the system's roles.
      const sizes = new Set(Object.values(system.type).map((t) => t.size))
      for (const t of texts) {
        expect(t.props.lineLimit).toBeNumber()
        expect(sizes.has(t.props.font as number)).toBe(true)
      }
      // Every gap and padding is a step of the system's scale (the switcher's 8 and 16 are on both).
      for (const n of nodes) for (const key of ["spacing", "padding"]) if (typeof n.props[key] === "number") expect(system.space).toContain(n.props[key] as number)
      // The components: a gauge, an empty state's symbol, a badge, a button and a toggle.
      for (const type of ["ProgressView", "Icon", "Badge", "Toggle"]) expect(nodes.some((n) => n.type === type)).toBe(true)
      const badges = nodes.filter((n) => n.type === "Badge").map((n) => n.props.text)
      if (which === "yours") expect(badges).toEqual(expect.arrayContaining(["overrides", "adds", "alias"]))
      else expect(badges).toEqual(["3 new"])
      scenes[state] = snapshot(host, "m")
    })
  }

  test("the record writes the gallery's fixture when asked", () => {
    if (!process.env.CMUX_RECORD_DESIGN_SYSTEM) return
    expect(Object.keys(scenes).sort()).toEqual(["cmux", "custom"])
    writeFileSync(fixture, `${JSON.stringify({ cmux: scenes.cmux, custom: scenes.custom }, null, 2)}\n`)
    // Formatted as webviews' lint checks it, when its dependencies are installed.
    const vp = join(root, "webviews/node_modules/.bin/vp")
    if (existsSync(vp)) expect(Bun.spawnSync([vp, "fmt", fixture], { cwd: join(root, "webviews") }).exitCode).toBe(0)
  })
})
