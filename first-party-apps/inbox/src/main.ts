/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Inbox: a view on the cmux feed, the one system for notifications and
// requests. Agents, apps, runs and integrations (GitHub review requests and
// failing checks) post feed items; this app lists, opens, marks, snoozes and
// answers them. Exports: the section, status item and pane renders, and the
// commands (palette, CLI, MCP tools).

import { markAllSeen as markAllSeenItems, markDone as markItemsDone, openItem as openFeedItem, snoozeItems, step } from "./actions.ts"
import { feed, type FeedItem, type SourceKind } from "./feed.ts"
import { t } from "./l10n.ts"
import { current, cycleVariant as cycle, items, listNow, listParams, setSelected, variant } from "./store.ts"
import { StatusItem } from "./views/status.ts"
import { renderCard, renderFocus, renderGrouped } from "./views/variants.ts"

const RENDERERS = { grouped: renderGrouped, focus: renderFocus, card: renderCard }

/** Renders the chosen variant; a variant change rebuilds the subtree (its reads and signals go with it). */
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

// Commands. Each is a palette entry and, with `mcp:expose`, an MCP tool.
// There is deliberately no `respond` command: answering a request needs origin
// `user`, and only the item's addressee may answer it through MCP.

function commandError(code: string, message: string): Error {
  // The runtime's CmuxError carries a code to the caller (CLI exit, MCP error); the typings omit its constructor.
  const E = CmuxError as unknown as new (code: string, message: string) => Error
  return new E(code, message)
}

async function findItem(id: unknown): Promise<FeedItem> {
  if (typeof id === "string" && id) {
    try {
      return await feed.get(id)
    } catch {
      throw commandError("item.not_found", t("item.notFound", "No inbox item {id}", { id }))
    }
  }
  if (items().length === 0) await listNow()
  const item = current()
  if (!item) throw commandError("item.not_found", t("item.noneSelected", "No inbox item is selected"))
  return item
}

/** Opens the inbox as a tab (proposed op `app.pane.open`). */
export async function openInbox() {
  try {
    await cmux.call("app.pane.open", { contribution: `${cmux.app.id}#pane` })
    return { opened: true }
  } catch (e) {
    throw commandError((e as { code?: string }).code ?? "operation.failed", t("pane.unsupported", "This cmux cannot open app panes yet; use the Inbox sidebar section."))
  }
}

export async function markAllSeen() {
  return { marked: await markAllSeenItems() }
}

async function move(direction: 1 | -1, args: { open?: boolean }) {
  if (items().length === 0) await listNow()
  const item = step(direction)
  if (item && args.open !== false) await openFeedItem(item)
  return { id: item?.id ?? null }
}

export const nextItem = (args: { open?: boolean } = {}) => move(1, args)
export const previousItem = (args: { open?: boolean } = {}) => move(-1, args)

export async function openItem(args: { id?: string } = {}) {
  const item = await findItem(args.id)
  setSelected(item.id)
  await openFeedItem(item)
  return { id: item.id }
}

export async function markDone(args: { id?: string } = {}) {
  const item = await findItem(args.id)
  await markItemsDone([item])
  return { id: item.id, done: true }
}

export async function snooze(args: { id?: string; minutes?: number } = {}) {
  const item = await findItem(args.id)
  const minutes = typeof args.minutes === "number" && args.minutes > 0 ? Math.min(args.minutes, 60 * 24 * 30) : 60
  const until = Date.now() + minutes * 60_000
  await snoozeItems([item], until)
  return { id: item.id, until: new Date(until).toISOString() }
}

/** The owner's items as JSON for agents. */
export async function list(args: { source?: SourceKind; needsResponse?: boolean; unseen?: boolean; includeSnoozed?: boolean; limit?: number } = {}) {
  const base = listParams(false)
  const r = await feed.list({
    filter: {
      status: args.includeSnoozed ? ["open", "snoozed"] : ["open"],
      ...(args.source ? { sources: [args.source] } : {}),
      ...(args.needsResponse ? { needsResponse: true } : {}),
      ...(args.unseen ? { unseen: true } : {})
    },
    limit: typeof args.limit === "number" ? Math.max(1, Math.min(args.limit, 200)) : base.limit
  })
  return {
    items: r.items.map((i) => ({
      id: i.id,
      kind: i.kind,
      request_kind: i.requestKind ?? null,
      title: i.title,
      body: i.body ?? null,
      urgency: i.urgency,
      needs_response: i.needsResponse,
      source: i.source,
      subject: i.subject,
      status: i.status,
      seen: i.seenAt !== null,
      snoozed_until: i.snoozedUntil,
      updated_at: i.updatedAt
    })),
    counts: r.counts,
    revision: r.revision
  }
}

export async function refresh() {
  const r = await listNow()
  return { items: r.items.length, revision: r.revision }
}

export async function cycleVariant() {
  return { variant: await cycle() }
}
