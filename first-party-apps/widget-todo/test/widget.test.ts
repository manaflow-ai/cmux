// The packed widget in the fake host: first install, adding, checking off, persistence across a
// restart, and two devices whose storage syncs.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"
import { pack, type FakeHost } from "cmux-extension-sdk/testing"
import { merge, type Item } from "../src/model.ts"
import { AT, item, launch, mount, SAMPLE, Storage, type Device } from "../preview/scenes.ts"

const dir = join(import.meta.dir, "..")
let source = ""
beforeAll(async () => {
  source = await pack(dir)
})

type Node = { type: string; props: Record<string, unknown>; children: string[] }

function nodes(host: FakeHost, mount: string): Array<[string, Node]> {
  // Walk from the root: a node a re-render detached is no longer shown, whatever the map still holds.
  const tree = host.tree(mount)
  const out: Array<[string, Node]> = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.push([id, n])
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

const texts = (host: FakeHost, m: string) => nodes(host, m).filter(([, n]) => n.type === "Text").map(([, n]) => String(n.props.text))

/** The clickable row (the nearest HStack with a pointer cursor) that holds the text `label`. */
function rowOf(host: FakeHost, m: string, label: string): string {
  const all = nodes(host, m)
  const text = all.find(([, n]) => n.type === "Text" && n.props.text === label)?.[0]
  if (!text) throw new Error(`no text ${label}; shown: ${texts(host, m).join(" | ")}`)
  const parent = new Map<string, string>()
  for (const [id, n] of all) for (const child of n.children) parent.set(child, id)
  for (let id = parent.get(text); id; id = parent.get(id)) {
    const n = host.tree(m).nodes.get(id)!
    if (n.type === "HStack" && n.props.cursor === "pointer") return id
  }
  throw new Error(`no row for ${label}`)
}

/** The text node that shows `label`. */
const textOf = (host: FakeHost, m: string, label: string) => nodes(host, m).find(([, n]) => n.type === "Text" && n.props.text === label)?.[1]

const field = (host: FakeHost, m: string) => host.findNode(m, (n) => n.type === "TextField")!

async function type(device: Device, m: string, text: string) {
  device.host.dispatch(m, field(device.host, m), "edit", { text })
  device.host.dispatch(m, field(device.host, m), "submit", { text })
  await device.host.settle(10)
}


const stored = (storage: Storage) => [...storage.data.values()] as Item[]

describe("cmux/todo widget", () => {
  test("imports nothing but the SDK and its own files", () => {
    for (const file of readdirSync(join(dir, "src"))) {
      const src = readFileSync(join(dir, "src", file), "utf8")
      for (const [, from] of src.matchAll(/from\s+"([^"]+)"/g)) expect(from === "cmux-extension-sdk" || from!.startsWith("./") || from!.startsWith("../strings/")).toBe(true)
    }
    expect(source).toContain("function renderTodo(")
  })

  test("first install: an empty list that says so, with New item ready in every size", async () => {
    for (const size of ["small", "medium", "large"] as const) {
      const d = launch(source)
      mount(d, "w", size)
      await d.host.settle(10)
      expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["0", "To Do", "Nothing to do"]))
      expect(d.host.findNode("w", (n) => n.type === "TextField" && n.props.placeholder === "New item")).toBeDefined()
    }
  })

  test("typing in New item and pressing Return adds a row, saved under its own key", async () => {
    const d = launch(source)
    mount(d, "w", "medium")
    await d.host.settle(10)
    await type(d, "w", "  Buy   milk ")
    expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["1", "Buy milk"]))
    expect(texts(d.host, "w")).not.toContain("Nothing to do")
    const keys = [...d.storage.data.keys()]
    expect(keys).toHaveLength(1)
    expect(keys[0]).toMatch(/^item:/)
    expect(stored(d.storage)[0]).toMatchObject({ text: "Buy milk", done: false, created: AT })
    // The field is empty again for the next item; an empty Return adds nothing.
    expect(d.host.tree("w").nodes.get(field(d.host, "w"))!.props.text).toBe("")
    await type(d, "w", "   ")
    expect(d.storage.data.size).toBe(1)
  })

  test("clicking a row checks it: it slides out of the list into Completed, struck through with a filled checkbox", async () => {
    const d = launch(source, new Storage({ "item:a": item("a", "Call the dentist", 10), "item:b": item("b", "Water the plants", 5) }))
    mount(d, "w", "large")
    await d.host.settle(10)
    expect(texts(d.host, "w")[0]).toBe("2")
    const row = rowOf(d.host, "w", "Call the dentist")
    // Rows slide in and out (RowList); the host animates the leave. No timer of the widget's own.
    expect(d.host.tree("w").nodes.get(row)!.props.transition).toBe("slide")
    d.host.dispatch("w", row, "tap")
    await d.host.settle(10)
    expect(d.host.timers.size).toBe(0)
    expect(texts(d.host, "w")[0]).toBe("1")
    expect(texts(d.host, "w")).not.toContain("Call the dentist")
    expect(texts(d.host, "w")).toContain("1 Completed")
    expect(stored(d.storage).find((i) => i.id === "a")).toMatchObject({ done: true, doneAt: AT })
    // Open Completed: the done row is struck through and dimmed, its checkbox filled with the list's blue.
    d.host.dispatch("w", rowOf(d.host, "w", "1 Completed"), "tap")
    await d.host.settle(10)
    expect(textOf(d.host, "w", "Call the dentist")!.props).toMatchObject({ strikethrough: true, color: "secondary" })
    expect(textOf(d.host, "w", "Water the plants")!.props.strikethrough).toBe(false)
    expect(nodes(d.host, "w").filter(([, n]) => n.type === "Circle" && n.props.fill === "#007AFF")).toHaveLength(1)
  })

  test("the list color is a hex: a named Reminders color, a typed hex, or blue", async () => {
    for (const [color, hex] of [["orange", "#FF9500"], ["#5ac8fa", "#5AC8FA"], ["", "#007AFF"], ["nope", "#007AFF"]] as const) {
      const d = launch(source, new Storage({ "item:a": item("a", "Send the invoice", 10, true) }))
      mount(d, "w", "large", { color })
      await d.host.settle(10)
      expect(textOf(d.host, "w", "To Do")!.props.color).toBe(hex)
      d.host.dispatch("w", rowOf(d.host, "w", "1 Completed"), "tap")
      await d.host.settle(10)
      expect(nodes(d.host, "w").some(([, n]) => n.type === "Circle" && n.props.fill === hex)).toBe(true)
    }
  })

  test("large: the Completed row opens the done items, which un-check on a click", async () => {
    const d = launch(source, new Storage(SAMPLE))
    mount(d, "w", "large")
    await d.host.settle(10)
    expect(texts(d.host, "w")).toContain("3 Completed")
    expect(texts(d.host, "w")).not.toContain("Send the invoice")
    d.host.dispatch("w", rowOf(d.host, "w", "3 Completed"), "tap")
    await d.host.settle(10)
    expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["Send the invoice", "Water the plants"]))
    d.host.dispatch("w", rowOf(d.host, "w", "Send the invoice"), "tap")
    await d.host.settle(10)
    expect(texts(d.host, "w")).toContain("2 Completed")
    expect(stored(d.storage).find((i) => i.id === "i")!.done).toBe(false)
  })

  test("small shows the count and the first three open items, oldest first, and how many more", async () => {
    const d = launch(source, new Storage(SAMPLE))
    mount(d, "w", "small")
    await d.host.settle(10)
    const shown = texts(d.host, "w")
    expect(shown.slice(0, 2)).toEqual(["6", "To Do"])
    expect(shown).toEqual(expect.arrayContaining(["Pick up dry cleaning", "Book flights for the offsite", "Call the dentist", "3 more"]))
    expect(shown).not.toContain("Renew passport")
    expect(d.host.findNode("w", (n) => n.type === "TextField")).toBeUndefined()
  })

  test("persisted: a restart shows the same list, checks and all", async () => {
    const storage = new Storage()
    const first = launch(source, storage)
    mount(first, "w", "large")
    await first.host.settle(10)
    await type(first, "w", "Renew passport")
    await type(first, "w", "Send the invoice")
    first.host.dispatch("w", rowOf(first.host, "w", "Renew passport"), "tap")
    await first.host.settle(10)

    const again = launch(source, storage, { now: AT + 3600_000 })
    mount(again, "w", "large")
    await again.host.settle(10)
    expect(texts(again.host, "w")).toEqual(expect.arrayContaining(["1", "Send the invoice", "1 Completed"]))
    expect(texts(again.host, "w")).not.toContain("Renew passport")
  })

  test("delete from the row's menu removes it and keeps a tombstone, so it does not come back", async () => {
    const d = launch(source, new Storage({ "item:a": item("a", "Call the dentist", 10) }))
    mount(d, "w", "medium")
    await d.host.settle(10)
    d.host.dispatch("w", rowOf(d.host, "w", "Call the dentist"), "menu", { path: [1] })
    await d.host.settle(10)
    expect(texts(d.host, "w")).toContain("Nothing to do")
    expect(stored(d.storage)[0]).toMatchObject({ id: "a", deleted: true })
  })

  test("the Add Widget preview shows sample items and never reads or writes storage", async () => {
    const d = launch(source, new Storage(SAMPLE))
    d.host.mount("p", "renderTodo", { surface: "widget", size: "medium", place: "newtab", instance: "gallery", settings: {}, preview: true })
    await d.host.settle(10)
    expect(texts(d.host, "p")).toEqual(expect.arrayContaining(["3", "Buy milk", "Call the dentist", "Water the plants"]))
    d.host.dispatch("p", rowOf(d.host, "p", "Buy milk"), "tap")
    await type(d, "p", "Nope")
    expect(d.host.calls.filter((c) => c.name.startsWith("app.storage."))).toEqual([])
  })

  test("every tile of the widget shows the one list", async () => {
    const d = launch(source)
    mount(d, "s", "small")
    mount(d, "l", "large")
    await d.host.settle(10)
    await type(d, "l", "Back up the laptop")
    expect(texts(d.host, "s")).toEqual(expect.arrayContaining(["1", "Back up the laptop"]))
  })
})

/**
 * Two devices with synced app storage: each has its own replica; `sync()` exchanges them the way
 * the synced scope does (per key, the newer item wins) and tells each app its keys changed
 * (`app.storage.changed`).
 */
function syncAll(...devices: Device[]) {
  const keys = new Set(devices.flatMap((d) => [...d.storage.data.keys()]))
  for (const key of keys) {
    const versions = devices.map((d) => d.storage.data.get(key)).filter(Boolean) as Item[]
    const winner = [...merge(versions, []).values()][0]!
    for (const d of devices) d.storage.data.set(key, structuredClone(winner))
  }
  for (const d of devices) d.host.emit("app.storage.changed", { keys: [...keys] })
}

/**
 * A server that keeps, per key, whichever write reached it last, with no idea of the item's own
 * times: devices are listed in the order their writes arrive.
 */
function syncLastArrival(...devicesInArrivalOrder: Device[]) {
  const keys = new Set(devicesInArrivalOrder.flatMap((d) => [...d.storage.data.keys()]))
  for (const key of keys) {
    const last = devicesInArrivalOrder.filter((d) => d.storage.data.has(key)).at(-1)!
    const value = last.storage.data.get(key)
    for (const d of devicesInArrivalOrder) d.storage.data.set(key, structuredClone(value))
  }
  for (const d of devicesInArrivalOrder) d.host.emit("app.storage.changed", { keys: [...keys] })
}

describe("sync across two devices", () => {
  test("changes on each device show on the other; concurrent edits to different items both survive", async () => {
    const mac = launch(source, new Storage(), { now: AT })
    const phone = launch(source, new Storage(), { now: AT + 1 })
    for (const d of [mac, phone]) mount(d, "w", "large")
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    // The widget listens for other devices' changes.
    expect([...mac.host.subscriptions.values()].map((s) => s.stream)).toContain("app.storage.changed")

    await type(mac, "w", "Buy milk")
    await type(phone, "w", "Call mom")
    syncAll(mac, phone)
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    for (const d of [mac, phone]) expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["2", "Buy milk", "Call mom"]))

    // Offline at the same time: the Mac checks off "Buy milk", the phone adds an item and deletes "Call mom".
    mac.host.eval(`globalThis.__now = ${AT + 60_000}`)
    phone.host.eval(`globalThis.__now = ${AT + 61_000}`)
    mac.host.dispatch("w", rowOf(mac.host, "w", "Buy milk"), "tap")
    await type(phone, "w", "Pay rent")
    phone.host.dispatch("w", rowOf(phone.host, "w", "Call mom"), "menu", { path: [1] })
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    syncAll(mac, phone)
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    for (const d of [mac, phone]) {
      expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["1", "Pay rent", "1 Completed"]))
      expect(texts(d.host, "w")).not.toContain("Call mom")
      expect(texts(d.host, "w")).not.toContain("Buy milk")
    }
    expect([...mac.storage.data.entries()].sort()).toEqual([...phone.storage.data.entries()].sort())
  })

  test("the same item changed on both: the later change wins on both devices", async () => {
    const seed = { "item:a": item("a", "Call the dentist", 10) }
    const mac = launch(source, new Storage(seed), { now: AT + 1000 })
    const phone = launch(source, new Storage(seed), { now: AT + 2000 })
    for (const d of [mac, phone]) mount(d, "w", "medium")
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    mac.host.dispatch("w", rowOf(mac.host, "w", "Call the dentist"), "tap") // checks it at +1 s
    phone.host.dispatch("w", rowOf(phone.host, "w", "Call the dentist"), "menu", { path: [1] }) // deletes it at +2 s
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    syncAll(mac, phone)
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    for (const d of [mac, phone]) {
      expect(texts(d.host, "w")).toContain("Nothing to do")
      expect(stored(d.storage)[0]).toMatchObject({ deleted: true })
    }
  })

  test("a read that started before a local change does not undo it", async () => {
    const d = launch(source, new Storage({ "item:a": item("a", "Call the dentist", 10) }))
    mount(d, "w", "medium")
    await d.host.settle(10)
    // Another device's change arrives; the read it starts sees the list before the check-off below,
    // and its answer is held back until after the check-off was saved.
    const answers: Array<() => void> = []
    const get = d.host.handlers["app.storage.get"]!
    d.host.handlers["app.storage.get"] = (p, o) => {
      const before = get(p, o)
      return new Promise((resolve) => answers.push(() => resolve(before)))
    }
    d.host.emit("app.storage.changed", {})
    await d.host.settle(10)
    expect(answers.length).toBe(1)
    d.host.dispatch("w", rowOf(d.host, "w", "Call the dentist"), "tap")
    await d.host.settle(10)
    expect(stored(d.storage)[0]).toMatchObject({ done: true })
    d.host.handlers["app.storage.get"] = get
    for (const answer of answers) answer()
    await d.host.settle(10)
    expect(texts(d.host, "w")).toContain("0")
    expect(stored(d.storage)[0]).toMatchObject({ done: true })
  })

  test("storage that keeps whichever write arrived last still ends at the newest change everywhere", async () => {
    const seed = { "item:a": item("a", "Call the dentist", 10) }
    const mac = launch(source, new Storage(seed), { now: AT + 2000 })
    const phone = launch(source, new Storage(seed), { now: AT + 1000 })
    for (const d of [mac, phone]) mount(d, "w", "medium")
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    mac.host.dispatch("w", rowOf(mac.host, "w", "Call the dentist"), "menu", { path: [1] }) // deletes it at +2 s
    phone.host.dispatch("w", rowOf(phone.host, "w", "Call the dentist"), "tap") // checks it at +1 s
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    // The phone's older check reaches the server last, so the server keeps it.
    syncLastArrival(mac, phone)
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    // The Mac sees an older version stored and writes its newer delete back; that write arrives last.
    syncLastArrival(phone, mac)
    await Promise.all([mac.host.settle(10), phone.host.settle(10)])
    for (const d of [mac, phone]) {
      expect(texts(d.host, "w")).toContain("Nothing to do")
      expect(stored(d.storage)[0]).toMatchObject({ deleted: true })
    }
  })

  test("a save that failed keeps its warning until a later read saves it again", async () => {
    const d = launch(source)
    mount(d, "w", "medium")
    await d.host.settle(10)
    const set = d.host.handlers["app.storage.set"]!
    d.host.handlers["app.storage.set"] = () => ({ ok: false, body: { code: "storage.unavailable", message: "disk full", retryable: true } })
    await type(d, "w", "Buy milk")
    expect(texts(d.host, "w")).toContain("Couldn't save: disk full")
    // A read that succeeds while the save is still missing does not hide the warning.
    d.host.handlers["app.storage.set"] = (p, o) => (p.key.startsWith("item:") ? { ok: false, body: { code: "storage.unavailable", message: "disk full", retryable: true } } : set(p, o))
    d.host.emit("app.storage.changed", {})
    await d.host.settle(10)
    expect(texts(d.host, "w")).toContain("Couldn't save: disk full")
    // Once storage works again, the next read saves the item and the warning goes.
    d.host.handlers["app.storage.set"] = set
    d.host.emit("app.storage.changed", {})
    await d.host.settle(10)
    expect(texts(d.host, "w").some((t) => t.startsWith("Couldn't save"))).toBe(false)
    expect(stored(d.storage)).toEqual([expect.objectContaining({ text: "Buy milk" })])
    const restarted = launch(source, d.storage)
    mount(restarted, "w", "medium")
    await restarted.host.settle(10)
    expect(texts(restarted.host, "w")).toContain("Buy milk")
  })

  test("quick changes to one item are stored newest last, even when storage answers out of order", async () => {
    const d = launch(source, new Storage({ "item:a": item("a", "Call the dentist", 10), "item:z": item("z", "Old", 1, true) }))
    mount(d, "w", "large")
    await d.host.settle(10)
    d.host.dispatch("w", rowOf(d.host, "w", "1 Completed"), "tap") // open Completed, so the checked row stays clickable
    await d.host.settle(10)
    // Storage that applies each write when it answers, and answers whenever the test says.
    const held: Array<() => void> = []
    d.host.handlers["app.storage.set"] = (p) =>
      new Promise((resolve) =>
        held.push(() => {
          d.storage.data.set(p.key, structuredClone(p.value))
          resolve({ ok: true, body: { value: null } })
        })
      )
    const row = () => rowOf(d.host, "w", "Call the dentist")
    d.host.dispatch("w", row(), "tap") // check
    await d.host.settle(10)
    d.host.dispatch("w", row(), "tap") // un-check it from Completed before the first save answered
    await d.host.settle(10)
    // Answer every write held so far, newest first, until none is left.
    while (held.length > 0) {
      for (const answer of held.splice(0).reverse()) answer()
      await d.host.settle(10)
    }
    expect(d.storage.data.get("item:a")).toMatchObject({ done: false })
    const restarted = launch(source, d.storage)
    mount(restarted, "w", "medium")
    await restarted.host.settle(10)
    expect(texts(restarted.host, "w")).toContain("1")
  })

  test("Clear removes the Completed items and leaves the open ones", async () => {
    const d = launch(source, new Storage({ "item:a": item("a", "Send the invoice", 10, true), "item:b": item("b", "Call the dentist", 11), "item:c": item("c", "Renew passport", 12) }))
    mount(d, "w", "large")
    await d.host.settle(10)
    d.host.dispatch("w", rowOf(d.host, "w", "Call the dentist"), "tap") // checked: now in Completed too
    await d.host.settle(10)
    d.host.dispatch("w", rowOf(d.host, "w", "2 Completed"), "tap")
    await d.host.settle(10)
    const clear = nodes(d.host, "w").find(([, n]) => n.type === "Button" && n.props.title === "Clear")?.[0]
    expect(clear).toBeDefined()
    d.host.dispatch("w", clear!, "tap")
    await d.host.settle(10)
    expect(d.storage.data.get("item:a")).toMatchObject({ deleted: true })
    expect(d.storage.data.get("item:b")).toMatchObject({ deleted: true })
    expect(d.storage.data.get("item:c")).not.toHaveProperty("deleted")
    expect(texts(d.host, "w")).toEqual(expect.arrayContaining(["1", "Renew passport"]))
    expect(texts(d.host, "w").some((t) => t.endsWith("Completed"))).toBe(false)
  })
})
