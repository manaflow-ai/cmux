// Runs the packed widget the way cmux does (the shipped app runtime in a fresh VM context) against
// a fake project index, and reads the scene it draws for each size.
import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { pack } from "cmux-extension-sdk/testing"
import { renderScene, visible } from "../preview/scenes.ts"

const source = await pack(join(import.meta.dir, ".."))

type SceneOp = { id?: string; type?: string; props?: Record<string, unknown> }
const texts = (ops: SceneOp[]) => visible(ops as never).filter((op) => op.type === "Text").map((op) => String(op.props?.text ?? ""))
const taps = (ops: SceneOp[]) => visible(ops as never).filter((op) => op.props?.onTap) as SceneOp[]

describe("projects widget", () => {
  test("small: only the machine's name with its dot, then four tiles, pinned first", async () => {
    const { ops, host, calls } = await renderScene(source, { size: "small", index: "busy" })
    expect(texts(ops)).toEqual(["Leo's MacBook Pro", "M", "manaflow", "C", "cmux", "W", "website", "A", "api"])
    expect(calls).toEqual([["project.list", { limit: 16 }], ["machine.get", {}]])
    // The machine's dot: a 7-point circle in its own color.
    expect(visible(ops as never).some((op) => (op.props?.frame as { width?: number })?.width === 7 && typeof op.props?.background === "string")).toBe(true)
    expect(host.logs.filter(([level]) => level === "error")).toEqual([])
  })

  test("each tile is the project's letter on its own color", async () => {
    const { ops } = await renderScene(source, { size: "medium", index: "busy" })
    const tiles = visible(ops as never).filter((op) => (op.props?.frame as { width?: number })?.width === 40 && op.props?.background)
    expect(tiles.length).toBe(8)
    expect(new Set(tiles.map((op) => op.props?.background)).size).toBeGreaterThan(3)
    const letters = visible(ops as never).filter((op) => op.type === "Text" && op.props?.color === "#ffffff").map((op) => op.props?.text)
    expect(letters).toEqual(["M", "C", "W", "A", "D", "N", "I", "D"])
  })

  test("medium: eight projects, the person's rename shown", async () => {
    const shown = texts((await renderScene(source, { size: "medium", index: "busy" })).ops)
    expect(shown.filter((_, i) => i >= 2 && i % 2 === 1)).toEqual(["manaflow", "cmux", "website", "api", "dotfiles", "Notes", "ios-app", "design-system"])
  })

  test("large: a list with each project's short path and how long ago", async () => {
    const shown = texts((await renderScene(source, { size: "large", index: "busy" })).ops)
    expect(shown.slice(2, 8)).toEqual(["M", "manaflow", "~/code/manaflow", "5w", "C", "cmux"])
    expect(shown).toContain("~/code/website")
    expect(shown).toContain("25m")
    expect(shown).not.toContain("old-prototype")
  })

  test("tapping a project opens a new workspace in its folder", async () => {
    const { ops, host, calls } = await renderScene(source, { size: "small", index: "busy" })
    const cells = taps(ops)
    expect(cells.length).toBe(4)
    host.dispatch("w", cells[1]!.id!, "tap", { gesture: "gesture-1" })
    await host.settle()
    expect(calls.filter(([name]) => name === "workspace.create")).toEqual([
      ["workspace.create", { initial_content: "terminal", cwd: "/Users/leo/code/cmux", name: "cmux", focus: true }]
    ])
  })

  test("hidden and missing projects never show; an empty index says how to fill it", async () => {
    expect(texts((await renderScene(source, { size: "small", index: "hiddenAndMissing" })).ops)).toEqual(["Leo's MacBook Pro", "C", "cmux"])
    expect(texts((await renderScene(source, { size: "medium", index: "empty" })).ops)).toEqual(["PROJECTS", "Leo's MacBook Pro", "Open a folder in cmux and it shows here."])
  })

  test("without access it says where to turn it on; with no machine name the header is just PROJECTS", async () => {
    expect(texts((await renderScene(source, { size: "small", index: "denied" })).ops)).toEqual(["Leo's MacBook Pro", "Turn on project access for Projects in Settings > Apps."])
    expect(texts((await renderScene(source, { size: "small", index: "few", machine: null })).ops)).toEqual(["PROJECTS", "C", "cmux", "W", "website", "A", "api"])
  })
})
