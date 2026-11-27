// Shared pieces of the browser: path bar, list header and rows, list states.

import { openEntry, rename } from "../actions.ts"
import type { Browser } from "../browser.ts"
import { formatBytes, formatCount, formatDate, kindLabel, symbolFor } from "../format.ts"
import { t } from "../l10n.ts"
import { type Entry, kindGroup, type SortKey } from "../model/entries.ts"
import { collapseCrumbs, crumbs } from "../model/handles.ts"
import { displayTotal } from "../model/listing.ts"
import { notice, sidebarError } from "../store.ts"
import { entryMenu, isEditing, stopEdit } from "./menus.ts"
import { gesture } from "../runtime.ts"

export const COLUMN_WIDTHS = { modified: 118, size: 64, kind: 88 }

export function pathBar(b: Browser, trailing: CmuxChildren = []) {
  return HStack({ spacing: 4 }, [
    Button(Icon("chevron.up").size(11), () => b.up())
      .disabled(() => (b.location()?.path ?? "") === "")
      .help(t("action.up", "Enclosing Folder")),
    () => {
      const loc = b.location()
      const root = b.root()
      if (!loc) return Text(t("pathbar.none", "No folder")).color("secondary")
      const conn = b.conn()
      const parts = collapseCrumbs(crumbs(root?.label ?? t("pathbar.root", "Root"), loc.path))
      return HStack({ spacing: 2 }, [
        conn && conn.kind !== "local" ? Badge(conn.label, "secondary") : null,
        ...parts.flatMap((c, i) => [
          i > 0 ? Icon("chevron.right").size(8).color("tertiary") : null,
          c === null
            ? Text("…").color("tertiary")
            : Button(Text(c.label).font("callout").weight(i === parts.length - 1 ? "semibold" : "regular").lineLimit(1), () => b.open({ ...loc, path: c.path }))
        ])
      ])
    },
    Spacer(),
    ...trailing
  ]).padding({ top: 6, leading: 8, bottom: 6, trailing: 8 })
}

function headerCell(b: Browser, key: SortKey, label: string, width?: number) {
  return Button(
    HStack({ spacing: 3 }, [
      Text(label).font("caption").weight(() => (b.state().sort.key === key ? "semibold" : "regular")).color("secondary"),
      () => (b.state().sort.key === key ? Icon(b.state().sort.dir === "asc" ? "chevron.up" : "chevron.down").size(8).color("secondary") : null),
      width ? null : Spacer()
    ]),
    () => b.setSort(key)
  ).frame(width ? { width } : { maxWidth: "infinity" })
}

export function listHeader(b: Browser, compact = false) {
  return HStack({ spacing: 8 }, [
    Spacer().frame({ width: 16 }),
    headerCell(b, "name", t("column.name", "Name")),
    compact ? null : headerCell(b, "modified", t("column.modified", "Date Modified"), COLUMN_WIDTHS.modified),
    headerCell(b, "size", t("column.size", "Size"), COLUMN_WIDTHS.size),
    compact ? null : headerCell(b, "kind", t("column.kind", "Kind"), COLUMN_WIDTHS.kind)
  ]).padding({ top: 4, leading: 10, bottom: 4, trailing: 10 })
}

/** One list row. Tap selects; tapping the selected row opens it (the scene has no double-click and no modifier keys: finder.md gaps G3, G4). */
export function entryRow(b: Browser, entry: CmuxSignal<Entry>, compact = false) {
  const selected = () => b.selection().includes(entry().name)
  const dim = () => (entry().hidden || entry().name.startsWith(".") ? 0.55 : 1)
  return HStack({ spacing: 8 }, [
    Icon(() => symbolFor(entry())).color(() => (kindGroup(entry()) === "folder" ? "accent" : "secondary")).frame({ width: 16 }),
    () =>
      isEditing(b, entry().name)
        ? TextField(entry().name, {
            placeholder: t("rename.placeholder", "New name"),
            autofocus: true,
            onSubmit: (text) => {
              const g = gesture()
              const from = entry().name
              stopEdit()
              void rename(b, from, text, g)
            },
            onCancel: stopEdit
          }).frame({ maxWidth: "infinity" })
        : Text(() => entry().name).lineLimit(1).truncation("middle").frame({ maxWidth: "infinity" }),
    compact ? null : Text(() => formatDate(entry().mtime)).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.modified }),
    Text(() => (kindGroup(entry()) === "folder" ? "—" : formatBytes(entry().size))).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.size }),
    compact ? null : Text(() => kindLabel(kindGroup(entry()))).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.kind })
  ])
    .padding({ top: 3, leading: 10, bottom: 3, trailing: 10 })
    .background(() => (selected() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(5)
    .opacity(dim)
    .contextMenu(() => entryMenu(b, entry().name))
    .onTap(() => {
      const g = gesture()
      const name = entry().name
      if (selected() && b.selection().length === 1) void openEntry(b, name, g)
      else b.select(name)
    })
}

// Structure changes only when a computed mode string changes; text inside uses
// bindings, so batches and watch events update props instead of rebuilding.

export function pagerText(b: Browser): string {
  const loaded = b.allRows().length
  const total = displayTotal(b.state())
  const from = loaded === 0 ? 0 : b.offset() + 1
  const to = Math.min(loaded, b.offset() + b.pageRows)
  return t("list.range", "{from}–{to} of {total}", { from: formatCount(from), to: formatCount(to), total: formatCount(total ?? loaded) })
}

/** Pager under the list; only when there is more than one page. */
export function pager(b: Browser) {
  const shown = computed(() => b.hasPrev() || b.hasNext())
  return () =>
    shown()
      ? HStack({ spacing: 6 }, [
          Button(Icon("chevron.left").size(11), () => b.prev()).disabled(() => !b.hasPrev()).help(t("list.prev", "Previous page")),
          Text(() => pagerText(b)).font("caption").color("secondary"),
          Button(Icon("chevron.right").size(11), () => void b.next()).disabled(() => !b.hasNext()).help(t("list.next", "Next page")),
          Spacer()
        ]).padding({ top: 4, leading: 10, bottom: 2, trailing: 10 })
      : null
}

export type ListMode = "none" | "missing" | "conn" | "error" | "loading" | "empty" | "rows"

export function listMode(b: Browser): ListMode {
  if (!b.location()) return isMissing(sidebarError()?.code) ? "missing" : "none"
  const conn = b.conn()
  if (conn && conn.state !== "connected") return "conn"
  const s = b.state()
  if (s.status === "error" && s.error) return "error"
  if (s.status === "loading" && s.base.length === 0) return "loading"
  if (b.allRows().length === 0 && (s.status === "complete" || s.status === "partial")) return "empty"
  return "rows"
}

/** Connection, loading, error and empty states; `body` renders when there are rows. */
export function listState(b: Browser, body: () => CmuxView) {
  const mode = computed(() => listMode(b))
  return () => {
    switch (mode()) {
      case "none":
        return EmptyState({ title: t("state.noFolder", "No folder open"), message: t("state.noFolderHint", "Pick a place in the sidebar or add a folder."), symbol: "folder" })
      case "missing":
        return EmptyState({ title: t("error.missingTitle", "File access is not available yet"), message: t("error.missingHint", "This cmux does not provide {op} yet.", { op: "fs.roots.list" }), symbol: "puzzlepiece.extension" })
      case "conn":
        return connectionState(b)
      case "error":
        return errorState(b)
      case "loading":
        return VStack({ spacing: 8, alignment: "center" }, [ProgressView(), Text(t("state.loading", "Loading…")).font("caption").color("secondary")])
          .padding(24)
          .frame({ maxWidth: "infinity" })
      case "empty":
        return EmptyState({ title: () => (b.state().filter.query ? t("state.noMatches", "No matches") : t("state.empty", "Folder is empty")), symbol: "folder" })
      default:
        return body()
    }
  }
}

export function connectionTitle(label: string, state: string): string {
  switch (state) {
    case "connecting":
      return t("conn.connecting", "Connecting to {name}…", { name: label })
    case "verifying":
      return t("conn.verifying", "Waiting for host key confirmation for {name}", { name: label })
    case "needs_auth":
      return t("conn.needsAuth", "{name} needs you to sign in", { name: label })
    case "unreachable":
      return t("conn.unreachable", "{name} is unreachable", { name: label })
    default:
      return t("conn.disconnected", "{name} is not connected", { name: label })
  }
}

export function connectionState(b: Browser) {
  const state = () => b.conn()?.state ?? "disconnected"
  const busy = computed(() => state() === "connecting" || state() === "verifying")
  return VStack({ spacing: 10, alignment: "center" }, [
    () => (busy() ? ProgressView() : Icon(() => (state() === "unreachable" ? "bolt.horizontal.circle" : "network.slash")).size(26).color("tertiary")),
    Text(() => connectionTitle(b.conn()?.label ?? "", state())).font("headline"),
    Text(() => b.conn()?.detail ?? "").font("caption").color("secondary")
  ])
    .padding(28)
    .frame({ maxWidth: "infinity" })
}

export const isMissing = (code: string | undefined) => code === "operation.unsupported" || code === "scope.missing"

export function errorState(b: Browser) {
  const err = () => b.state().error
  const missing = computed(() => isMissing(err()?.code))
  return VStack({ spacing: 10, alignment: "center" }, [
    EmptyState({
      title: () =>
        missing() ? t("error.missingTitle", "File access is not available yet") : err()?.code === "fs.permission_denied" ? t("error.denied", "You do not have permission to see this folder") : t("error.load", "Cannot open this folder"),
      message: () => (missing() ? t("error.missingHint", "This cmux does not provide {op} yet.", { op: "fs.list" }) : (err()?.message ?? "")),
      symbol: () => (missing() ? "puzzlepiece.extension" : "exclamationmark.triangle")
    }),
    () => (missing() ? null : Button(t("action.retry", "Try Again"), () => b.relist()))
  ])
}

export function noticeRow() {
  const shown = computed(() => notice() !== null)
  return () => (shown() ? Text(() => notice() ?? "").font("caption").color("warning").padding({ top: 4, leading: 10, bottom: 4, trailing: 10 }) : null)
}

export function statusText(b: Browser): string {
  const s = b.state()
  const total = displayTotal(s)
  const sel = b.selection().length
  const parts = [t("status.items", "{n} items", { n: formatCount(total ?? b.allRows().length) })]
  if (sel > 0) parts.push(t("status.selected", "{n} selected", { n: sel }))
  if (s.status === "stale") parts.push(t("status.refreshing", "refreshing"))
  return parts.join(" · ")
}

export const statusLine = (b: Browser) => Text(() => statusText(b)).font("caption2").color("tertiary").padding({ top: 4, leading: 10, bottom: 6, trailing: 10 })
