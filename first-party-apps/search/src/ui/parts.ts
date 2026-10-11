/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View pieces shared by the variants: the query field, chips, highlighted
// text, recent searches and the "what is missing" footer.

import { t } from "../l10n.ts"
import { nameSegments, type Segments } from "../match.ts"
import type { Hit, Unavailable } from "../model.ts"
import { SOURCES, type SourceId } from "../query.ts"
import { clearMemory, recent } from "../memory.ts"
import type { Controller } from "./controller.ts"

export const SOURCE_SYMBOL: Record<SourceId, string> = { workspaces: "square.stack", terminals: "terminal", browser: "globe", apps: "square.grid.2x2", files: "doc" }

export function sourceTitle(source: SourceId): string {
  switch (source) {
    case "workspaces":
      return t("source.workspaces", "Workspaces")
    case "terminals":
      return t("source.terminals", "Terminals")
    case "browser":
      return t("source.browser", "Browser")
    case "apps":
      return t("source.apps", "Apps")
    case "files":
      return t("source.files", "Files")
  }
}

export function SearchField(c: Controller, long = false) {
  return TextField(c.query, {
    placeholder: long ? t("field.placeholder.long", "Search workspaces, terminals, pages and files") : t("field.placeholder", "Search"),
    autofocus: long,
    onEdit: (text) => c.edit(text),
    onSubmit: (text) => c.submit(text),
    onCancel: () => c.cancel()
  })
}

/**
 * Text with one highlighted range. The renderer has no attributed text, so
 * this is three Text nodes in an HStack (proposed: a `highlights` prop on Text
 * and `subtitleHighlights` on Row). Long text truncates per segment.
 */
export function Highlighted(segments: () => Segments, options: { monospaced?: boolean; font?: string; secondary?: boolean } = {}) {
  const style = (v: ReturnType<typeof Text>) => {
    let out = v.lineLimit(1)
    if (options.font) out = out.font(options.font)
    if (options.monospaced) out = out.monospaced()
    return out
  }
  const plain = (v: ReturnType<typeof Text>) => (options.secondary ? style(v).secondary() : style(v))
  return HStack({ spacing: 0 }, [
    plain(Text(() => segments().before)).truncation("head"),
    style(Text(() => segments().match)).weight("semibold").color("accent").fixedSize("horizontal"),
    plain(Text(() => segments().after)).truncation("tail").layoutPriority(1)
  ])
}

export const titleSegments = (hit: Hit): Segments => nameSegments(hit.title, hit.titleRange)
export const previewText = (s: Segments | null) => (s ? s.before + s.match + s.after : "")

/** One-line subtitle for a native Row: the matched line when there is one, else the location. */
export const rowSubtitle = (hit: Hit) => previewText(hit.preview) || hit.location

export function Chip(label: () => string, selected: () => boolean, onTap: () => void, help?: string) {
  const v = Text(label)
    .font("caption")
    .lineLimit(1)
    .fixedSize("horizontal")
    .color(() => (selected() ? "primary" : "secondary"))
    .paddingHorizontal(7)
    .paddingVertical(3)
    .background(() => (selected() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(5)
    .cursor("pointer")
    .onTap(onTap)
  return help ? v.help(help) : v
}

export function ScopeChip(c: Controller) {
  return Chip(
    () => (c.effectiveScope() === "workspace" ? t("scope.workspace", "This Workspace") : t("scope.all", "Everywhere")),
    () => c.effectiveScope() === "workspace",
    () => c.toggleScope()
  )
}

export function SourceChips(c: Controller) {
  return HStack({ spacing: 2 }, [
    Chip(() => t("filter.all", "All"), () => c.filter() === null, () => c.setFilter(null)),
    ...SOURCES.map((s) => Chip(() => sourceTitle(s), () => c.filter() === s, () => c.setFilter(s)))
  ])
}

export function RegexChip(c: Controller) {
  return Chip(() => t("regex.toggle", ".*"), c.regex, () => c.toggleRegex(), t("regex.help", "Regular expression")).monospaced()
}

export function RecentSearches(c: Controller) {
  return VStack({ spacing: 2 }, [
    () => (recent().length ? Text(t("recent.title", "Recent")).font("caption").secondary().paddingHorizontal(8).paddingVertical(2) : null),
    ForEach({ items: recent, key: (q) => q }, (q) =>
      Row({ title: () => q(), symbol: "clock.arrow.circlepath" })
        .onTap(() => c.useRecent(q()))
        .contextMenu([Button(t("recent.clear", "Clear Recent Searches"), () => clearMemory())])
    )
  ])
}

export function missingCopy(u: Unavailable): string {
  const source = sourceTitle(u.source)
  if (u.code === "scope.missing") return t("missing.scope", "{source}: access not granted", { source })
  if (u.code === "no.roots") return t("missing.files.noRoots", "No folder to search (folders come from terminal working directories)")
  if (u.code !== "operation.unsupported") return t("missing.generic", "{source}: cannot search ({code})", { source, code: u.code })
  switch (u.source) {
    case "terminals":
      return t("missing.terminals", "Terminal history needs terminal.search (searched visible screens only)")
    case "browser":
      return t("missing.browser", "Browsing history needs browser.history.search")
    case "files":
      return t("missing.files", "File search needs fs.search")
    case "apps":
      return t("missing.apps", "Other apps' items need search.providers.query")
    case "workspaces":
      return t("missing.workspaces", "Name search needs session.snapshot")
  }
}

/** Quiet lines under the results naming each source that could not be searched. */
export function MissingFooter(c: Controller) {
  return ForEach({ items: () => c.response().unavailable.filter((u) => u.code !== "query.invalid"), key: (u) => `${u.source}:${u.code}` }, (u) =>
    HStack({ spacing: 4 }, [Icon("info.circle").font("caption2").secondary(), Text(() => missingCopy(u())).font("caption2").secondary().lineLimit(2)]).paddingHorizontal(8)
  )
}

/** Empty, no-match and invalid-regex states. Returns null while results show. */
export function Status(c: Controller) {
  const r = c.response()
  if (!c.query().trim()) return recent().length ? null : EmptyState({ title: t("empty.title", "Search Everything"), message: t("empty.message", "t: terminals, f: files, b: browser, w: workspaces, a: apps. /regex/ works too."), symbol: "magnifyingglass" })
  if (r.unavailable.some((u) => u.code === "query.invalid")) return EmptyState({ title: t("invalid.title", "Invalid regular expression"), message: r.error ?? "", symbol: "exclamationmark.triangle" })
  if (c.loading() && !r.ranked.length) return Text(t("searching", "Searching…")).font("caption").secondary().paddingHorizontal(8)
  if (!c.loading() && !r.ranked.length && r.query === c.query()) {
    return EmptyState({ title: t("none.title", "No Matches"), message: r.scope === "workspace" ? t("none.here", "Nothing here. Try in:all.") : t("none.message", "Nothing matches “{query}”", { query: c.query().trim() }), symbol: "magnifyingglass" })
  }
  return null
}

export function moreLabel(shown: number, total: number, truncated: boolean): string {
  return total > shown ? t("more", "{count} more", { count: total - shown }) : truncated ? t("more.unknown", "More results") : ""
}
