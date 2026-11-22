// User actions on a browser's selection. Every mutation passes the gesture of
// the tap that caused it (finder.md 5.4: destructive and focus-changing ops need
// origin user), and long work becomes a tracked job.

import type { Browser } from "./browser.ts"
import { ops, type OpError } from "./data/ops.ts"
import { t } from "./l10n.ts"
import { buildDragPayload, planDrop, type DragPayload, type Rights } from "./model/drag.ts"
import { join, type Location } from "./model/handles.ts"
import { type ConflictChoice, newJob } from "./model/jobs.ts"
import { dispatchJob, flash, remember, trackJob } from "./store.ts"

/** Copy / Cut keeps the typed payload (handles), so Paste works after the source browser navigated away. */
export type Clip = { op: "copy" | "move"; payload: DragPayload; rights: Rights }
const [clip, setClip] = signal<Clip | null>(null)
export { clip }

const fail = (e: OpError) => {
  flash(e.missing ? t("error.missingOp", "{op} is not available in this version of cmux.", { op: e.op }) : e.message)
  return false
}

export function refuseMessage(reason: string): string {
  switch (reason) {
    case "read_only":
      return t("refuse.readOnly", "This folder is read-only.")
    case "into_itself":
      return t("refuse.intoItself", "A folder cannot go inside itself.")
    case "same_place":
      return t("refuse.samePlace", "The items are already here.")
    default:
      return t("refuse.other", "This drop is not possible.")
  }
}

export function payloadFor(b: Browser, names: readonly string[] = b.selection()): DragPayload | null {
  const loc = b.location()
  const root = b.root()
  if (!loc || !root) return null
  return buildDragPayload(loc, root.display, names, b.allRows(), root.rights)
}

export async function openEntry(b: Browser, name: string, gesture: string | null): Promise<boolean> {
  const e = b.allRows().find((x) => x.name === name)
  const loc = b.location()
  if (!e || !loc) return false
  if (e.kind === "dir" || (e.kind === "symlink" && e.target_kind === "dir")) {
    b.into(name)
    remember({ ...loc, path: join(loc.path, name) }, name)
    return true
  }
  const r = await ops.openDocument({ ...loc, path: join(loc.path, name) }, gesture)
  return r.ok ? true : fail(r.error)
}

/** Copy or move a payload into `to`, through the owners (finder.md 5.2). */
export async function transferPayload(op: "copy" | "move", payload: DragPayload, rights: Rights, to: Location, toWritable: boolean, gesture: string | null): Promise<boolean> {
  const plan = planDrop(payload, { kind: "folder", location: to, writable: toWritable }, rights)
  // Pasting a copy into its own folder is a duplicate (the owner's conflict flow offers Keep Both); a drag onto its own folder is a no-op.
  if (plan.action === "refuse" && !(plan.reason === "same_place" && op === "copy")) {
    flash(refuseMessage(plan.reason))
    return false
  }
  const first = payload.items[0]!.ref
  // One job per source root: the owner of that root runs it (a multi-root selection is not possible from one browser).
  const from = { conn: first.conn, root: first.root, paths: payload.items.map((i) => i.ref.path) }
  const r = await ops.transfer(op, from, to, gesture)
  if (!r.ok) return fail(r.error)
  trackJob(newJob({ id: r.value.job, op, subject: r.value.subject, destination: r.value.destination, crossHost: r.value.cross_host, at: Date.now() }))
  return true
}

export async function transfer(op: "copy" | "move", from: Browser, names: string[], to: Location, toWritable: boolean, gesture: string | null): Promise<boolean> {
  const payload = payloadFor(from, names)
  return payload ? transferPayload(op, payload, from.root()?.rights ?? "read", to, toWritable, gesture) : false
}

export function copySelection(b: Browser, op: "copy" | "move") {
  const payload = payloadFor(b)
  if (payload && payload.items.length > 0) setClip({ op, payload, rights: b.root()?.rights ?? "read" })
}

export async function paste(into: Browser, gesture: string | null) {
  const c = clip()
  const to = into.location()
  if (!c || !to) return false
  const ok = await transferPayload(c.op, c.payload, c.rights, to, into.root()?.rights === "read_write", gesture)
  if (ok && c.op === "move") setClip(null)
  return ok
}

export async function trash(b: Browser, gesture: string | null) {
  const loc = b.location()
  const names = b.selection()
  if (!loc || names.length === 0) return false
  const r = await ops.trash({ conn: loc.conn, root: loc.root, paths: names.map((n) => join(loc.path, n)) }, gesture)
  if (!r.ok) return fail(r.error)
  trackJob(newJob({ id: r.value.job, op: "trash", subject: r.value.subject, destination: r.value.destination, crossHost: false, at: Date.now() }))
  b.select(null)
  return true
}

export async function newFolder(b: Browser, name: string, gesture: string | null) {
  const loc = b.location()
  if (!loc || !name.trim()) return false
  const r = await ops.mkdir(loc, name.trim(), gesture)
  if (!r.ok) return fail(r.error)
  b.select(r.value.entry.name)
  return true
}

export async function rename(b: Browser, from: string, to: string, gesture: string | null) {
  const loc = b.location()
  if (!loc || !to.trim() || to === from) return false
  const r = await ops.rename({ ...loc, path: join(loc.path, from) }, to.trim(), gesture)
  if (!r.ok) return fail(r.error)
  b.select(r.value.entry.name)
  return true
}

/** Keyboard and menu alternative to dragging onto the focused terminal: the shell resolves or copies (finder.md 7.2). */
export async function sendToTerminal(b: Browser, gesture: string | null) {
  const p = payloadFor(b)
  if (!p || p.items.length === 0) return false
  const r = await ops.dropOnTerminal(p.items, gesture)
  return r.ok ? true : fail(r.error)
}

export async function sendToAgent(b: Browser, gesture: string | null) {
  const p = payloadFor(b)
  if (!p || p.items.length === 0) return false
  const r = await ops.attachToAgent(p.items, gesture)
  return r.ok ? true : fail(r.error)
}

export async function cancelJob(id: string) {
  dispatchJob(id, { type: "requestCancel" })
  const r = await ops.cancelJob(id)
  if (!r.ok) dispatchJob(id, { type: "requestFailed", error: r.error })
}

export async function resolveConflict(id: string, choice: ConflictChoice, applyToAll: boolean, gesture: string | null) {
  dispatchJob(id, { type: "requestResolve" })
  const r = await ops.resolveJob(id, choice, applyToAll, gesture)
  if (!r.ok) dispatchJob(id, { type: "requestFailed", error: r.error })
}

export async function undoJob(undo: string, gesture: string | null) {
  const r = await ops.undo(undo, gesture)
  return r.ok ? true : fail(r.error)
}
