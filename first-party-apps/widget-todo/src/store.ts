// The list, shared by every placed tile of this widget: read from app storage once, changed here at
// once, then saved item by item. A re-read (another device's change arriving, or a new mount) merges
// with what is shown, item by item, so a save still in flight is never lost to an older read.

import { cmux, signal } from "cmux-extension-sdk"
import { isItem, ITEM_PREFIX, itemKey, merge, TOMBSTONE_MS, type Item } from "./model.ts"

const [items, setItems] = signal<Map<string, Item>>(new Map())
const [loaded, setLoaded] = signal(false)
const [problem, setProblem] = signal<string | null>(null)
/** Items checked off a moment ago: drawn checked and faded before they leave the open list. */
const [settling, setSettling] = signal<ReadonlySet<string>>(new Set())

export { items, loaded, problem, settling }

/** How long a checked item stays in place, faded, before it leaves the list (Reminders: about a second). */
export const SETTLE_MS = 1200

let device = ""
let nextId = 0
let reading: Promise<void> | null = null
let readAgain = false

const message = (error: unknown) => (error instanceof Error ? error.message : String(error))

/** This install's id for tie breaks: random per run is enough, it only orders same-millisecond writes. */
function deviceId(): string {
  if (!device) device = Math.random().toString(36).slice(2, 10)
  return device
}

function newId(now: number): string {
  nextId += 1
  return `${now.toString(36)}-${deviceId()}-${nextId}`
}

async function readAll(): Promise<Item[]> {
  const keys = (await cmux.storage.keys()).filter((k) => k.startsWith(ITEM_PREFIX))
  const values = await Promise.all(keys.map((k) => cmux.storage.get<Item>(k)))
  const now = Date.now()
  const out: Item[] = []
  values.forEach((value, i) => {
    if (!isItem(value)) return
    // A removal older than the tombstone window has reached every device that syncs: forget it.
    if (value.deleted && now - value.updated > TOMBSTONE_MS) {
      void cmux.storage.delete(keys[i]!).catch(() => {})
      return
    }
    out.push(value)
  })
  return out
}

/** Reads the stored list and merges it into the one shown. Overlapping calls coalesce into one more read. */
export function reload(): Promise<void> {
  if (reading) {
    readAgain = true
    return reading
  }
  reading = readAll().then(
    (stored) => {
      setItems((shown) => merge(shown.values(), stored))
      setLoaded(true)
      setProblem(null)
    },
    (error: unknown) => {
      setLoaded(true)
      setProblem(message(error))
    }
  ).finally(() => {
    reading = null
    if (readAgain) {
      readAgain = false
      void reload()
    }
  })
  return reading
}

let started = false
/** Reads the list the first time any tile mounts, and again whenever another device's change arrives. */
export function start() {
  if (started) return
  started = true
  void reload()
  // Synced storage tells the app when another device changed its keys. A host without that stream
  // answers the subscription with an error; the list then re-reads on each new mount.
  try {
    cmux.events.on("app.storage.changed", () => void reload())
  } catch {
    // no synced storage on this host
  }
}

/** Shows `next` at once, then saves it. */
function put(next: Item) {
  setItems((all) => new Map(all).set(next.id, next))
  cmux.storage.set(itemKey(next.id), next).then(
    () => setProblem(null),
    (error: unknown) => setProblem(message(error))
  )
}

function stamp(item: Item, change: Partial<Item>): Item {
  return { ...item, ...change, updated: Math.max(Date.now(), item.updated + 1), by: deviceId() }
}

export function add(text: string): Item {
  const now = Date.now()
  const item: Item = { id: newId(now), text, done: false, created: now, updated: now, by: deviceId() }
  put(item)
  return item
}

const timers = new Map<string, number>()

function settle(id: string, on: boolean) {
  const old = timers.get(id)
  if (old !== undefined) cmux.timer.clear(old)
  timers.delete(id)
  setSettling((s) => {
    const next = new Set(s)
    if (on) next.add(id)
    else next.delete(id)
    return next
  })
  if (on) {
    timers.set(
      id,
      cmux.timer.after(SETTLE_MS, () => {
        timers.delete(id)
        settle(id, false)
      })
    )
  }
}

/** Checks an item off or back on. A checked item stays, faded, for SETTLE_MS before it leaves the list. */
export function toggle(id: string) {
  const item = items().get(id)
  if (!item || item.deleted) return
  const done = !item.done
  put(stamp(item, done ? { done, doneAt: Date.now() } : { done, doneAt: undefined }))
  settle(id, done)
}

export function remove(id: string) {
  const item = items().get(id)
  if (!item || item.deleted) return
  settle(id, false)
  put(stamp(item, { deleted: true }))
}

export function clearCompleted() {
  for (const item of items().values()) if (item.done && !item.deleted) remove(item.id)
}
