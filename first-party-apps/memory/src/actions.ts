// Every write is shown as a diff first. The app reads the document again,
// applies the intent, shows before/after, and Apply sends document.edit with
// the base revision from a tap (origin user). A stale revision (an agent wrote
// the file meanwhile) reads again and applies the same intent once more.
// Delete moves the whole file to the trash through fs.trash (origin user).

import { applyIntent, type Intent, toEdits } from "./model/edits.ts"
import type { FileRef } from "./model/review.ts"
import { t } from "./l10n.ts"
import { call } from "./ops.ts"
import { gesture, withGesture } from "./runtime.ts"
import { allFiles, dispatchReview, loadFiles, open, readDoc, rememberText, review, select, selected } from "./store.ts"

/** The open document when it is this file and unchanged (Save still checks its revision), else a fresh read. */
async function current(file: FileRef, fresh: boolean) {
  const doc = open()
  if (!fresh && doc && doc.root === file.root && doc.path === file.path && !doc.changed) return { ok: true as const, doc }
  return readDoc(file.root, file.path)
}

async function prepare(file: FileRef, intent: Intent, fresh = false): Promise<void> {
  const r = await current(file, fresh)
  if (!r.ok) return dispatchReview({ type: "error", code: r.error.code, message: r.error.message })
  if (fresh) rememberText(file.root, file.path, r.doc.text, r.doc.revision)
  const next = applyIntent(r.doc.text, intent)
  if (!next.ok) return dispatchReview(next.reason === "gone" ? { type: "gone" } : { type: "error", code: "memory.empty", message: "" })
  dispatchReview({ type: "prepared", prepared: { doc: r.doc.doc, revision: r.doc.revision, before: r.doc.text, after: next.text } })
}

export function propose(file: FileRef, intent: Intent, title: string): Promise<void> {
  dispatchReview({ type: "ask", file, intent, title })
  return prepare(file, intent)
}

export const appendTo = (file: FileRef, text: string, section: string | null = null) =>
  text.trim() ? propose(file, { op: "append", text, section }, t("intent.append", "Add a line to {file}", { file: file.label })) : Promise.resolve()

export const removeEntry = (file: FileRef, entry: string) => propose(file, { op: "remove", entry }, t("intent.remove", "Delete a line from {file}", { file: file.label }))

export const replaceEntry = (file: FileRef, entry: string, text: string) => propose(file, { op: "replace", entry, text }, t("intent.replace", "Change a line in {file}", { file: file.label }))

export const trashFile = (file: FileRef) => propose(file, { op: "trash" }, t("intent.trash", "Move {file} to the Trash", { file: file.label }))

export async function apply(): Promise<void> {
  const s = review()
  if (s.phase !== "review") return
  const token = gesture()
  dispatchReview({ type: "apply" })
  if (s.intent.op === "trash") {
    const r = await call<unknown>("fs.trash", { root: s.file.root, paths: [s.file.path], expected_revisions: { [s.file.path]: s.revision } }, withGesture(token))
    if (r.ok) {
      dispatchReview({ type: "applied" })
      await loadFiles(s.file.root)
      const sel = selected()
      const next = allFiles()[0]
      if (sel && sel.root === s.file.root && sel.path === s.file.path && next) await select(next.root, next.path)
    } else if (r.error.code === "document.stale") await rebase()
    else dispatchReview({ type: "error", code: r.error.code, message: r.error.message })
    return
  }
  const r = await call<{ revision: string }>("document.edit", { doc: s.doc, base_revision: s.revision, edits: toEdits(s.before, s.after) }, withGesture(token))
  if (r.ok) {
    dispatchReview({ type: "applied" })
    rememberText(s.file.root, s.file.path, s.after, r.value.revision)
    return
  }
  if (r.error.code === "document.stale") await rebase()
  else dispatchReview({ type: "error", code: r.error.code, message: r.error.message })
}

async function rebase() {
  dispatchReview({ type: "stale" })
  const s = review()
  if (s.phase === "preparing") await prepare(s.file, s.intent, true)
}

export function cancel() {
  const s = review()
  if (s.phase !== "applying") dispatchReview({ type: "cancel" })
}

/** Shows the pending edit in the user's diff renderer: the document host turns it into a diff resource. */
export async function openInDiffs(): Promise<string | null> {
  const s = review()
  if (s.phase !== "review" || s.intent.op === "trash") return null
  const token = gesture()
  const d = await call<{ diff: string }>("document.propose", { doc: s.doc, base_revision: s.revision, edits: toEdits(s.before, s.after) }, withGesture(token))
  if (!d.ok) return d.error.missing ? t("diffs.missing", "Opening in Diffs needs document.propose and ui.open, which this cmux does not have yet") : d.error.message
  const o = await call<unknown>("ui.open", { interface: "cmux.diff.renderer/1", props: { diff: d.value.diff, layout: "unified" } }, withGesture(token))
  return o.ok ? null : o.error.message
}

export function openPane(token: string | null = gesture()) {
  return call<unknown>("app.pane.open", { kind: "memoryHub" }, withGesture(token))
}
