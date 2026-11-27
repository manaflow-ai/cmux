// The pane's three designs (DEV/NIGHTLY setting `variant`):
//   files    memory files grouped by machine and project, the selected file
//            below as entries (edit, delete, add), the review above
//   entries  every entry of every memory file in one list under file headers,
//            filtered as you type; edit and delete from each entry
//   split    file list on the left, the selected file and its review on the right

import { removeEntry } from "../actions.ts"
import { type Entry, parseEntries } from "../model/entries.ts"
import { t } from "../l10n.ts"
import { allFiles, errors, fileKey, hits, loadAllTexts, loaded, query, rootOf, roots, rootsError, select, texts, type MemFile, type Root } from "../store.ts"
import { displayPath, documentView, errorState, fileRow, fileSubtitle, refOf, reviewCard, searchField } from "./parts.ts"

function rootTitle(r: Root): string {
  const machine = r.machine_label || t("machine.this", "This Mac")
  return r.kind === "user" ? t("root.user", "{machine} · everywhere", { machine }) : t("root.project", "{project} · {machine}", { project: r.label, machine })
}

function gate() {
  if (!loaded()) return Text(t("loading", "Looking for agent memory…")).font("callout").secondary().padding(16)
  const err = rootsError()
  if (err) return errorState(err, t("error.roots", "Cannot find agent memory"))
  if (!allFiles().length && !Object.keys(errors()).length) return EmptyState({ title: t("empty.title", "No agent memory files"), message: t("empty.message", "CLAUDE.md, AGENTS.md and agent memory folders show up here."), symbol: "brain" })
  return null
}

/** Search hits; call inside a reactive child. */
function hitList() {
  const h = hits() ?? []
  if (!h.length) return Text(t("search.none", "No memory matches “{q}”", { q: query() })).font("callout").secondary().padding(12)
  return VStack(
    { spacing: 0 },
    h.slice(0, 30).map((x) =>
      Row({ title: x.text || x.path, subtitle: x.line ? t("search.where", "{file}, line {line}", { file: displayPath(x), line: x.line }) : displayPath(x), symbol: "magnifyingglass" }).onTap(() => void select(x.root, x.path))
    )
  )
}

function rootGroups() {
  return VStack({ spacing: 0 }, [
    ForEach({ items: roots, key: (r) => r.root }, (r) =>
      VStack({ spacing: 0 }, [
        Text(() => rootTitle(r())).font("caption").weight("semibold").secondary().padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
        () => {
          const err = errors()[r().root]
          return err ? Text(err.missing ? t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }) : err.message).font("caption").color("danger").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }) : null
        },
        ForEach({ items: () => allFiles().filter((f) => f.root === r().root), key: (f) => f.path }, (f) => fileRow(f))
      ])
    )
  ])
}

const header = () =>
  VStack({ spacing: 6 }, [Text(t("title", "Agent Memory")).font("headline"), searchField()]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 })

export function filesView() {
  return VStack({ spacing: 0 }, [header(), reviewCard(), Divider(), () => gate() ?? VStack({ spacing: 0 }, [() => (hits() !== null ? hitList() : rootGroups()), Divider(), documentView()])])
}

// MARK: entries

function entryRow(f: MemFile, e: Entry) {
  // The menu sits on the text, which fills the row.
  const menu = () => [Button(t("action.openFile", "Show File"), () => void select(f.root, f.path)), Button(t("action.deleteLine", "Delete Line…"), () => void removeEntry(refOf(f), e.text)).destructive()]
  return HStack({ spacing: 6 }, [Text("•").font("callout").secondary(), Text(e.text).font("callout").lineLimit(3).frame({ maxWidth: "infinity" }).contextMenu(menu)])
    .padding({ top: 3, leading: 12, bottom: 3, trailing: 12 })
    .hoverBackground("hover")
}

const [requested, setRequested] = signal(false)

export function entriesView() {
  return VStack({ spacing: 0 }, [
    header(),
    reviewCard(),
    Divider(),
    () => {
      const g = gate()
      if (g) return g
      if (!requested()) {
        setRequested(true)
        void loadAllTexts()
      }
      const q = query().trim().toLowerCase()
      const blocks = allFiles().map((f) => {
        const text = texts()[fileKey(f.root, f.path)]
        const entries = text === undefined ? [] : parseEntries(text).filter((e) => !q || e.text.toLowerCase().includes(q))
        return { f, loaded: text !== undefined, entries }
      })
      const shown = blocks.filter((b) => b.entries.length || (!q && !b.loaded))
      if (!shown.length) return Text(q ? t("search.none", "No memory matches “{q}”", { q: query() }) : t("doc.empty", "This file is empty")).font("callout").secondary().padding(12)
      return VStack(
        { spacing: 0 },
        shown.flatMap((b) => [
          HStack({ spacing: 6 }, [
            Text(displayPath(b.f)).font("caption").weight("semibold").monospaced().lineLimit(1).truncation("head").layoutPriority(1),
            Text(`${fileSubtitle(b.f)} · ${rootTitle(rootOf(b.f.root)!)}`).font("caption").secondary().lineLimit(1),
            Spacer()
          ]).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
          ...(b.loaded ? b.entries.slice(0, 12).map((e) => entryRow(b.f, e)) : [Text(t("loading.file", "Opening…")).font("caption").secondary().padding({ top: 0, leading: 12, bottom: 0, trailing: 12 })]),
          b.entries.length > 12 ? Text(t("doc.more", "{n} more entries", { n: b.entries.length - 12 })).font("caption").secondary().padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }).onTap(() => void select(b.f.root, b.f.path)) : null
        ])
      )
    }
  ])
}


// MARK: split

export function splitView() {
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 8 }, [Text(t("title", "Agent Memory")).font("headline"), Spacer()]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 }),
    Divider(),
    () =>
      gate() ??
      HStack({ spacing: 0 }, [
        VStack({ spacing: 0 }, [VStack({ spacing: 0 }, [searchField()]).padding(8), () => (hits() !== null ? hitList() : rootGroups()), Spacer()]).frame({ width: 260, maxHeight: "infinity" }),
        Rectangle().fill("separator").frame({ width: 1, maxHeight: "infinity" }),
        VStack({ spacing: 0 }, [reviewCard(), documentView(), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
      ])
  ])
}
