// Gradient fills and SF Symbol rendering modes in the scene DSL: the builders return exactly the
// documented values and refuse anything else.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

const thrown = (host: FakeHost, expr: string) => host.eval(`(() => { try { ${expr}; return null } catch (e) { return e.name + ": " + e.message } })()`)

describe("linearGradient and radialGradient", () => {
  test("return the plain gradient value a background or fill carries", () => {
    const host = new FakeHost(app(`
      return { render: () => VStack([
        Text("Cupertino").background(linearGradient(["#2F7FD6", "#69A8E8"], 180)),
        Circle().fill(radialGradient(["warning", "#FF453A"])).size(20),
        RoundedRectangle().fill(linearGradient(["primary", "#FFFFFF00"])),
      ]).background(linearGradient(["#0B1A3A", "#253B6E", "#3A4E86"])) }`))
    host.mount("m1", "render")
    const props = (type: string) => host.tree("m1").nodes.get(host.findNode("m1", (n) => n.type === type)!)!.props
    expect(props("VStack").background).toEqual({ linear: { colors: ["#0B1A3A", "#253B6E", "#3A4E86"] } })
    expect(props("Text").background).toEqual({ linear: { colors: ["#2F7FD6", "#69A8E8"], angle: 180 } })
    expect(props("Circle").fill).toEqual({ radial: { colors: ["warning", "#FF453A"] } })
    expect(props("RoundedRectangle").fill).toEqual({ linear: { colors: ["primary", "#FFFFFF00"] } })
  })

  test("a bound gradient redraws when its signal changes", async () => {
    const host = new FakeHost(app(`
      const [night, setNight] = signal(false)
      globalThis.dusk = () => setNight(true)
      return { render: () => VStack([]).background(() => linearGradient(night() ? ["#0B1A3A", "#3A4E86"] : ["#2F7FD6", "#69A8E8"])) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "VStack")!
    expect(host.tree("m1").nodes.get(id)!.props.background).toEqual({ linear: { colors: ["#2F7FD6", "#69A8E8"] } })
    host.eval("dusk()")
    await host.settle()
    expect(host.tree("m1").nodes.get(id)!.props.background).toEqual({ linear: { colors: ["#0B1A3A", "#3A4E86"] } })
  })

  test("refuse fewer than 2 or more than 8 stops, a color that is not a token or hex, and a bad angle", () => {
    const host = new FakeHost(app(`return {}`))
    expect(thrown(host, `linearGradient(["#112233"])`)).toContain("TypeError: linearGradient: colors must be 2 to 8")
    expect(thrown(host, `linearGradient(Array(9).fill("#112233"))`)).toContain("TypeError")
    expect(thrown(host, `linearGradient(["#112233", "red"])`)).toContain("TypeError")
    expect(thrown(host, `linearGradient(["#112233", "#12345"])`)).toContain("TypeError")
    expect(thrown(host, `linearGradient(["#112233", "var(--x)"])`)).toContain("TypeError")
    expect(thrown(host, `linearGradient("#112233")`)).toContain("TypeError")
    expect(thrown(host, `linearGradient(["#112233", "#445566"], NaN)`)).toContain("TypeError: linearGradient: angle")
    expect(thrown(host, `linearGradient(["#112233", "#445566"], "90deg")`)).toContain("TypeError: linearGradient: angle")
    expect(thrown(host, `radialGradient(["#112233"])`)).toContain("TypeError: radialGradient")
    expect(thrown(host, `linearGradient(["#112233", "success", "#11223344"], -45)`)).toBeNull()
  })

  test("copy the stops, so a later change to the caller's array does not reach the scene", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.eval(`(() => { const c = ["#112233", "#445566"]; const g = linearGradient(c); c.push("#778899"); return g })()`)).toEqual({ linear: { colors: ["#112233", "#445566"] } })
  })
})

describe("symbolRendering", () => {
  test("sets the mode, and palette colors only when given", () => {
    const host = new FakeHost(app(`
      return { render: () => HStack([
        Icon("cloud.sun.rain.fill").symbolRendering("multicolor"),
        Icon("cloud.sun.fill").symbolRendering("palette", ["#FFFFFF", "warning"]),
        Icon("thermometer").symbolRendering("hierarchical").color("secondary"),
      ]) }`))
    host.mount("m1", "render")
    const icon = (symbol: string) => host.tree("m1").nodes.get(host.findNode("m1", (n) => n.props.symbol === symbol)!)!.props
    expect(icon("cloud.sun.rain.fill")).toEqual({ symbol: "cloud.sun.rain.fill", symbolRendering: "multicolor" })
    expect(icon("cloud.sun.fill")).toEqual({ symbol: "cloud.sun.fill", symbolRendering: "palette", symbolColors: ["#FFFFFF", "warning"] })
    expect(icon("thermometer")).toEqual({ symbol: "thermometer", symbolRendering: "hierarchical", color: "secondary" })
  })

  test("refuses an unknown mode and palette colors that are not 1 to 3 tokens or hex", () => {
    const host = new FakeHost(app(`return {}`))
    expect(thrown(host, `Icon("sun.max").symbolRendering("rainbow")`)).toContain("TypeError: symbolRendering: unknown mode")
    expect(thrown(host, `Icon("sun.max").symbolRendering("palette", [])`)).toContain("TypeError: symbolRendering: colors")
    expect(thrown(host, `Icon("sun.max").symbolRendering("palette", ["#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF"])`)).toContain("TypeError")
    expect(thrown(host, `Icon("sun.max").symbolRendering("palette", ["yellow"])`)).toContain("TypeError")
    expect(thrown(host, `Icon("sun.max").symbolRendering("monochrome")`)).toBeNull()
  })
})
