// Pure helpers for what the app remembers (memory.ts stores them).

const MAX_RECENT = 8
const MAX_OPENED = 100

/** Adds a query to the front of the recent list (deduplicated, capped). Pure. */
export function pushRecent(list: readonly string[], query: string): string[] {
  const q = query.trim()
  if (!q) return [...list]
  return [q, ...list.filter((x) => x !== q)].slice(0, MAX_RECENT)
}

/** Records that a hit was opened now, keeping the newest entries. Pure. */
export function markOpened(opened: Readonly<Record<string, number>>, id: string, nowMs: number): Record<string, number> {
  const entries = Object.entries({ ...opened, [id]: nowMs }).sort((a, b) => b[1] - a[1])
  return Object.fromEntries(entries.slice(0, MAX_OPENED))
}
