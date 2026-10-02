/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// "scratchpad": the current workspace's scratchpad first (always open, one
// field to add a line), then every other note with search.

import { t } from "../l10n.ts"
import { appendTo, messageOf, scratchpadOf } from "../store.ts"
import { freshField, newNoteHere, noteBody, searchField } from "./common.ts"
import { moreButton, noteById, notesList } from "./list.ts"
import type { ViewState } from "./state.ts"

export function renderScratchpad(vs: ViewState) {
  const workspaceId = computed(() => vs.ws.current()?.id ?? null)
  const padId = computed(() => {
    const ws = workspaceId()
    return ws ? (scratchpadOf(ws)?.id ?? null) : null
  })
  const placeholder = t("scratchpad.placeholder")
  // The server creates the workspace's scratchpad on its first append (one per workspace).
  const append = (text: string) => {
    const ws = vs.ws.current()
    return ws ? appendTo({ workspace: ws.id }, text).catch((e: unknown) => cmux.log("notes: append failed", messageOf(e))) : undefined
  }
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon("square.and.pencil").font("caption").secondary().help(t("scratchpad.title")),
      Text(() => vs.ws.current()?.name ?? t("scratchpad.none"))
        .font("caption")
        .weight("semibold")
        .secondary()
        .lineLimit(1),
      Spacer()
    ]),
    () => {
      if (!workspaceId()) return null
      const id = padId()
      if (id) return noteBody(noteById(() => id), vs, { appendPlaceholder: placeholder, append })
      return freshField(placeholder, append)
    },
    Divider().padding({ top: 4, leading: 0, bottom: 4, trailing: 0 }),
    HStack({ spacing: 6 }, [searchField(vs).layoutPriority(1), Button(Icon("plus").secondary(), () => newNoteHere(vs)).help(t("action.new")), moreButton(vs)]),
    notesList(vs, { exclude: padId, inlineDetail: true, showWorkspace: true, quietWhenEmpty: true })
  ])
}
