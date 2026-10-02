// Building blocks shared by every variant: note rows, the line-based body
// view with markdown-lite styling, the append field, search and status rows.

import { t } from "../l10n.ts"
import { parseLines, inlineText, type Line } from "../markdown.ts"
import { previewOf, titleOf, type Note, type NoteOp } from "../model.ts"
import { bodyLines, MAX_RENDERED_LINES } from "../settings.ts"
import { commit, findNote, loadError, newNoteId, ready, saveError } from "../store.ts"
import type { ViewState } from "./state.ts"

/** A write from the app's own UI (a tap or submit in this client). */
export function edit(op: NoteOp): Promise<Note | null> {
  return commit(op, { now: Date.now(), via: "ui" }).catch((e) => {
    cmux.log("notes: save failed", e instanceof Error ? e.message : String(e))
    return null
  })
}

/** A scratchpad is named after its workspace (live name, else the stored one). */
export const displayTitle = (n: Note, vs?: ViewState) =>
  n.title.trim() || (n.scratchpad && n.workspace ? (vs?.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name })) : titleOf(n) || t("note.untitled", "Untitled"))

const isAgentEdit = (n: Note) => n.lastEdit.via === "command" && (n.lastEdit.actor ?? "").startsWith("agent:")

export function symbolOf(n: Note): string {
  if (n.pinned) return "pin.fill"
  if (isAgentEdit(n)) return "sparkles"
  if (n.scratchpad) return "square.and.pencil"
  return n.body.includes("- [ ]") ? "checklist" : "note.text"
}

export function subtitleOf(n: Note, vs: ViewState, showWorkspace: boolean): string {
  const preview = previewOf(n, 80, !n.scratchpad) // a scratchpad shows "Scratchpad" as its title, so its first line is preview
  const place = showWorkspace && n.workspace && !n.scratchpad ? (vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name })) : ""
  if (place && preview) return `${place} · ${preview}`
  return place || preview || t("note.empty", "Empty note")
}

/** Right-click menu of a note. Rebuilt when the note or the current workspace changes. */
export function noteMenu(n: Note, vs: ViewState) {
  const here = vs.ws.current()
  const items = [Button(n.pinned ? t("action.unpin", "Unpin") : t("action.pin", "Pin"), () => edit({ kind: "setPinned", id: n.id, pinned: !n.pinned }))]
  if (n.workspace) items.push(Button(t("action.detach", "Detach from Workspace"), () => edit({ kind: "setWorkspace", id: n.id, workspace: null })))
  else if (here) items.push(Button(t("action.attach", "Attach to This Workspace"), () => edit({ kind: "setWorkspace", id: n.id, workspace: here })))
  items.push(Divider(), Button(t("action.delete", "Delete"), () => edit({ kind: "delete", id: n.id })).destructive())
  return items
}

export function noteRow(item: () => Note, vs: ViewState, opts: { showWorkspace: boolean }) {
  return Row({
    title: () => displayTitle(item(), vs),
    subtitle: () => subtitleOf(item(), vs, opts.showWorkspace),
    symbol: () => symbolOf(item()),
    tint: () => (item().pinned ? "accent" : "secondary"),
    selected: () => vs.selected() === item().id
  })
    .onTap(() => vs.toggle(item().id))
    .contextMenu(() => noteMenu(item(), vs))
}

/**
 * A text field that starts empty again after each submit. The renderer keeps
 * the typed text when the `text` prop does not change, so the field is
 * rebuilt instead (README gap: TextField has no clear-on-submit).
 */
export function freshField(placeholder: string, onSubmit: (text: string) => unknown, opts: { autofocus?: boolean } = {}) {
  const [generation, setGeneration] = signal(0)
  return Group([
    () => {
      generation()
      return TextField("", {
        placeholder,
        autofocus: opts.autofocus ?? false,
        onSubmit: (text) => {
          if (!text.trim()) return
          setGeneration((g) => g + 1)
          return onSubmit(text)
        }
      })
        .font("callout")
        .padding({ top: 4, leading: 8, bottom: 4, trailing: 8 })
        .background("hover")
        .cornerRadius(6)
    }
  ])
}

export function searchField(vs: ViewState) {
  return Group([
    () => {
      vs.searchGeneration()
      return HStack({ spacing: 6 }, [
        Icon("magnifyingglass").font("caption").secondary(),
        TextField("", { placeholder: t("search.placeholder", "Search notes"), onEdit: (q) => vs.setQuery(q), onCancel: () => vs.clearSearch() }).font("callout")
      ])
        .padding({ top: 4, leading: 8, bottom: 4, trailing: 8 })
        .background("hover")
        .cornerRadius(6)
    }
  ])
}

function lineDisplay(line: () => Line, kind: Line["kind"], noteId: () => string) {
  const text = () => inlineText(line().text)
  const indent = () => line().level * 12
  switch (kind) {
    case "heading":
      return Text(text).font(() => (line().level <= 1 ? "title3" : line().level === 2 ? "headline" : "subheadline")).weight("semibold").lineLimit(2)
    case "check":
      return HStack({ spacing: 6 }, [
        Icon(() => (line().checked ? "checkmark.square.fill" : "square")).font("callout").color(() => (line().checked ? "success" : "secondary")),
        Text(text).font("callout").color(() => (line().checked ? "secondary" : "primary"))
      ])
        .padding(() => ({ top: 0, leading: indent(), bottom: 0, trailing: 0 }))
        .cursor("pointer")
        .onTap(() => edit({ kind: "toggleCheck", id: noteId(), index: line().index }))
    case "bullet":
    case "number":
      return HStack({ spacing: 6 }, [Text(() => (kind === "number" ? line().marker : "•")).font("callout").secondary(), Text(text).font("callout")]).padding(() => ({ top: 0, leading: indent(), bottom: 0, trailing: 0 }))
    case "quote":
      // A fixed-height bar: an unbounded Rectangle in an HStack grows to fill the whole column.
      return HStack({ spacing: 6 }, [Rectangle({ fill: "separator" }).frame({ width: 2, height: 16 }), Text(text).font("callout").italic().secondary()])
    case "code":
      return Text(() => line().text || " ").font("caption").monospaced().padding({ top: 0, leading: 8, bottom: 0, trailing: 4 }).frame({ maxWidth: "infinity" }).background("hover")
    case "fence":
      return Group([() => (line().text ? Text(() => line().text).font("caption2").monospaced().secondary() : Rectangle({ fill: "hover" }).frame({ height: 3, maxWidth: "infinity" }))])
    case "rule":
      return Divider()
    case "blank":
      return Spacer().frame({ height: 4 })
    default:
      return Text(text).font("callout")
  }
}

function lineView(line: () => Line, noteId: () => string, vs: ViewState) {
  // Rebuild only when the line's kind or its editing state flips; text changes are live props.
  const kind = computed(() => line().kind)
  const editing = computed(() => {
    const e = vs.editingLine()
    return !!e && e.id === noteId() && e.index === line().index
  })
  const raw = () => findNote(noteId())?.body.split("\n")[line().index] ?? ""
  return Group([
    () =>
      editing()
        ? TextField(raw(), {
            placeholder: t("line.placeholder", "Edit line"),
            autofocus: true,
            onSubmit: (text) => {
              vs.setEditingLine(null)
              return edit({ kind: "replaceLine", id: noteId(), index: line().index, text })
            },
            onCancel: () => vs.setEditingLine(null)
          }).font("callout")
        : lineDisplay(line, kind(), noteId).contextMenu(() => [
            Button(t("action.editLine", "Edit Line"), () => vs.setEditingLine({ id: noteId(), index: line().index })),
            Button(t("action.deleteLine", "Delete Line"), () => edit({ kind: "deleteLine", id: noteId(), index: line().index })).destructive()
          ])
  ])
}

/** The body of one note, line by line, followed by the append field. */
export function noteBody(noteId: () => string, vs: ViewState, opts: { appendPlaceholder?: string; maxLines?: () => number } = {}) {
  const lines = computed(() => parseLines(findNote(noteId())?.body ?? ""))
  const limit = () => (vs.isExpanded(noteId()) ? MAX_RENDERED_LINES : (opts.maxLines ?? bodyLines)())
  const shown = computed(() => lines().slice(0, limit()))
  const hidden = computed(() => Math.max(0, lines().length - shown().length))
  // A string, so the footer is rebuilt only when it changes kind (the count is a live title).
  const more = computed(() => {
    const expanded = vs.isExpanded(noteId())
    if (hidden() > 0) return expanded ? "capped" : "more"
    return expanded && lines().length > (opts.maxLines ?? bodyLines)() ? "less" : "none"
  })
  return VStack({ spacing: 3 }, [
    ForEach({ items: shown, key: (l) => l.index }, (line) => lineView(line, noteId, vs)),
    () => {
      const state = more()
      if (state === "more") return Button(() => t("action.showMore", "Show {n} more lines", { n: hidden() }), () => vs.setExpanded(noteId(), true)).font("caption")
      if (state === "capped") return Text(t("limit.lines", "Long note: showing the first {n} lines.", { n: MAX_RENDERED_LINES })).font("caption").secondary()
      if (state === "less") return Button(t("action.showLess", "Show Less"), () => vs.setExpanded(noteId(), false)).font("caption")
      return null
    },
    freshField(opts.appendPlaceholder ?? t("append.placeholder", "Add a line"), (text) => edit({ kind: "append", id: noteId(), text }))
  ])
}

/** Load and save errors as a row; null when all is well. */
export function statusRow() {
  return () => {
    const failed = loadError()
    if (failed) return EmptyState({ title: t("error.load", "Cannot load notes"), message: failed, symbol: "exclamationmark.triangle" })
    const unsaved = saveError()
    if (unsaved) return Row({ title: t("error.save", "Cannot save notes"), subtitle: unsaved, symbol: "exclamationmark.triangle", tint: "warning" })
    return null
  }
}

/** Creates an empty note and selects it in this surface (user action). */
export async function newNoteHere(vs: ViewState, workspace: Note["workspace"] = null) {
  const id = newNoteId()
  const note = await edit({ kind: "create", id, workspace })
  if (note) {
    vs.clearSearch()
    vs.select(note.id)
  }
}

export const isReady = ready
