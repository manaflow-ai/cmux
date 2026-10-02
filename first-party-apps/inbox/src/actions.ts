/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// What the user (or an agent through a command) does to items. Every view and
// command goes through these, so tap, menu, palette and MCP share one path.

import { t } from "./l10n.ts"
import { markSeen } from "./ledger.ts"
import { neighbor, type ViewItem } from "./model.ts"
import { clearSnooze, clientId, describe, doneIds, noticeFor, selected, setReplyBlocked, setSelected, snoozeIds, terminalTab, updateLedger, visible } from "./store.ts"

const ACK_BATCH = 256

/** Marks cmux notifications read for this app's client id in the daemon's ledger (shared by every client). */
async function ack(ids: readonly string[]): Promise<void> {
  for (let i = 0; i < ids.length; i += ACK_BATCH) {
    try {
      await cmux.notification.ack({ client_id: clientId(), notifications: ids.slice(i, i + ACK_BATCH) })
    } catch (e) {
      cmux.log(`ack: ${describe(e)}`)
    }
  }
}

/**
 * Opens an item: the agent's or notification's tab, or the pull request in a
 * browser tab. The focus call is issued first and synchronously when the tab
 * is known, so it runs inside the tap's user turn (origin `user`).
 */
export async function openItem(item: ViewItem): Promise<void> {
  setSelected(item.id)
  let opening: Promise<unknown> | null = null
  try {
    if (item.url) opening = cmux.actions.run("openBrowser", { url: item.url })
    else if (item.terminal) {
      const tab = terminalTab(item.terminal)
      opening = tab ? cmux.tab.focus({ tab }) : cmux.terminal.get({ terminal: item.terminal }).then((x) => (x.tab_id ? cmux.tab.focus({ tab: x.tab_id }) : null))
    }
  } catch (e) {
    noticeFor(t("error.open", "Could not open: {reason}", { reason: describe(e) }))
  }
  await markRead([item])
  if (opening) await opening.catch((e: unknown) => noticeFor(t("error.open", "Could not open: {reason}", { reason: describe(e) })))
}

export async function markRead(list: readonly ViewItem[]): Promise<void> {
  await updateLedger((l) => markSeen(l, list))
  await ack(list.flatMap((i) => i.notifications))
}

/** Finishes items; the selection moves to the next item still in the list. */
export async function markDone(list: readonly ViewItem[]): Promise<void> {
  const gone = new Set(list.map((i) => i.id))
  const sel = selected()
  if (sel && gone.has(sel)) {
    const remaining = visible().filter((i) => !gone.has(i.id) || i.id === sel)
    const next = neighbor(remaining, sel, 1)
    setSelected(next && !gone.has(next) ? next : null)
  }
  await doneIds([...list])
  await ack(list.flatMap((i) => i.notifications))
}

export async function snoozeItems(list: readonly ViewItem[], until: number): Promise<void> {
  const ids = list.map((i) => i.id)
  const sel = selected()
  if (sel && ids.includes(sel)) setSelected(neighbor(visible().filter((i) => !ids.includes(i.id) || i.id === sel), sel, 1))
  await snoozeIds(ids, until)
}

export const unsnoozeItems = (list: readonly ViewItem[]) => clearSnooze(list.map((i) => i.id))

export async function markAllRead(): Promise<number> {
  const unread = visible().filter((i) => i.unread)
  await markRead(unread)
  return unread.length
}

/** Moves the selection from `from` (default: the selection; none selected starts at the ends). */
export function step(direction: 1 | -1, from: string | null = selected()): ViewItem | null {
  const id = neighbor(visible(), from, direction)
  setSelected(id)
  return visible().find((i) => i.id === id) ?? null
}

/** Types a reply into an agent's terminal (needs the optional `terminal:execute` scope). */
export async function reply(item: ViewItem, text: string): Promise<boolean> {
  const message = text.trim()
  if (!item.terminal || !message) return false
  try {
    await cmux.terminal.input.write({ terminal: item.terminal, text: `${message}\r` })
    await markRead([item])
    noticeFor(t("reply.sent", "Sent"))
    return true
  } catch (e) {
    if ((e as { code?: string }).code === "scope.missing") setReplyBlocked(true)
    else noticeFor(t("error.reply", "Could not send: {reason}", { reason: describe(e) }))
    return false
  }
}
