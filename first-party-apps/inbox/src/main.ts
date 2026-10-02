/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Inbox: one triage list of everything that needs you: cmux notifications,
// agents that wait for input or just finished, and GitHub work items through
// the integration gateway. Exports: the section, status item and pane
// renders, and the commands (palette, CLI, MCP tools).

import { markAllRead as markAllReadItems, markDone as markItemsDone, openItem as openViewItem, snoozeItems, step } from "./actions.ts"
import { t } from "./l10n.ts"
import { itemJSON, type Source, type ViewItem } from "./model.ts"
import { attach, current, cycleVariant as cycle, ensureData, items, refreshGithub, scheduleGithub, setSelected, variant, visible } from "./store.ts"
import { StatusItem } from "./views/status.ts"
import { renderCard, renderFocus, renderGrouped } from "./views/variants.ts"

const RENDERERS = { grouped: renderGrouped, focus: renderFocus, card: renderCard }

/** Renders the chosen variant; a variant change rebuilds the subtree (its signals and reads go with it). */
function surface(wide: boolean): CmuxView {
  attach()
  scheduleGithub()
  return VStack([ForEach({ items: () => [variant()], key: (v) => v }, (v) => RENDERERS[v()](wide))])
}

/** Sidebar section `inbox`. */
export function renderInbox(ctx: { surface?: string } = {}) {
  return surface(ctx.surface === "pane")
}

/** Pane kind `inbox` (the platform does not mount pane kinds yet; the preview harness can). */
export function renderPane() {
  return surface(true)
}

/** Status item `badge`. */
export function renderStatus() {
  attach()
  scheduleGithub()
  return StatusItem()
}

// Commands. Each is a palette entry and, with `mcp:expose`, an MCP tool.

// The runtime's CmuxError carries a code to the caller (CLI exit, MCP error); the typings omit its constructor.
function commandError(code: string, message: string): Error {
  const E = CmuxError as unknown as new (code: string, message: string) => Error
  return new E(code, message)
}

async function findItem(id: unknown): Promise<ViewItem> {
  await ensureData()
  const item = typeof id === "string" && id ? items().find((i) => i.id === id) : (current() ?? undefined)
  if (!item) throw commandError("item.not_found", t("item.notFound", "No inbox item {id}", { id: String(id ?? "") }))
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

export async function markAllRead() {
  await ensureData()
  return { marked: await markAllReadItems() }
}

async function move(direction: 1 | -1, args: { open?: boolean }) {
  await ensureData()
  const item = step(direction)
  if (item && args.open !== false) await openViewItem(item)
  return { id: item?.id ?? null }
}

export const nextItem = (args: { open?: boolean } = {}) => move(1, args)
export const previousItem = (args: { open?: boolean } = {}) => move(-1, args)

export async function openItem(args: { id?: string } = {}) {
  const item = await findItem(args.id)
  setSelected(item.id)
  await openViewItem(item)
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

/** JSON for agents: open items (or snoozed ones), most urgent first. */
export async function list(args: { source?: Source; unreadOnly?: boolean; includeSnoozed?: boolean } = {}) {
  await ensureData()
  const out = items().filter(
    (i) => (args.includeSnoozed || i.snoozedUntil === null) && (!args.source || i.source === args.source) && (!args.unreadOnly || i.unread)
  )
  return { items: out.map(itemJSON), visible: visible().length }
}

export async function refresh() {
  await ensureData()
  await refreshGithub(true)
  return { items: items().length }
}

export async function cycleVariant() {
  return { variant: await cycle() }
}
