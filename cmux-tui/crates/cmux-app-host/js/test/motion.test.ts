// The motion contract (ABI.md "Motion"): every modifier sets a scene prop of its own name, static or
// live, and Particles is a node. The renderers run them; the runtime only carries them.
import { describe, expect, test } from "bun:test"
import { app, FakeHost } from "./fake-host.ts"

describe("motion modifiers", () => {
  test("each modifier sets the prop of its name on the create op", () => {
    const host = new FakeHost(app(`
      return { render: () => Circle()
        .stroke("accent").strokeWidth(4)
        .animation("bouncy")
        .scale(1.2)
        .offset({ x: 2, y: -4 })
        .blur(3)
        .glow({ color: "warning", radius: 8, opacity: 0.6 })
        .gradient({ colors: ["#FF0000", "accent"], angle: 45 })
        .trim({ from: 0, to: 0.75 })
        .loop({ effect: "pulse", period: 1.5, amount: 2 })
        .transition("pop")
        .clipped() }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Circle")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({
      stroke: "accent",
      strokeWidth: 4,
      animation: "bouncy",
      scale: 1.2,
      offset: { x: 2, y: -4 },
      blur: 3,
      glow: { color: "warning", radius: 8, opacity: 0.6 },
      gradient: { colors: ["#FF0000", "accent"], angle: 45 },
      trim: { from: 0, to: 0.75 },
      loop: { effect: "pulse", period: 1.5, amount: 2 },
      transition: "pop",
      clipped: true,
    })
  })

  test("spring and timed motions pass through as objects", () => {
    const host = new FakeHost(app(`
      return { render: () => VStack([
        Text("a").animation({ spring: { response: 0.4, dampingFraction: 0.7 } }),
        Text("b").animation({ duration: 0.3, curve: "easeInOut" }),
      ]) }`))
    host.mount("m1", "render")
    const motions = [...host.tree("m1").nodes.values()].filter((n) => n.type === "Text").map((n) => n.props.animation)
    expect(motions).toEqual([{ spring: { response: 0.4, dampingFraction: 0.7 } }, { duration: 0.3, curve: "easeInOut" }])
  })

  test("a live prop sends one update per change, and null removes it", async () => {
    const host = new FakeHost(app(`
      const [on, setOn] = signal(false)
      globalThis.flip = (v) => setOn(v)
      return { render: () => Text("x")
        .animation("snappy")
        .scale(() => (on() ? 1.5 : 1))
        .glow(() => (on() ? { color: "accent", radius: 6 } : null))
        .loop(() => (on() ? { effect: "spin" } : null)) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Text")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ text: "x", animation: "snappy", scale: 1, glow: null, loop: null })
    host.eval("flip(true)")
    await host.settle()
    const updates = host.batches("m1").at(-1)!.filter((op) => op.op === "update")
    expect(updates.map((op) => op.props)).toEqual([{ scale: 1.5 }, { glow: { color: "accent", radius: 6 } }, { loop: { effect: "spin" } }])
    host.eval("flip(false)")
    await host.settle()
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ text: "x", animation: "snappy", scale: 1 })
  })

  test("an unchanged live value sends nothing", async () => {
    const host = new FakeHost(app(`
      const [n, setN] = signal(0)
      globalThis.bump = () => setN(n() + 1)
      return { render: () => Text("x").offset(() => ({ x: 0, y: n() > 5 ? 1 : 0 })) }`))
    host.mount("m1", "render")
    const before = host.batches("m1").length
    host.eval("bump()")
    await host.settle()
    expect(host.batches("m1").length).toBe(before)
  })
})

describe("Particles", () => {
  test("is a node whose props pass through, with burst as a live counter", async () => {
    const host = new FakeHost(app(`
      const [pulls, setPulls] = signal(0)
      globalThis.pull = () => setPulls(pulls() + 1)
      return { render: () => ZStack([
        Particles({ preset: "confetti", colors: ["accent", "#FFD700"], rate: 2, burst: () => pulls() }),
        Text("Pull"),
      ]) }`))
    host.mount("m1", "render")
    const id = host.findNode("m1", (n) => n.type === "Particles")!
    expect(host.tree("m1").nodes.get(id)!.props).toEqual({ preset: "confetti", colors: ["accent", "#FFD700"], rate: 2, burst: 0 })
    const zstack = host.findNode("m1", (n) => n.type === "ZStack")!
    expect(host.tree("m1").nodes.get(zstack)!.children[0]).toBe(id)
    host.eval("pull()")
    await host.settle()
    expect(host.tree("m1").nodes.get(id)!.props.burst).toBe(1)
  })

  test("is a global and the runtime reports 1.6.0", () => {
    const host = new FakeHost(app(`return {}`))
    expect(host.eval("typeof Particles")).toBe("function")
    expect(host.eval("__cmuxAppRuntimeVersion")).toBe("1.6.0")
  })
})
