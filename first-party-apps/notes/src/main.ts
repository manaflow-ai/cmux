/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Notes: markdown notes inside cmux. Notes are documents owned by the notes
// server (catalog fragment `note.*`, owner app:cmux/notes); the text is
// edited in the native editor pane. This app renders the sidebar section
// (scene trees), runs export and import through user-picked handles, and, on
// today's runtime, forwards the agent tools to the server's ops.

import * as commands from "./commands.ts"
import { variant } from "./settings.ts"
import { attach, loadError } from "./store.ts"
import { statusRow } from "./views/common.ts"
import { renderEditorList } from "./views/editor.ts"
import { listHeader, notesList } from "./views/list.ts"
import { renderScratchpad } from "./views/scratchpad.ts"
import { createViewState } from "./views/state.ts"

/** Sidebar section. The `variant` setting picks the design (DEV/NIGHTLY). */
export function renderNotes(ctx: Record<string, unknown> = {}) {
  attach()
  const vs = createViewState(ctx)
  const failed = computed(() => loadError() !== null)
  return VStack({ spacing: 6 }, [
    statusRow(),
    () => {
      if (failed()) return null // the status row explains
      switch (variant()) {
        case "list":
          return VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: true, showWorkspace: true })])
        case "editor":
          return renderEditorList(vs)
        default:
          return renderScratchpad(vs)
      }
    }
  ])
}

export const list = commands.list
export const read = commands.read
export const create = commands.create
export const capture = commands.capture
export const append = commands.append
export const search = commands.search
export const exportNotes = commands.exportNotes
export const importNotes = commands.importNotes
export const newNote = commands.newNote
export const open = commands.open
export const cycleVariant = commands.cycleVariant
