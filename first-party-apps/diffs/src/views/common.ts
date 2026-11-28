// Pieces every diff view shares: file headers, status symbols, the toolbar,
// error and empty states.

import type { DiffResource, FileStatus } from "../interfaces/diff.ts"
import { t } from "../l10n.ts"
import type { FileDecision } from "../model/review.ts"
import type { FileDiff } from "../model/unified.ts"
import type { Session, SessionError } from "../session.ts"
import { layout, toggleLayout } from "../settings.ts"

export const basename = (path: string) => path.slice(path.lastIndexOf("/") + 1) || path
export const dirname = (path: string) => (path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "")

export function statusSymbol(s: FileStatus): string {
  switch (s) {
    case "added":
    case "untracked":
      return "plus.circle"
    case "deleted":
      return "minus.circle"
    case "renamed":
    case "copied":
      return "arrow.right.circle"
    case "binary":
      return "doc.circle"
    default:
      return "circle.fill"
  }
}

export function statusTint(s: FileStatus): string {
  switch (s) {
    case "added":
      return "success"
    case "deleted":
      return "danger"
    case "untracked":
      return "tertiary"
    default:
      return "warning"
  }
}

export const statusLabel = (s: FileStatus) => t(`status.${s}`, s.charAt(0).toUpperCase() + s.slice(1))

export const stat = (a: number, d: number) => t("stat", "+{a} −{d}", { a, d })

export function decisionBadge(d: FileDecision) {
  if (d === "pending") return null
  const tone = d === "accept" ? "success" : d === "reject" ? "danger" : "secondary"
  const english = d === "accept" ? "Accepted" : d === "reject" ? "Rejected" : "Partly decided"
  return Badge(t(`file.decision.${d}`, english), tone)
}

export function producerLine(r: DiffResource): string {
  switch (r.producer) {
    case "git":
      return t("producer.git", "Working tree")
    case "agent":
      return t("producer.agent", "Proposed by {name}", { name: r.producerLabel ?? "agent" })
    case "automation":
      return t("producer.run", "Diff from run {name}", { name: r.producerLabel ?? "" })
    default:
      return t("producer.user", "Diff")
  }
}

const MISSING_HINTS: Record<string, string> = {
  "git.status": "Showing changes needs git status from the session host.",
  "git.diff": "Showing a diff needs git diff from the session host.",
  "diff.get": "Opening a diff needs diff resources.",
  "feed.get": "Reviewing a proposal needs feed items.",
  "document.read": "Comparing documents needs the document host."
}

/** The error panel. A missing proposed op says which op is missing. */
export function errorState(err: SessionError) {
  if (err.code === "operation.unsupported" || err.code === "scope.missing") {
    const op = err.op ?? "operation"
    return EmptyState({ title: t("error.missing", "{op} is not available yet.", { op }), message: MISSING_HINTS[op] ?? err.message, symbol: "puzzlepiece.extension" })
  }
  if (err.code === "git.not_a_repository") return EmptyState({ title: t("changes.noRepo", "Not a git repository"), symbol: "folder" })
  return EmptyState({ title: t("error.load", "Cannot load the diff"), message: err.message, symbol: "exclamationmark.triangle" })
}

/** Toolbar above the pane: title, totals, layout switch, refresh. */
export function toolbar(session: Session, extra: CmuxChildren = []) {
  const res = () => session.loaded()?.resource
  const totals = () => session.files().reduce((s, f) => [s[0]! + f.additions, s[1]! + f.deletions], [0, 0])
  return HStack({ spacing: 8 }, [
    VStack({ spacing: 1 }, [
      Text(() => res()?.title ?? "").font("headline").lineLimit(1).truncation("middle"),
      Text(() => {
        const r = res()
        if (!r) return ""
        const [a, d] = totals()
        return `${producerLine(r)} · ${t("files.count", "{n} files", { n: session.files().length })} · ${stat(a!, d!)}`
      })
        .font("caption")
        .secondary()
        .lineLimit(1)
    ]),
    Spacer(),
    ...extra,
    Button(() => (layout() === "inline" ? t("layout.sideBySide", "Side by Side") : t("layout.inline", "Inline")), () => toggleLayout()).font("caption"),
    Button(Icon("arrow.clockwise"), () => session.reload()).help(t("action.refresh", "Refresh"))
  ]).padding({ top: 6, leading: 10, bottom: 6, trailing: 10 })
}

export function fileHeader(session: Session, file: () => FileDiff, opts: { collapsible: boolean; controls?: CmuxChildren[number] }) {
  return HStack({ spacing: 6 }, [
    () => (opts.collapsible ? Icon(() => (session.collapsed(file().path) ? "chevron.right" : "chevron.down")).font("caption").secondary() : null),
    Icon(() => statusSymbol(file().status)).font("caption").color(() => statusTint(file().status)),
    Text(() => file().path).font("callout").weight("medium").monospaced().lineLimit(1).truncation("head"),
    () => (file().oldPath ? Text(t("file.renamed", "Renamed from {path}", { path: file().oldPath! })).font("caption").secondary().lineLimit(1) : null),
    Spacer(),
    Text(() => (file().binary ? "" : stat(file().additions, file().deletions))).font("caption").monospaced().secondary(),
    opts.controls ?? null
  ])
    .padding({ top: 5, leading: 10, bottom: 5, trailing: 10 })
    .background("hover")
    .cursor(opts.collapsible ? "pointer" : "default")
    .onTap(() => (opts.collapsible ? session.toggleCollapsed(file().path) : undefined))
}

/** Loading, error and empty handling around a loaded body. */
export function guarded(session: Session, body: () => CmuxView) {
  return () => {
    const err = session.error()
    if (err) return errorState(err)
    if (!session.loaded()) return session.loading() ? EmptyState({ title: t("pane.loading", "Loading diff"), symbol: "hourglass" }) : null
    if (!session.files().length) return EmptyState({ title: t("pane.empty", "No differences"), symbol: "checkmark.circle" })
    return body()
  }
}

export function actionErrorRow(session: Session) {
  return () => {
    const e = session.actionError()
    if (!e) return null
    const op = e.op ?? (e.code === "operation.unsupported" ? "diff.decide" : "")
    return HStack({ spacing: 6 }, [
      Icon("exclamationmark.triangle").font("caption").color("warning"),
      Text(e.code === "operation.unsupported" ? t("error.missing", "{op} is not available yet.", { op: op || e.message }) : e.message).font("caption").lineLimit(2)
    ]).padding({ top: 4, leading: 10, bottom: 4, trailing: 10 })
  }
}
