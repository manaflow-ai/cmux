/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Inbox: a view on the cmux feed, the one system for notices and requests.
// Agents, apps, automations and integrations post feed items; this app lists
// them, opens them through the feed, answers and declines requests for the
// user, and triages the rest. Exports: the section, status item and pane
// renders, and the palette commands. Agents use the feed's own MCP tools and
// CLI (feed.post, feed.list, feed.get, feed.cancel), never this app.

import { markAllRead as markAllReadItems, markDone as markItemsDone, openItem as openFeedItem, snoozeItems, step } from "./actions.ts"
import { feed, isOpenRequest, type FeedItem } from "./feed.ts"
import { t } from "./l10n.ts"
import { current, cycleVariant as cycle, items, listNow, setSelected, variant } from "./store.ts"
import { StatusItem } from "./views/status.ts"
import { renderCard, renderFocus, renderGrouped } from "./views/variants.ts"

const RENDERERS = { grouped: renderGrouped, focus: renderFocus, card: renderCard }

/** Renders the chosen variant; a variant change rebuilds the subtree (its reads and subscriptions go with it). */
const surface = (wide: boolean): CmuxView => VStack([ForEach({ items: () => [variant()], key: (v) => v }, (v) => RENDERERS[v()](wide))])

/** Sidebar section `inbox`. */
export function renderInbox(ctx: { surface?: string } = {}) {
  return surface(ctx.surface === "pane")
}

/** Pane kind `pane` (the platform does not mount pane kinds yet; the preview harness can). */
export function renderPane() {
  return surface(true)
}

/** Status item `badge`. */
export function renderStatus() {
  return StatusItem()
}

// Palette commands. There is no answer or decline command: only the user
// answers, with the gesture of a tap in the inbox or the feed panel.

function commandError(code: string, message: string): Error {
  // The runtime's CmuxError carries a code to the caller (CLI exit); the typings omit its constructor.
  const E = CmuxError as unknown as new (code: string, message: string) => Error
  return new E(code, message)
}

async function findItem(id: unknown): Promise<FeedItem> {
  if (typeof id === "string" && id) {
    try {
      return await feed.get(id)
    } catch {
      throw commandError("item.not_found", t("item.notFound", { id }))
    }
  }
  if (items().length === 0) await listNow()
  const item = current()
  if (!item) throw commandError("item.not_found", t("item.noneSelected"))
  return item
}

/** Opens the inbox as a tab (proposed op `app.pane.open`). */
export async function openInbox(_args: Record<string, unknown> = {}, ctx?: CmuxCommandContext) {
  try {
    await (ctx?.cmux ?? cmux).call("app.pane.open", { contribution: `${cmux.app.id}#pane` })
    return { opened: true }
  } catch (e) {
    throw commandError((e as { code?: string }).code ?? "operation.failed", t("pane.unsupported"))
  }
}

export async function markAllRead() {
  if (!(await markAllReadItems())) throw commandError("feed.refused", t("command.refused"))
  return { read: true }
}

async function move(direction: 1 | -1, args: { open?: boolean }, ctx?: CmuxCommandContext) {
  if (items().length === 0) await listNow()
  const item = step(direction)
  if (item && args.open !== false) await openFeedItem(item, ctx?.cmux)
  return { id: item?.id ?? null }
}

export const nextItem = (args: { open?: boolean } = {}, ctx?: CmuxCommandContext) => move(1, args, ctx)
export const previousItem = (args: { open?: boolean } = {}, ctx?: CmuxCommandContext) => move(-1, args, ctx)

export async function openItem(args: { id?: string } = {}, ctx?: CmuxCommandContext) {
  const item = await findItem(args.id)
  setSelected(item.id)
  await openFeedItem(item, ctx?.cmux)
  return { id: item.id }
}

export async function markDone(args: { id?: string } = {}) {
  const item = await findItem(args.id)
  if (isOpenRequest(item)) throw commandError("feed.open_request", t("request.cannotTriage"))
  if (!(await markItemsDone([item]))) throw commandError("feed.refused", t("command.refused"))
  return { id: item.id, done: true }
}

export async function snooze(args: { id?: string; minutes?: number } = {}) {
  const item = await findItem(args.id)
  if (isOpenRequest(item)) throw commandError("feed.open_request", t("request.cannotTriage"))
  const minutes = typeof args.minutes === "number" && args.minutes > 0 ? Math.min(args.minutes, 60 * 24 * 30) : 60
  const until = Date.now() + minutes * 60_000
  if (!(await snoozeItems([item], until))) throw commandError("feed.refused", t("command.refused"))
  return { id: item.id, until }
}

export async function cycleVariant() {
  return { variant: await cycle() }
}
