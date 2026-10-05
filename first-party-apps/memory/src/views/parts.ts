// Pieces the designs share: file labels, the document as entries, the add
// field, the review card with its diff, search and errors.

import { appendTo, apply, cancel, openInDiffs, removeEntry, replaceEntry, trashFile } from "../actions.ts"
import { type Entry, parseEntries } from "../model/entries.ts"
import { agentsLabel, type MemoryKind } from "../model/kinds.ts"
import { diffLines, type DiffLine } from "../model/linediff.ts"
import type { FileRef } from "../model/review.ts"
import { t } from "../l10n.ts"
import type { OpError } from "../ops.ts"
import { type MemFile, open, openError, review, rootOf, search, select, selected } from "../store.ts"

export function kindText(k: MemoryKind): string {
  switch (k) {
    case "instructions":
      return t("kind.instructions", "Instructions")
    case "local":
      return t("kind.local", "Personal, not shared")
    case "override":
      return t("kind.override", "Override")
    case "memoryIndex":
      return t("kind.memoryIndex", "Memory index")
    case "memoryTopic":
      return t("kind.memoryTopic", "Memory")
    case "rules":
      return t("kind.rules", "Rules")
  }
}

/** "~/.claude/CLAUDE.md" for user roots, "AGENTS.md" for projects. */
export const displayPath = (f: Pick<MemFile, "root" | "path">) => (rootOf(f.root)?.kind === "user" ? `~/${f.path}` : f.path)

export const fileSubtitle = (f: MemFile) => [agentsLabel(f.c.agents), kindText(f.c.kind), f.c.slug ? (f.project_label ?? f.c.slug) : null].filter(Boolean).join(" · ")

export const refOf = (f: Pick<MemFile, "root" | "path">): FileRef => ({ root: f.root, path: f.path, label: displayPath(f) })

export const isSelected = (f: Pick<MemFile, "root" | "path">) => selected()?.root === f.root && selected()?.path === f.path

export function fileSymbol(k: MemoryKind) {
  return k === "memoryIndex" || k === "memoryTopic" ? "brain" : k === "rules" ? "list.bullet.rectangle" : "doc.text"
}

export function fileRow(f: () => MemFile) {
  return Row({
    title: () => displayPath(f()),
    subtitle: () => fileSubtitle(f()),
    symbol: () => fileSymbol(f().c.kind),
    selected: () => isSelected(f())
  }).onTap(() => void select(f().root, f().path))
}

const [editing, setEditing] = signal<string | null>(null)

function entryView(file: FileRef, e: Entry) {
  if (editing() === e.text) {
    return TextField(e.text, {
      placeholder: t("edit.placeholder", "Change this line"),
      autofocus: true,
      onSubmit: (text) => {
        setEditing(null)
        void replaceEntry(file, e.text, text)
      },
      onCancel: () => setEditing(null)
    })
  }
  // The menu sits on the text, which fills the row.
  const menu = () => [Button(t("action.edit", "Edit…"), () => setEditing(e.text)), Button(t("action.deleteLine", "Delete Line…"), () => void removeEntry(file, e.text)).destructive()]
  return HStack({ spacing: 6 }, [
    Text(e.bullet ? "•" : " ").font("callout").secondary(),
    Text(e.text).font("callout").lineLimit(4).frame({ maxWidth: "infinity" }).contextMenu(menu),
    Text(String(e.start)).font(10).monospaced().color("tertiary")
  ]).padding({ top: 2, leading: 0, bottom: 2, trailing: 0 })
}

/** The open document as entries under their headings, an add field and Move to Trash. */
export function documentView(maxEntries = 60) {
  return () => {
    const err = openError()
    if (err) return errorState(err, t("error.open", "Cannot open this file"))
    const doc = open()
    if (!doc) return selected() ? Text(t("loading.file", "Opening…")).font("callout").secondary().padding(12) : null
    const file = refOf(doc)
    const entries = parseEntries(doc.text)
    const out: CmuxView[] = []
    let section: string | null | undefined
    for (const e of entries.slice(0, maxEntries)) {
      if (e.section !== section) {
        section = e.section
        if (section) out.push(Text(section).font("caption").weight("semibold").secondary().padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }))
      }
      out.push(entryView(file, e))
    }
    return VStack({ spacing: 4 }, [
      HStack({ spacing: 8 }, [
        Text(file.label).font("headline").monospaced().lineLimit(1).truncation("head"),
        Spacer(),
        Button(t("action.trash", "Move to Trash…"), () => void trashFile(file)).font("caption")
      ]),
      doc.changed ? Text(t("doc.changed", "An agent changed this file while you reviewed. Save checks your edit against the newest text.")).font("caption").color("warning") : null,
      entries.length ? VStack({ spacing: 2 }, out) : Text(t("doc.empty", "This file is empty")).font("callout").secondary(),
      entries.length > maxEntries ? Text(t("doc.more", "{n} more entries", { n: entries.length - maxEntries })).font("caption").secondary() : null,
      TextField("", { placeholder: t("add.placeholder", "Add a line to this file…"), onSubmit: (text) => void appendTo(file, text) })
    ]).padding(12)
  }
}

// MARK: review

const LINE_HEIGHT = 16
const CONTEXT = 2
const MAX_LINES = 40

/** Changed lines with CONTEXT lines around them; "…" between distant changes. */
export function previewLines(before: string, after: string): Array<DiffLine | null> {
  const lines = diffLines(before, after)
  const keep = new Set<number>()
  lines.forEach((l, i) => {
    if (l.kind !== "context") for (let k = i - CONTEXT; k <= i + CONTEXT; k++) keep.add(k)
  })
  const out: Array<DiffLine | null> = []
  let last = -1
  lines.forEach((l, i) => {
    if (!keep.has(i)) return
    if (last >= 0 && i > last + 1) out.push(null)
    out.push(l)
    last = i
  })
  return out
}

function diffLine(l: DiffLine | null) {
  if (!l) return Text("…").font(11).monospaced().color("tertiary").padding({ top: 0, leading: 6, bottom: 0, trailing: 6 })
  const tone = l.kind === "add" ? "success" : l.kind === "del" ? "danger" : null
  const row = HStack({ spacing: 6 }, [
    Text(String(l.newLine ?? l.oldLine ?? "").padStart(3, " ")).font(10).monospaced().color("tertiary"),
    Text(`${l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "} ${l.text || " "}`).font(11).monospaced().lineLimit(1).truncation("tail")
  ])
    .padding({ top: 0, leading: 6, bottom: 0, trailing: 6 })
    .frame({ maxWidth: "infinity", height: LINE_HEIGHT })
  return tone ? ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), row]) : row
}

const [diffsNotice, setDiffsNotice] = signal<string | null>(null)

function failure(code: string, message: string): string {
  if (code === "document.stale") return t("failed.stale", "The file changed again while you reviewed. Look at it and try once more.")
  if (code === "scope.missing") return t("failed.scope", "Allow this app to change memory files in Settings > Apps.")
  if (code === "operation.unsupported") return t("failed.unsupported", "This cmux cannot write memory files yet.")
  if (code === "memory.empty") return t("failed.empty", "Type some text first.")
  return message || code
}

export function reviewCard() {
  return () => {
    const s = review()
    if (s.phase === "idle") return null
    let body: CmuxView
    if (s.phase === "preparing") body = Text(t("review.preparing", "Reading the file…")).font("callout").secondary()
    else if (s.phase === "applied") body = HStack({ spacing: 8 }, [Icon("checkmark.circle.fill").color("success"), Text(s.intent.op === "trash" ? t("review.trashed", "Moved to the Trash") : t("review.saved", "Saved")).font("callout"), Spacer(), Button(t("action.done", "Done"), () => cancel()).font("caption")])
    else if (s.phase === "gone") body = HStack({ spacing: 8 }, [Text(t("review.gone", "That line is no longer in the file; an agent changed it.")).font("callout").lineLimit(2), Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")])
    else if (s.phase === "failed") body = HStack({ spacing: 8 }, [Icon("exclamationmark.triangle.fill").color("warning"), Text(failure(s.code, s.message)).font("callout").lineLimit(3), Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")])
    else {
      const lines = previewLines(s.before, s.after)
      const applying = s.phase === "applying"
      body = VStack({ spacing: 6 }, [
        s.phase === "review" && s.note === "rebased" ? Text(t("review.rebased", "An agent changed this file after the first preview. This is your edit on the new text.")).font("caption").color("warning") : null,
        VStack({ spacing: 0 }, lines.slice(0, MAX_LINES).map(diffLine)).background("hover").cornerRadius(4),
        lines.length > MAX_LINES ? Text(t("review.more", "{n} more lines", { n: lines.length - MAX_LINES })).font("caption").secondary() : null,
        () => (diffsNotice() ? Text(diffsNotice()!).font("caption").color("warning").lineLimit(2) : null),
        HStack({ spacing: 10 }, [
          s.intent.op === "trash" ? null : Button(t("action.openInDiffs", "Open in Diffs"), async () => setDiffsNotice(await openInDiffs())).font("caption").disabled(applying),
          Spacer(),
          Button(t("action.cancel", "Cancel"), () => cancel()).font("caption").disabled(applying),
          applying
            ? ProgressView(null).frame({ width: 12, height: 12 })
            : Button(s.intent.op === "trash" ? t("action.moveToTrash", "Move to Trash") : t("action.save", "Save"), () => void apply())
                .font("caption")
                .weight("semibold")
        ])
      ])
    }
    return VStack({ spacing: 6 }, [Text(s.title).font("headline").lineLimit(2), body]).padding(10).background("hover").cornerRadius(8).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 })
  }
}

// MARK: search and errors

export const searchField = () => TextField("", { placeholder: t("search.placeholder", "Search memory"), onSubmit: (q) => void search(q), onEdit: (q) => (q === "" ? void search("") : undefined) })

export function errorState(err: OpError, title: string) {
  if (err.missing) return EmptyState({ title: t("error.missingTitle", "Agent memory is not available yet"), message: t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }), symbol: "puzzlepiece.extension" })
  return EmptyState({ title, message: err.message, symbol: "exclamationmark.triangle" })
}
