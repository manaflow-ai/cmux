/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// What the user does to feed items. Every view and command goes through
// these, so tap, menu and palette share one path. Each is one call to the
// feed owner (or to the feed's own open action); nothing is kept here.

import { feed, isOpenRequest, type FeedFilter, type FeedItem } from "./feed.ts"
import { t } from "./l10n.ts"
import { codeOf, describe, filters, items, noticeFor, selected, setSelected } from "./store.ts"

/** Resolves true when the owner accepted the call; a refusal shows a notice and resolves false. */
const quiet = (p: Promise<unknown>): Promise<boolean> =>
  p.then(
    () => true,
    (e: unknown) => {
      noticeFor(t("error.feed", { reason: describe(e) }))
      return false
    }
  )

/**
 * Opens an item through the feed's own action `feed.openItem`: it reads the
 * item and runs its open target (`tab.focus`, `workspace.focus`, `url.open`,
 * ...), and for sign-in and passkey requests the whole handover (the agent's
 * tab paused, the user's copy opened next to it). Called synchronously in the
 * tap, so the call carries the tap's gesture token (origin user).
 */
export function openItem(item: FeedItem): Promise<boolean> {
  setSelected(item.id)
  return quiet(
    cmux.actions.run("feed.openItem", { item: item.id }).catch((e: unknown) => {
      throw codeOf(e) === "operation.unsupported" ? new Error(t("open.unsupported")) : e
    })
  )
}

/** The gesture token of the running user event; answers and declines refuse to run without one. */
function userGesture(): string | null {
  const g = cmux.gesture()
  if (!g) noticeFor(t("answer.needsTap"))
  return g
}

/**
 * Answers a request. Only the user answers: the call presents the gesture
 * token of the tap that chose the answer (origin user); without one (a
 * command, an agent) nothing is sent.
 */
export function answer(item: FeedItem, value: unknown): Promise<boolean> {
  const gesture = userGesture()
  if (!gesture) return Promise.resolve(false)
  moveSelectionOff([item.id])
  return quiet(feed.answer(item.id, value, gesture))
}

/** Declines a request (`feed.cancel`, reason `declined`): the waiting agent gets "declined". */
export function decline(item: FeedItem): Promise<boolean> {
  const gesture = userGesture()
  if (!gesture || !isOpenRequest(item)) return Promise.resolve(false)
  moveSelectionOff([item.id])
  return quiet(feed.decline(item.id, gesture))
}

export const markRead = (list: readonly FeedItem[]) => {
  const unread = list.filter((i) => i.read_at === null).map((i) => i.id)
  return unread.length ? quiet(feed.read({ items: unread })) : Promise.resolve(false)
}

/** Archives ("done"). Open requests cannot be archived: answer or decline them. */
export function markDone(list: readonly FeedItem[]): Promise<boolean> {
  const ids = list.filter((i) => !isOpenRequest(i)).map((i) => i.id)
  if (!ids.length) return Promise.resolve(false)
  moveSelectionOff(ids)
  return quiet(feed.archive({ items: ids }))
}

/** Snoozes; the owner wakes them, not this app. Open requests cannot be snoozed. */
export function snoozeItems(list: readonly FeedItem[], until: number): Promise<boolean> {
  const ids = list.filter((i) => !isOpenRequest(i)).map((i) => i.id)
  if (!ids.length) return Promise.resolve(false)
  moveSelectionOff(ids)
  return quiet(feed.snooze(ids, until))
}

/** Back from done to the active list. */
export const unarchive = (list: readonly FeedItem[]) => quiet(feed.unarchive(list.map((i) => i.id)))

const currentFilter = (): FeedFilter => (filters().source === "all" ? {} : { poster_kind: filters().source as FeedFilter["poster_kind"] })

/** Reads everything the source filter shows, in one owner call. */
export const markAllRead = () => quiet(filters().source === "all" ? feed.read({ all: true }) : feed.read({ filter: currentFilter() }))

/** Archives everything the source filter shows; the owner skips open requests. */
export const markAllDone = () => quiet(feed.archive({ filter: currentFilter() }))

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
