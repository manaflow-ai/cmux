// Run the packed extension against the same scene, signal, gesture and timer runtime as cmux.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../../examples/extensions/media-player")
let built: string
beforeAll(async () => { built = await pack(dir) })

const anchor = Date.UTC(2026, 0, 3, 12)
const song = {
  title: "Morning Light", artist: "Quiet Hours", artwork: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmikAAAAASUVORK5CYII=",
  playing: true, position: 10, position_ms: anchor, rate: 2, duration: 100,
  can_previous: true, can_next: true
}
type Track = Omit<typeof song, "artwork" | "position" | "duration"> & Partial<Pick<typeof song, "artwork" | "position" | "duration">>

function player(layout = "card") {
  const h = new FakeHost(built, { app: { id: "local/media-player", version: "1.0.0" }, settings: { layout } })
  h.global.clock = anchor + 5_000
  h.eval("Date.now = () => globalThis.clock")
  let track: Track | null = song
  h.handlers["media.get"] = () => ({ ok: true, body: { value: { track } } })
  h.handlers["media.control"] = () => ({ ok: true, body: { value: null } })
  return { h, async push(next: Track | null) {
    track = next
    h.emit("media.changed")
    await h.settle()
  } }
}

const nodes = (h: FakeHost) => [...h.tree("m").nodes.values()]
const reads = (h: FakeHost) => h.calls.filter((c) => c.name === "media.get").length
const progress = (h: FakeHost) => nodes(h).find((n) => n.type === "ProgressView")?.props.value
const control = (h: FakeHost, label: string) => h.findNode("m", (n) => n.props.onTap === true && n.props.help === label && !n.props.disabled)

function tick(h: FakeHost, time: number) {
  h.global.clock = time
  for (const [id, timer] of [...h.timers]) {
    if (!timer.repeat) h.timers.delete(id)
    h.global.__cmuxAppTimer(id)
  }
}

describe("media player sample", () => {
  test("draws the artwork, track and timeline in three layouts", async () => {
    const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
    expect(manifest.settings.properties.layout).toMatchObject({ enum: ["compact", "card"], default: "compact" })
    const widths = []
    for (const [layout, entry] of [["compact", "renderSection"], ["card", "renderSection"], ["card", "renderPane"]] as const) {
      const { h } = player(layout)
      expect(h.mount("m", entry)).toBe("")
      await h.settle()
      const texts = nodes(h).map((n) => n.props.text)
      expect(texts).toContain(song.title)
      expect(texts).toContain(song.artist)
      const cover = nodes(h).find((n) => n.type === "Image" && n.props.src === song.artwork)
      expect(cover).toBeDefined()
      widths.push((cover!.props.frame as { width: number }).width)
      expect(progress(h)).toBeCloseTo(0.2)
    }
    expect(widths[1]!).toBeGreaterThan(widths[0]!)
    expect(widths[2]!).toBeGreaterThan(widths[1]!)
  })

  test("advances locally at the track rate, follows pushed seeks and pauses, and releases the mount", async () => {
    const { h, push } = player()
    h.mount("m", "renderPane")
    await h.settle()
    expect(progress(h)).toBeCloseTo(0.2)
    tick(h, anchor + 9_000)
    expect(progress(h)).toBeCloseTo(0.28)
    expect(reads(h)).toBe(1)

    await push({ ...song, playing: false, position: 56 })
    tick(h, anchor + 20_000)
    expect(progress(h)).toBeCloseTo(0.56)
    expect(reads(h)).toBe(2)
    await push(song)
    h.global.__cmuxAppUnmount("m")
    expect(h.timers.size).toBe(0)
    expect(h.subscriptions.size).toBe(0)
    expect(h.calls.filter((call) => call.name === "media.control")).toBeEmpty()
  })

  test("transport taps carry their gesture and seek from the current position", async () => {
    const { h } = player()
    h.mount("m", "renderSection")
    await h.settle()
    for (const label of ["Previous", "Pause", "Next", "Back 15 seconds", "Forward 15 seconds"]) {
      const id = control(h, label)
      expect(id).toBeDefined()
      h.dispatch("m", id!, "tap", { gesture: "tap-" + label })
    }
    const calls = h.calls.filter((c) => c.name === "media.control")
    expect(calls.map((c) => [c.params, c.options.gesture])).toEqual([
      [{ command: "previous" }, "tap-Previous"], [{ command: "play_pause" }, "tap-Pause"],
      [{ command: "next" }, "tap-Next"], [{ command: "seek", seconds: 5 }, "tap-Back 15 seconds"],
      [{ command: "seek", seconds: 35 }, "tap-Forward 15 seconds"]
    ])
  })

  test("live sources omit unavailable actions and a stopped source clears the card", async () => {
    const { h, push } = player()
    h.mount("m", "renderSection")
    await h.settle()
    await push({ ...song, artwork: undefined, duration: undefined, position: undefined, can_next: false, can_previous: false })
    expect(control(h, "Pause")).toBeDefined()
    for (const label of ["Previous", "Next", "Back 15 seconds", "Forward 15 seconds"]) expect(control(h, label)).toBeUndefined()
    expect(nodes(h).some((n) => n.type === "Image")).toBe(false)

    await push(null)
    expect(nodes(h).some((n) => n.type === "EmptyState")).toBe(true)
    expect(nodes(h).some((n) => n.props.text === song.title)).toBe(false)
    expect(control(h, "Pause")).toBeUndefined()
  })
})
