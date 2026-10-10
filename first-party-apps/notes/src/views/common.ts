/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Building blocks shared by every variant: note rows and menus, the inline
// read view of a body (markdown-lite, checkboxes you can tap), the append
// field, search, status and notices. Editing a note's text happens in the
// native editor pane, which this app opens with the note's document handle.

import { CANCELLED, exportNotes, importNotes } from "../files.ts"
import { t } from "../l10n.ts"
import { inlineText, parseLines, type Line } from "../markdown.ts"
import type { NoteSummary } from "../notes.ts"
import { bodyLines, MAX_RENDERED_LINES } from "../settings.ts"
import { appendTo, bodyOf, codeOf, createNote, deleteNote, loadError, messageOf, saveError, toggleCheck, updateNote } from "../store.ts"
import { notice, noticeFor, type ViewState } from "./state.ts"

const logged = (p: Promise<unknown>) => p.catch((e: unknown) => cmux.log("notes: write failed", messageOf(e)))

/** A scratchpad is named after its workspace (live name, else the stored one). */
export const displayTitle = (n: NoteSummary, vs?: ViewState) =>
  n.title_explicit && n.title
    ? n.title
    : n.scratchpad && n.workspace
      ? (vs?.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", { name: n.workspace.name }))
      : n.title || t("note.untitled")

export const byAgent = (n: NoteSummary) => n.last_edit.actor_kind === "agent"

export function symbolOf(n: NoteSummary): string {
  if (n.pinned) return "pin.fill"
  if (byAgent(n)) return "sparkles"
  return n.scratchpad ? "square.and.pencil" : "note.text"
}

export function subtitleOf(n: NoteSummary, vs: ViewState, showWorkspace: boolean): string {
  const place = showWorkspace && n.workspace && !n.scratchpad ? (vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", { name: n.workspace.name })) : ""
  if (place && n.preview) return `${place} · ${n.preview}`
  return place || n.preview || t("note.empty")
}

/**
 * Opens the note in the native editor pane (proposed `app.pane.open` with the
 * note's document handle). It moves focus, so it runs synchronously in the
 * tap and presents the tap's gesture token.
 */
export function openInEditor(n: NoteSummary): Promise<unknown> {
  return cmux.call("app.pane.open", { contribution: `${cmux.app.id}#editor`, input: { doc: n.doc }, placement: "right" }).catch((e: unknown) => {
    noticeFor(codeOf(e) === "operation.unsupported" ? t("editor.unsupported") : t("error.generic", { reason: messageOf(e) }))
  })
}

/** Export and import run from a tap: the system panel needs the tap's gesture token. */
export function runExport(ids: string[] | null): Promise<unknown> {
  const gesture = cmux.gesture()
  return exportNotes(ids, gesture).then(
    (r) => noticeFor(t("export.done", { n: r.files.length, folder: r.folder })),
    (e: unknown) => (codeOf(e) === CANCELLED ? undefined : noticeFor(t("export.failed", { reason: fsReason(e) })))
  )
}

export function runImport(): Promise<unknown> {
  const gesture = cmux.gesture()
  return importNotes(gesture).then(
    (r) => noticeFor(r.skipped.length ? t("import.doneSkipped", { n: r.imported.length, skipped: r.skipped.length }) : t("import.done", { n: r.imported.length })),
    (e: unknown) => (codeOf(e) === CANCELLED ? undefined : noticeFor(t("import.failed", { reason: fsReason(e) })))
  )
}

const fsReason = (e: unknown) => (codeOf(e) === "operation.unsupported" ? t("files.unsupported") : messageOf(e))

/** Right-click menu of a note. */
export function noteMenu(n: NoteSummary, vs: ViewState): CmuxView[] {
  const here = vs.ws.current()
  const items = [
    Button(t("action.openEditor"), () => openInEditor(n)),
    Button(n.pinned ? t("action.unpin") : t("action.pin"), () => logged(updateNote(n.id, { pinned: !n.pinned })))
  ]
  if (n.workspace) items.push(Button(t("action.detach"), () => logged(updateNote(n.id, { workspace: null }))))
  else if (here) items.push(Button(t("action.attach"), () => logged(updateNote(n.id, { workspace: here.id }))))
  items.push(Button(t("action.exportOne"), () => runExport([n.id])))
  items.push(Divider(), Button(t("action.delete"), () => logged(deleteNote(n.id))).destructive())
  return items
}

/** The section's own menu: new note, import, export everything. */
export function sectionMenu(vs: ViewState): CmuxView[] {
  return [Button(t("action.new"), () => newNoteHere(vs)), Divider(), Button(t("action.importFiles"), () => runImport()), Button(t("action.exportAll"), () => runExport(null))]
}

export function noteRow(item: () => NoteSummary, vs: ViewState, opts: { showWorkspace: boolean; onTap?: (n: NoteSummary) => unknown }) {
  return Row({
    title: () => displayTitle(item(), vs),
    subtitle: () => subtitleOf(item(), vs, opts.showWorkspace),
    symbol: () => symbolOf(item()),
    tint: () => (item().pinned ? "accent" : "secondary"),
    selected: () => vs.selected() === item().id
  })
    .onTap(() => (opts.onTap ? opts.onTap(item()) : vs.toggle(item().id)))
    .contextMenu(() => noteMenu(item(), vs))
}

/**
 * A text field that starts empty again after each submit. The renderer keeps
 * the typed text when the `text` prop does not change, so the field is
 * rebuilt instead (README gap: TextField has no clear-on-submit).
 */
export function freshField(placeholder: string, onSubmit: (text: string) => unknown) {
  const [generation, setGeneration] = signal(0)
  return Group([
    () => {
      generation()
      return TextField("", {
        placeholder,
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
        TextField("", { placeholder: t("search.placeholder"), onEdit: (q) => vs.setQuery(q), onCancel: () => vs.clearSearch() }).font("callout")
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
        .onTap(() => toggleCheck(noteId(), line().index).then((ok) => (ok ? undefined : noticeFor(t("check.stale")))))
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

/** The body of one note, read-only line by line (checkboxes toggle), then the append field. */
export function noteBody(note: () => NoteSummary, vs: ViewState, opts: { appendPlaceholder?: string; append?: (text: string) => unknown } = {}) {
  const id = () => note().id
  const lines = computed(() => parseLines(bodyOf(id()) ?? ""))
  const limit = () => (vs.isExpanded(id()) ? MAX_RENDERED_LINES : bodyLines())
  const shown = computed(() => lines().slice(0, limit()))
  const hidden = computed(() => Math.max(0, lines().length - shown().length))
  // A string, so the footer is rebuilt only when it changes kind (the count is a live title).
  const more = computed(() => {
    const expanded = vs.isExpanded(id())
    if (hidden() > 0) return expanded ? "capped" : "more"
    return expanded && lines().length > bodyLines() ? "less" : "none"
  })
  return VStack({ spacing: 3 }, [
    ForEach({ items: shown, key: (l) => l.index }, (line) => {
      // Rebuilt only when the line's kind changes; text changes are live props.
      const kind = computed(() => line().kind)
      return Group([() => lineDisplay(line, kind(), id)])
    }),
    () => {
      const state = more()
      if (state === "more") return Button(() => t("action.showMore", { n: hidden() }), () => vs.setExpanded(id(), true)).font("caption")
      if (state === "capped") return Text(t("limit.lines", { n: MAX_RENDERED_LINES })).font("caption").secondary()
      if (state === "less") return Button(t("action.showLess"), () => vs.setExpanded(id(), false)).font("caption")
      return null
    },
    HStack({ spacing: 6 }, [
      freshField(opts.appendPlaceholder ?? t("append.placeholder"), (text) => (opts.append ? opts.append(text) : logged(appendTo({ note: id() }, text)))).layoutPriority(1),
      Button(Icon("square.and.pencil").secondary(), () => openInEditor(note())).help(t("action.openEditor"))
    ])
  ])
}

/** Load and save errors and transient notices; null when all is well. */
export function statusRow() {
  return () => {
    const failed = loadError()
    if (failed) {
      if (failed.code === "operation.unsupported") return EmptyState({ title: t("server.unavailable"), message: t("server.unavailableHelp"), symbol: "note.text" })
      return EmptyState({ title: t("error.load"), message: failed.message, symbol: "exclamationmark.triangle" })
    }
    const unsaved = saveError()
    if (unsaved) return Row({ title: t("error.save"), subtitle: unsaved, symbol: "exclamationmark.triangle", tint: "warning" })
    const n = notice()
    return n ? HStack({ spacing: 6 }, [Icon("info.circle").font("caption").secondary(), Text(n).font("caption").secondary().lineLimit(2)]) : null
  }
}

/** Creates an empty note and shows it in this surface (user action). */
export async function newNoteHere(vs: ViewState) {
  const note = await createNote({}).catch(() => null)
  if (note) {
    vs.clearSearch()
    vs.select(note.id)
  }
}
