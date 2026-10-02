/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Notes: plain-text and markdown notes inside cmux. Global notes, a
// scratchpad per workspace, quick capture, pin, search, and the same
// commands as MCP tools so agents can keep notes for you.

import * as commands from "./commands.ts"
import { detectLanguage, setLanguage } from "./l10n.ts"
import { variant } from "./settings.ts"
import { ensureLoaded, loadError } from "./store.ts"
import { statusRow } from "./views/common.ts"
import { listHeader, notesList } from "./views/list.ts"
import { renderScratchpad } from "./views/scratchpad.ts"
import { renderSplit } from "./views/split.ts"
import { createViewState } from "./views/state.ts"

function prepare(ctx: Record<string, unknown>) {
  setLanguage(detectLanguage(ctx))
  ensureLoaded().catch(() => undefined) // the status row shows the error
  return createViewState(ctx)
}

/** Sidebar section. The `variant` setting picks the design (DEV/NIGHTLY). */
export function renderNotes(ctx: Record<string, unknown> = {}) {
  const vs = prepare(ctx)
  const failed = computed(() => loadError() !== null)
  return VStack({ spacing: 6 }, [
    statusRow(),
    () => {
      if (failed()) return null // the status row explains; editing would write over notes we could not read
      switch (variant()) {
        case "list":
          return VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: true, showWorkspace: true })])
        case "split":
          return renderSplit(vs, { wide: false })
        default:
          return renderScratchpad(vs)
      }
    }
  ])
}

/** Pane kind: list and editor side by side (the platform does not mount pane kinds yet). */
export function renderNotesPane(ctx: Record<string, unknown> = {}) {
  const vs = prepare(ctx)
  return VStack({ spacing: 0 }, [statusRow(), renderSplit(vs, { wide: true })])
}

export const list = commands.list
export const read = commands.read
export const create = commands.create
export const capture = commands.capture
export const append = commands.append
export const pin = commands.pin
export const search = commands.search
export const exportNotes = commands.exportNotes
export const newNote = commands.newNote
export const open = commands.open
export const cycleVariant = commands.cycleVariant
