// "split": list and editor. Wide (a pane) shows two columns; narrow (a
// sidebar section) shows the list, and the editor in its place after a tap.

import { t } from "../l10n.ts"
import { age, deriveTitle, type Note } from "../model.ts"
import { findNote } from "../store.ts"
import { edit, noteBody, noteMenu } from "./common.ts"
import { listHeader, noteById, notesList } from "./list.ts"
import type { ViewState } from "./state.ts"

function ageText(n: Note): string {
  const a = age(n.updatedAt, Date.now())
  if (a.unit === "now") return t("time.now", "now")
  if (a.unit === "minutes") return t("time.minutes", "{n}m", { n: a.n })
  if (a.unit === "hours") return t("time.hours", "{n}h", { n: a.n })
  return t("time.days", "{n}d", { n: a.n })
}

function metaLine(n: Note, vs: ViewState): string {
  const parts: string[] = []
  if (n.workspace) parts.push(vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name }))
  parts.push(ageText(n))
  if (n.lastEdit.via === "command" && (n.lastEdit.actor ?? "").startsWith("agent:")) parts.push(t("edited.agent", "Edited by an agent"))
  return parts.join(" · ")
}

export function editor(id: () => string, vs: ViewState, opts: { back: boolean }) {
  const note = noteById(id)
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      opts.back ? Button(Icon("chevron.left").secondary(), () => vs.select(null)).help(t("action.back", "Back")) : null,
      TextField(() => note().title, {
        placeholder: deriveTitle(note().body) || t("title.placeholder", "Title"),
        onSubmit: (title) => edit({ kind: "setTitle", id: id(), title })
      })
        .font("headline")
        .layoutPriority(1),
      Button(Icon(() => (note().pinned ? "pin.fill" : "pin")).color(() => (note().pinned ? "accent" : "secondary")), () => edit({ kind: "setPinned", id: id(), pinned: !note().pinned })).help(
        () => (note().pinned ? t("action.unpin", "Unpin") : t("action.pin", "Pin"))
      )
    ]).contextMenu(() => noteMenu(note(), vs)),
    Text(() => metaLine(note(), vs)).font("caption").secondary().lineLimit(1),
    Divider(),
    noteBody(id, vs, { maxLines: () => 200 })
  ])
}

export function renderSplit(vs: ViewState, opts: { wide: boolean }) {
  const selectedId = computed(() => {
    const id = vs.selected()
    return id && findNote(id) ? id : null
  })
  const list = VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: false, showWorkspace: true })])
  if (opts.wide) {
    return HStack({ spacing: 0 }, [
      VStack({ spacing: 0 }, [list, Spacer()]).frame({ width: 240, maxHeight: "infinity" }).padding(8),
      Divider(),
      VStack({ spacing: 0 }, [
        () => {
          const id = selectedId()
          return id ? editor(() => id, vs, { back: false }) : EmptyState({ title: t("empty.select", "Select a note"), symbol: "note.text" })
        },
        Spacer()
      ])
        .padding(12)
        .frame({ maxWidth: "infinity", maxHeight: "infinity" })
    ])
  }
  return Group([
    () => {
      const id = selectedId()
      return id ? editor(() => id, vs, { back: true }) : list
    }
  ])
}
