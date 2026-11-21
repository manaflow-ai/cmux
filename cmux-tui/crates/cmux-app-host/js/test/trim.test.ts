// `trim` on shapes and the SDK's `Ring`: the builder carries exactly the documented value, a bound
// trim redraws on its signal, bad static values throw, and `Ring` draws a track and a round-capped
// arc that follows its value.
import { afterAll, describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { app, FakeHost } from "./fake-host.ts"

const thrown = (host: FakeHost, expr: string) => host.eval(`(() => { try { ${expr}; return null } catch (e) { return e.name + ": " + e.message } })()`)
const circles = (host: FakeHost, mount: string) => [...host.tree(mount).nodes.values()].filter((n) => n.type === "Circle")

describe("trim", () => {
  test("carries { from?, to, lineCap? } on a shape, and null clears it", () => {
    const host = new FakeHost(app(`
      return { render: () => VStack([
        Circle().stroke("accent").strokeWidth(8).size(44).trim({ to: 0.7, lineCap: "round" }).animation("smooth"),
        Capsule().stroke("success").trim({ from: 0.25, to: 0.5 }),
        Rectangle().stroke("warning").trim(null),
      ]) }`))
    host.mount("m1", "render")
    const props = (type: string) => host.tree("m1").nodes.get(host.findNode("m1", (n) => n.type === type)!)!.props
    expect(props("Circle").trim).toEqual({ to: 0.7, lineCap: "round" })
    expect(props("Circle").animation).toBe("smooth")
    expect(props("Capsule").trim).toEqual({ from: 0.25, to: 0.5 })
    expect(props("Rectangle").trim ?? null).toBeNull()
  })

  test("a bound trim redraws when its signal changes", async () => {
    const host = new FakeHost(app(`
      const [used, setUsed] = signal(0.2)
      globalThis.spend = () => setUsed(0.9)
      return { render: () => Circle().stroke("accent").trim(() => ({ to: used() })) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Circle")!
    expect(host.tree("m1").nodes.get(id)!.props.trim).toEqual({ to: 0.2 })
    host.eval("spend()")
    await host.settle()
    expect(host.tree("m1").nodes.get(id)!.props.trim).toEqual({ to: 0.9 })
  })

  test("refuses a static value with no finite to, a bad from or lineCap, or an extra key", () => {
    const host = new FakeHost(app(`return {}`))
    expect(thrown(host, `Circle().trim({})`)).toContain("TypeError: trim:")
    expect(thrown(host, `Circle().trim({ to: NaN })`)).toContain("TypeError: trim:")
    expect(thrown(host, `Circle().trim({ from: "0", to: 1 })`)).toContain("TypeError: trim:")
    expect(thrown(host, `Circle().trim({ to: 1, lineCap: "square" })`)).toContain("TypeError: trim:")
    expect(thrown(host, `Circle().trim({ to: 1, dash: 2 })`)).toContain("TypeError: trim:")
    expect(thrown(host, `Circle().trim({ to: 1.5 })`)).toBeNull()
  })
})

describe("Ring (cmux-extension-sdk widget helper)", () => {
  const root = join(import.meta.dir, "../../../../..")
  const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")
  const dir = mkdtempSync(join(tmpdir(), "cmux-ring-"))
  afterAll(() => rmSync(dir, { recursive: true, force: true }))

  test("draws a track and a round-capped arc to the clamped value, which follows its signal", async () => {
    mkdirSync(join(dir, "src"), { recursive: true })
    writeFileSync(join(dir, "src/main.ts"), `
      import { Ring, signal, widget } from "cmux-extension-sdk"
      const [used, setUsed] = signal(0.42)
      ;(globalThis as any).fill = () => setUsed(1.7)
      export const renderRing = widget(() => Ring(() => used(), { tint: "#FF2D55", track: "#FF2D5533", width: 8, size: 60 }))
      export const renderPlain = widget(() => Ring(0.5))
    `)
    const host = new FakeHost(await pack(dir, { sdk }), { app: { id: "local/ring", version: "0.1.0" }, settings: {} })
    expect(host.mount("m", "renderRing", { surface: "widget", size: "small" })).toBe("")
    const [track, arc] = circles(host, "m")
    expect(track!.props).toMatchObject({ stroke: "#FF2D5533", strokeWidth: 8, size: 60 })
    expect(track!.props.trim).toBeUndefined()
    expect(arc!.props).toMatchObject({ stroke: "#FF2D55", strokeWidth: 8, size: 60, animation: "smooth" })
    expect(arc!.props.trim).toEqual({ to: 0.42, lineCap: "round" })
    host.eval("fill()")
    await host.settle()
    expect(circles(host, "m")[1]!.props.trim).toEqual({ to: 1, lineCap: "round" })

    expect(host.mount("p", "renderPlain", { surface: "widget", size: "small" })).toBe("")
    const [plainTrack, plainArc] = circles(host, "p")
    expect(plainTrack!.props).toMatchObject({ stroke: "separator", strokeWidth: 6, size: 44 })
    expect(plainArc!.props).toMatchObject({ stroke: "accent", trim: { to: 0.5, lineCap: "round" } })
  })
})
