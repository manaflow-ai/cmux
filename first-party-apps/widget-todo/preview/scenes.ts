// Runs the packed widget in the fake host over an in-memory app storage, for the tests and for the
// preview fixtures the gallery renders (preview/build.ts). The clock is pinned: Monday, November 16,
// 2026, 9:41 AM in Los Angeles.
import { FakeHost, type Op } from "cmux-extension-sdk/testing"

export const AT = Date.UTC(2026, 10, 16, 17, 41, 0)

export type Size = "small" | "medium" | "large"

/** One device's app storage: what `app.storage.*` reads and writes. */
export class Storage {
  readonly data = new Map<string, unknown>()
  constructor(seed: Record<string, unknown> = {}) {
    for (const [k, v] of Object.entries(seed)) this.data.set(k, structuredClone(v))
  }
  install(host: FakeHost) {
    host.handlers["app.storage.get"] = (p) => ({ ok: true, body: { value: structuredClone(this.data.get(p.key) ?? null) } })
    host.handlers["app.storage.set"] = (p) => {
      this.data.set(p.key, structuredClone(p.value))
      return { ok: true, body: { value: null } }
    }
    host.handlers["app.storage.delete"] = (p) => {
      this.data.delete(p.key)
      return { ok: true, body: { value: null } }
    }
    host.handlers["app.storage.keys"] = () => ({ ok: true, body: { value: [...this.data.keys()].sort() } })
  }
}

export interface Device {
  host: FakeHost
  storage: Storage
}

/** A fresh launch of the widget's script on one device. */
export function launch(source: string, storage = new Storage(), options: { locale?: string; now?: number } = {}): Device {
  const host = new FakeHost("", { app: { id: "cmux/todo", version: "1.0.0", locale: options.locale ?? "en-US" }, apiVersion: "1.0.0", settings: {} })
  host.eval(`globalThis.__now = ${options.now ?? AT}; Date.now = () => globalThis.__now; Math.random = () => 0.5`)
  host.eval(source)
  storage.install(host)
  return { host, storage }
}

export function mount(device: Device, id: string, size: Size, settings: Record<string, unknown> = {}) {
  device.host.mount(id, "renderTodo", { surface: "widget", size, place: "newtab", instance: `tile-${id}`, settings })
}

export async function renderScene(source: string, size: Size, seed: Record<string, unknown>, options: { expandDone?: boolean; settings?: Record<string, unknown> } = {}): Promise<Op[]> {
  const device = launch(source, new Storage(seed))
  mount(device, "w", size, options.settings)
  await device.host.settle(10)
  if (options.expandDone) {
    const fold = device.host.findNode("w", (n) => n.type === "Text" && /Completed$/.test(String(n.props.text)))
    const tree = device.host.tree("w")
    const row = [...tree.nodes].find(([, n]) => n.children.includes(fold ?? ""))?.[0]
    if (row) device.host.dispatch("w", row, "tap")
    await device.host.settle(10)
  }
  return device.host.batches("w").flat()
}

/** Sample lists for the previews: public-safe, made up. */
export function item(id: string, text: string, minutesAgo: number, done = false) {
  const created = AT - minutesAgo * 60_000
  return { id, text, done, created, updated: created, by: "preview", ...(done ? { doneAt: created + 60_000 } : {}) }
}

export const SAMPLE = Object.fromEntries(
  [
    item("a", "Pick up dry cleaning", 300),
    item("b", "Review the release notes", 280, true),
    item("c", "Book flights for the offsite", 260),
    item("d", "Call the dentist", 240),
    item("e", "Water the plants", 220, true),
    item("f", "Renew passport", 200),
    item("g", "Order a birthday gift for Sam", 180),
    item("h", "Back up the laptop", 160),
    item("i", "Send the invoice", 140, true)
  ].map((i) => [`item:${i.id}`, i])
)
