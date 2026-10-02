// "scratchpad": the current workspace's scratchpad first (always open, one
// field to add a line), then every other note with search.

import { t } from "../l10n.ts"
import { scratchpadOf } from "../model.ts"
import { commit, newNoteId, notes } from "../store.ts"
import { freshField, newNoteHere, noteBody, searchField } from "./common.ts"
import { notesList } from "./list.ts"
import type { ViewState } from "./state.ts"

/** Appends to the workspace's scratchpad, creating it on first use (one write path for the UI and commands). */
export async function appendToScratchpad(workspace: { id: string; name: string }, text: string, stamp: { now: number; via: "ui" | "command"; actor?: string }) {
  const pad = await commit({ kind: "create", id: newNoteId(), workspace, scratchpad: true }, stamp)
  return commit({ kind: "append", id: pad!.id, text }, stamp)
}

export function renderScratchpad(vs: ViewState) {
  const workspaceId = computed(() => vs.ws.current()?.id ?? null)
  const padId = computed(() => {
    const ws = workspaceId()
    return ws ? (scratchpadOf(notes(), ws)?.id ?? null) : null
  })
  const placeholder = t("scratchpad.placeholder", "Note for this workspace")
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon("square.and.pencil").font("caption").secondary().help(t("scratchpad.title", "Scratchpad")),
      Text(() => vs.ws.current()?.name ?? t("scratchpad.none", "No workspace selected"))
        .font("caption")
        .weight("semibold")
        .secondary()
        .lineLimit(1),
      Spacer()
    ]),
    () => {
      const ws = workspaceId()
      if (!ws) return null
      const id = padId()
      if (id) return noteBody(() => id, vs, { appendPlaceholder: placeholder })
      return freshField(placeholder, (text) => {
        const current = vs.ws.current()
        if (current) return appendToScratchpad(current, text, { now: Date.now(), via: "ui" }).catch((e) => cmux.log("notes: save failed", String(e)))
      })
    },
    Divider().padding({ top: 4, leading: 0, bottom: 4, trailing: 0 }),
    HStack({ spacing: 6 }, [
      searchField(vs).layoutPriority(1),
      Button(Icon("plus").secondary(), () => newNoteHere(vs)).help(t("action.new", "New Note"))
    ]),
    notesList(vs, { exclude: padId, inlineDetail: true, showWorkspace: true, quietWhenEmpty: true })
  ])
}
