// Widgets (`cmux.widget/1`) in the fake host: the `cmux ext new --kind widget` template, built only
// on cmux-extension-sdk, draws with the SDK's layout helpers, reads the host's now() clock, and
// redraws on the host's tick (`__cmuxAppTick`) and on nothing else.
import { beforeAll, describe, expect, test } from "bun:test"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const template = join(root, "cmux-tui/crates/cmux-tui/src/cli/ext/templates/widget")
const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")

let built = ""
beforeAll(async () => {
  built = await pack(template, { sdk })
})

const texts = (host: FakeHost, mount: string) =>
  [...host.tree(mount).nodes.values()].filter((n) => n.type === "Text").map((n) => String(n.props.text))

const context = (size: string, place = "newtab") => ({
  surface: "widget",
  place,
  size,
  instance: "w1",
  settings: {},
  refresh: { everySeconds: 60 },
})

// 2026-11-16 09:41 and 09:42 local time.
const at941 = new Date(2026, 10, 16, 9, 41, 5).getTime()
const at942 = new Date(2026, 10, 16, 9, 42, 0).getTime()

describe("cmux.widget/1", () => {
  test("the template draws the time with the SDK's helpers, and the host's tick redraws it", async () => {
    const host = new FakeHost(built, { app: { id: "local/w", version: "0.1.0" }, settings: {} })
    expect(host.mount("m", "renderWidget", context("small"))).toBe("")
    host.tick("m", at941)
    await host.settle()
    expect(texts(host, "m")).toContain("9:41")
    expect(texts(host, "m")).toContain("Monday")
    // The frame: a leading column filling the tile with Apple's 16 pt inset.
    const frame = [...host.tree("m").nodes.values()].find((n) => n.type === "VStack")!
    expect(frame.props.padding).toBe(16)
    expect(frame.props.alignment).toBe("leading")
    const batches = host.batches("m").length
    host.tick("m", at942)
    await host.settle()
    expect(texts(host, "m")).toContain("9:42")
    expect(host.batches("m").length).toBe(batches + 1)
    // A tick for a mount that is not a widget (or not mounted) changes nothing.
    host.tick("nope", at941)
    await host.settle()
    expect(host.batches("m").length).toBe(batches + 1)
  })

  test("medium draws its own line, and the sidebar's frame is inset 12 pt", async () => {
    const host = new FakeHost(built, { app: { id: "local/w", version: "0.1.0" }, settings: {} })
    expect(host.mount("m", "renderWidget", context("medium", "sidebar"))).toBe("")
    host.tick("m", at941)
    await host.settle()
    expect(texts(host, "m")).toContain("Monday, in the sidebar")
    const frame = [...host.tree("m").nodes.values()].find((n) => n.type === "VStack")!
    expect(frame.props.padding).toBe(12)
  })
})
