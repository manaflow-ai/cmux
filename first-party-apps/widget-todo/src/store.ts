// The list, shared by every placed tile of this widget: read from app storage once, changed here at
// once, then saved item by item. A re-read (another device's change arriving, or a new mount) merges
// with what is shown, item by item, so a save still in flight is never lost to an older read, and
// writes back every item whose shown copy is newer than the stored one. Storage that keeps whichever
// write arrived last (as a synced store does) therefore still ends at the newest version on every
// device, and a save that failed is retried on the next read.

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
/** Items whose last save failed: the warning stays up until each is saved. */
const failed = new Set<string>()

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
      const now = Date.now()
      const kept = new Map(stored.map((i) => [i.id, i]))
      const merged = merge(items().values(), stored)
      // A removal past the tombstone window is gone from storage (readAll deleted it): forget it here too.
      for (const [id, item] of merged) if (item.deleted && now - item.updated > TOMBSTONE_MS) merged.delete(id)
      setItems(merged)
      setLoaded(true)
      for (const item of merged.values()) {
        const was = kept.get(item.id)
        if (!was || was.updated !== item.updated || was.by !== item.by) save(item)
      }
      if (failed.size === 0) setProblem(null)
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

/** The newest version of each item still to be written, and the items with a write in flight. */
const pending = new Map<string, Item>()
const writing = new Set<string>()

/**
 * Saves `item`. Writes to one item go one at a time, newest version only: a second change made while
 * a write is in flight waits for it, so two writes can never land out of order and leave the older
 * version stored. The warning for an item clears only when its newest version is saved.
 */
function save(item: Item) {
  pending.set(item.id, item)
  if (!writing.has(item.id)) flush(item.id)
}

function flush(id: string) {
  const item = pending.get(id)
  if (!item) return
  pending.delete(id)
  writing.add(id)
  cmux.storage.set(itemKey(id), item).then(
    () => {
      if (!pending.has(id)) failed.delete(id)
      if (failed.size === 0) setProblem(null)
    },
    (error: unknown) => {
      failed.add(id)
      setProblem(message(error))
    }
  ).finally(() => {
    writing.delete(id)
    flush(id)
  })
}

/** Shows `next` at once, then saves it. */
function put(next: Item) {
  setItems((all) => new Map(all).set(next.id, next))
  save(next)
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

/** Removes the done items in the Completed section; one checked a moment ago (still shown, faded) stays. */
export function clearCompleted() {
  const shown = settling()
  for (const item of items().values()) if (item.done && !item.deleted && !shown.has(item.id)) remove(item.id)
}
