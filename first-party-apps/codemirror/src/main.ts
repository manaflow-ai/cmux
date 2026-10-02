/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Editor app commands (identical in first-party-apps/{monaco,codemirror}/src/main.ts).
// The editor itself is the web pane (web/index.html, built from web-src/). These
// exports serve the palette, CLI and MCP: with a `doc` handle they act on the
// document owner directly; without one they go to the focused editor pane
// through the proposed `app.pane.command` (the pane runs them over the bridge).

import type { DocumentOpenResult } from "./interfaces/document.ts"
import { EDITOR_INTERFACE } from "./interfaces/editor.ts"
import { normalizeVariant, EDITOR_VARIANTS } from "./shared/chrome.ts"

type CmuxErrorConstructor = new (code: string, message: string) => CmuxError
/** A thrown CmuxError reaches CLI and MCP callers as {code, message} (the typings lack its constructor). */
const invalid = (message: string): CmuxError => new (CmuxError as unknown as CmuxErrorConstructor)("invalid_params", message)

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined)

/** Runs a pane command in the focused pane of this app's `editor` kind. */
const paneCommand = (command: string, args: Record<string, unknown> = {}) => cmux.call("app.pane.command", { kind: "editor", command, args })

/** Open a file or document in an editor pane of this app. */
export async function open(args: { uri?: string; doc?: string } = {}) {
  const uri = str(args.uri)
  let doc = str(args.doc)
  if (!uri && !doc) throw invalid("give uri or doc")
  if (!doc) doc = (await cmux.call<DocumentOpenResult>("document.open", { uri })).info.doc
  await cmux.call("app.pane.open", { kind: "editor", props: { doc }, interface: EDITOR_INTERFACE })
  return { doc }
}

/** Save: a given document through its owner, else the focused editor pane. */
export async function save(args: { doc?: string } = {}) {
  const doc = str(args.doc)
  if (!doc) return paneCommand("save")
  const opened = await cmux.call<DocumentOpenResult>("document.open", { doc })
  if (!opened.info.dirty) return { doc, saved: false, reason: "clean" }
  await cmux.call("document.save", { doc, revision: opened.info.revision })
  return { doc, saved: true }
}

export async function revert(args: { doc?: string } = {}) {
  const doc = str(args.doc)
  if (!doc) return paneCommand("revert")
  await cmux.call("document.revert", { doc })
  return { doc, reverted: true }
}

export async function toggleReadOnly() {
  return paneCommand("toggleReadOnly")
}

/** DEV/NIGHTLY: next pane design. Persists through the proposed `app.settings.set`; the host pushes settings to open panes. */
export async function cycleVariant() {
  const current = normalizeVariant(cmux.app.settings().variant)
  const next = EDITOR_VARIANTS[(EDITOR_VARIANTS.indexOf(current) + 1) % EDITOR_VARIANTS.length]!
  try {
    await cmux.call("app.settings.set", { key: "variant", value: next })
    return { variant: next, persisted: true }
  } catch {
    return { variant: next, persisted: false }
  }
}
