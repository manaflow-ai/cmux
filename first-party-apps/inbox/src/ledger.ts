// The triage ledger: what the user has seen, finished and snoozed. Pure
// functions over a plain object that lives in app storage (per machine until
// synced app storage exists). Stamps are the item's `at` when it was
// handled, so an item that changes afterwards (a new notification for the
// agent, a new push to the pull request) comes back.

export interface Ledger {
  v: 1
  seen: Record<string, number>
  done: Record<string, number>
  /** id -> wake time in ms. */
  snooze: Record<string, number>
  /** GitHub items present on the first successful load are treated as seen, so old work does not badge. */
  githubSeeded: boolean
}

export const emptyLedger = (): Ledger => ({ v: 1, seen: {}, done: {}, snooze: {}, githubSeeded: false })

const numberMap = (v: unknown): Record<string, number> => {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {}
  const out: Record<string, number> = {}
  for (const [k, n] of Object.entries(v as Record<string, unknown>)) if (typeof n === "number" && Number.isFinite(n)) out[k] = n
  return out
}

/** Reads a stored ledger, dropping anything malformed. */
export function parseLedger(raw: unknown): Ledger {
  if (!raw || typeof raw !== "object") return emptyLedger()
  const r = raw as Record<string, unknown>
  return { v: 1, seen: numberMap(r.seen), done: numberMap(r.done), snooze: numberMap(r.snooze), githubSeeded: r.githubSeeded === true }
}

export const isSeen = (l: Ledger, id: string, at: number) => (l.seen[id] ?? -1) >= at
export const isDone = (l: Ledger, id: string, at: number) => (l.done[id] ?? -1) >= at
export const snoozedUntil = (l: Ledger, id: string, now: number) => {
  const until = l.snooze[id]
  return until !== undefined && until > now ? until : null
}

type Stamped = { id: string; at: number }

const stamp = (map: Record<string, number>, items: readonly Stamped[]) => {
  const next = { ...map }
  for (const i of items) next[i.id] = Math.max(next[i.id] ?? -1, i.at)
  return next
}

export const markSeen = (l: Ledger, items: readonly Stamped[]): Ledger => ({ ...l, seen: stamp(l.seen, items) })

/** Done implies seen; a finished item also stops being snoozed. */
export function markDone(l: Ledger, items: readonly Stamped[]): Ledger {
  const snooze = { ...l.snooze }
  for (const i of items) delete snooze[i.id]
  return { ...l, seen: stamp(l.seen, items), done: stamp(l.done, items), snooze }
}

export function snooze(l: Ledger, ids: readonly string[], until: number): Ledger {
  const next = { ...l.snooze }
  for (const id of ids) next[id] = until
  return { ...l, snooze: next }
}

export function unsnooze(l: Ledger, ids: readonly string[]): Ledger {
  const next = { ...l.snooze }
  for (const id of ids) delete next[id]
  return { ...l, snooze: next }
}

/** Ends every snooze due at `now`; woken items read as unread again. */
export function wake(l: Ledger, now: number): { ledger: Ledger; woke: string[] } {
  const woke = Object.entries(l.snooze)
    .filter(([, until]) => until <= now)
    .map(([id]) => id)
  if (woke.length === 0) return { ledger: l, woke }
  const snoozeMap = { ...l.snooze }
  const seen = { ...l.seen }
  for (const id of woke) {
    delete snoozeMap[id]
    delete seen[id]
  }
  return { ledger: { ...l, snooze: snoozeMap, seen }, woke }
}

/** The earliest pending wake time, for one one-shot timer. */
export function nextWake(l: Ledger, now: number): number | null {
  let best: number | null = null
  for (const until of Object.values(l.snooze)) if (until > now && (best === null || until < best)) best = until
  return best
}

export const MAX_ENTRIES = 2000
const RETAIN_MS = 30 * 86_400_000

/**
 * Keeps entries for items that still exist and recent entries for the rest
 * (an agent may come back), and caps each map at MAX_ENTRIES newest stamps.
 */
export function prune(l: Ledger, liveIds: ReadonlySet<string>, now: number): Ledger {
  const keep = (map: Record<string, number>, stampIsTime: boolean) => {
    const entries = Object.entries(map).filter(([id, v]) => liveIds.has(id) || (stampIsTime ? v > now - RETAIN_MS : true))
    entries.sort((a, b) => b[1] - a[1])
    return Object.fromEntries(entries.slice(0, MAX_ENTRIES))
  }
  return { ...l, seen: keep(l.seen, true), done: keep(l.done, true), snooze: keep(l.snooze, false) }
}
