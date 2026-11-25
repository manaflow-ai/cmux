// The to-do list as data, with no host calls: what an item is, how two copies of the list merge,
// and which items each widget size shows.
//
// Each item is its own storage key (`item:<id>`), so two devices that change different items never
// overwrite each other. Two changes to the same item resolve by the later `updated` time (ties by
// the larger `by`, the writing device's random id), and a removal is a tombstone (`deleted`) that
// wins over older edits, so an item removed on one device does not come back from another.

export interface Item {
  id: string
  text: string
  done: boolean
  /** When the item was added (ms): the list's order, oldest first, as in Reminders. */
  created: number
  /** When the item last changed (ms): the newer change wins a merge. */
  updated: number
  /** The device that wrote this version: breaks a tie between two changes in the same millisecond. */
  by: string
  /** When it was checked off (ms). */
  doneAt?: number
  /** A removed item, kept so the removal syncs. */
  deleted?: boolean
}

export const ITEM_PREFIX = "item:"
export const MAX_TEXT = 500
/** Tombstones older than this are dropped for good. */
export const TOMBSTONE_MS = 30 * 24 * 3600 * 1000

export const itemKey = (id: string) => `${ITEM_PREFIX}${id}`

/** True when `value` is a stored item (anything else under the prefix is ignored, never thrown on). */
export function isItem(value: unknown): value is Item {
  const v = value as Item | null
  return (
    !!v &&
    typeof v === "object" &&
    typeof v.id === "string" &&
    typeof v.text === "string" &&
    typeof v.done === "boolean" &&
    typeof v.created === "number" &&
    typeof v.updated === "number"
  )
}

/** Which of two versions of one item wins. */
export function newer(a: Item, b: Item): Item {
  if (a.updated !== b.updated) return a.updated > b.updated ? a : b
  return String(a.by ?? "") >= String(b.by ?? "") ? a : b
}

/** Merges two copies of the list: per item, the newer version. */
export function merge(a: Iterable<Item>, b: Iterable<Item>): Map<string, Item> {
  const out = new Map<string, Item>()
  for (const item of [...a, ...b]) {
    const have = out.get(item.id)
    out.set(item.id, have ? newer(have, item) : item)
  }
  return out
}

const byCreated = (a: Item, b: Item) => a.created - b.created || a.id.localeCompare(b.id)

/** The items to show: open ones oldest first, and done ones, most recently done first. */
export function split(items: Iterable<Item>) {
  const live = [...items].filter((i) => !i.deleted)
  const open = live.filter((i) => !i.done).sort(byCreated)
  const done = live.filter((i) => i.done).sort((a, b) => (b.doneAt ?? b.updated) - (a.doneAt ?? a.updated))
  const remaining = live.filter((i) => !i.done).length
  return { open, done, remaining }
}

export type Size = "small" | "medium" | "large"

/** How many open rows each size has room for, next to the header and New item (Apple's Reminders widget shows 3, 4 and 7 with no field). */
export const ROWS: Record<Size, number> = { small: 3, medium: 3, large: 7 }

export function normalizeSize(value: unknown): Size {
  return value === "medium" || value === "large" ? value : "small"
}

/** The trimmed text of a new item, or null when there is nothing to add. */
export function cleanText(text: string): string | null {
  const value = text.replace(/\s+/g, " ").trim()
  return value ? value.slice(0, MAX_TEXT) : null
}
