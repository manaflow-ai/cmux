/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// What the user (or an agent through a command) does to feed items. Every
// view and command goes through these, so tap, menu, palette and MCP share
// one path. Each is one call to the feed owner; nothing is kept here.

import { feed, type FeedAction, type FeedItem, type FeedMutation } from "./feed.ts"
import { t } from "./l10n.ts"
import { describe, filters, items, noteRevision, noticeFor, selected, setSelected, toFeedFilter } from "./store.ts"

const fail = (key: string, english: string) => (e: unknown) => {
  noticeFor(t(key, english, { reason: describe(e) }))
  return undefined
}
const settle = (p: Promise<FeedMutation>) => p.then((m) => noteRevision(m?.revision)).catch(fail("error.feed", "The feed did not accept that: {reason}"))

/** Runs an action target from the cmux action registry. */
const run = (target: { action: string; args: Record<string, unknown> }) => cmux.actions.run(target.action, target.args)

/**
 * Opens an item's target (the agent's tab, the pull request, the browser tab
 * for a sign-in) and marks it seen. The target runs first and synchronously,
 * so it is inside the tap's user turn (origin `user`).
 */
export async function openItem(item: FeedItem): Promise<void> {
  setSelected(item.id)
  const opening = item.open ? run(item.open).catch(fail("error.open", "Could not open: {reason}")) : null
  if (item.seenAt === null) await settle(feed.mark([item.id], "seen"))
  await opening
}

export const markSeen = (list: readonly FeedItem[]) => (list.length ? settle(feed.mark(list.map((i) => i.id), "seen")) : Promise.resolve())

/** Finishes items; the selection moves to the next item still listed. */
export async function markDone(list: readonly FeedItem[]): Promise<void> {
  moveSelectionOff(list.map((i) => i.id))
  if (list.length) await settle(feed.mark(list.map((i) => i.id), "done"))
}

/** Snoozes items; the owner wakes them, not this app. */
export async function snoozeItems(list: readonly FeedItem[], until: number): Promise<void> {
  moveSelectionOff(list.map((i) => i.id))
  const at = new Date(until).toISOString()
  for (const item of list) await settle(feed.snooze(item.id, at))
}

/** Back to open (from snoozed or done). */
export const reopen = (list: readonly FeedItem[]) => settle(feed.mark(list.map((i) => i.id), "open"))

/** Answers a request. Must be called synchronously from a tap or menu handler: responding needs origin `user`. */
export function respond(item: FeedItem, value: unknown): Promise<void> {
  const sending = feed.respond(item.id, value)
  moveSelectionOff([item.id])
  return settle(sending)
}

/** One of the item's own actions. */
export function runAction(item: FeedItem, action: FeedAction): Promise<unknown> {
  switch (action.kind) {
    case "open":
      return openItem(item)
    case "respond":
      return respond(item, action.value)
    case "done":
      return markDone([item])
    case "snooze":
      return snoozeItems([item], Date.now() + 3_600_000)
    case "custom":
      return action.target ? run(action.target).catch(fail("error.open", "Could not open: {reason}")) : Promise.resolve()
  }
}

/** Marks everything the current filters show as seen, in one owner call. */
export async function markAllSeen(): Promise<number> {
  const m = await feed.markMatching({ ...toFeedFilter(filters()), unseen: true }, "seen")
  noteRevision(m?.revision)
  return m?.changed ?? 0
}

function moveSelectionOff(ids: string[]) {
  const sel = selected()
  if (!sel || !ids.includes(sel)) return
  const list = items()
  const index = list.findIndex((i) => i.id === sel)
  const next = list.slice(index + 1).find((i) => !ids.includes(i.id)) ?? list.slice(0, index).reverse().find((i) => !ids.includes(i.id))
  setSelected(next?.id ?? null)
}

/** Moves the selection from `from` (default: the selection; none selected starts at the ends). */
export function step(direction: 1 | -1, from: string | null = selected()): FeedItem | null {
  const list = items()
  if (list.length === 0) return null
  const index = from ? list.findIndex((i) => i.id === from) : -1
  const next = index < 0 ? list[direction === 1 ? 0 : list.length - 1]! : list[(index + direction + list.length) % list.length]!
  setSelected(next.id)
  return next
}
