/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Variant "grouped": the field and scope toggle on one line, then native rows
// grouped by source with a count, a "N more" row that narrows to that source,
// and quiet lines for sources that could not be searched. Return opens the
// highlighted (best) row; Escape clears.

import { t } from "../l10n.ts"
import type { Hit } from "../model.ts"
import type { SourceId } from "../query.ts"
import type { Controller } from "./controller.ts"
import { MissingFooter, RecentSearches, ScopeChip, SearchField, Status, moreLabel, rowSubtitle, sourceTitle } from "./parts.ts"

type Line = { key: string; header?: { source: SourceId; total: number }; hit?: Hit; more?: { source: SourceId; label: string } }

export function lines(c: Controller): Line[] {
  const out: Line[] = []
  for (const g of c.response().groups) {
    out.push({ key: `h:${g.source}`, header: { source: g.source, total: g.total } })
    for (const hit of g.hits) out.push({ key: hit.id, hit })
    const label = c.filter() === g.source ? "" : moreLabel(g.hits.length, g.total, g.truncated)
    if (label) out.push({ key: `m:${g.source}`, more: { source: g.source, label } })
  }
  return out
}

export function GroupedView(c: Controller) {
  const rows = () => lines(c)
  return VStack({ spacing: 4 }, [
    HStack({ spacing: 6 }, [Icon("magnifyingglass").secondary(), SearchField(c), ScopeChip(c)]).paddingHorizontal(8),
    () => Status(c),
    () => (c.query().trim() ? null : RecentSearches(c)),
    ForEach({ items: rows, key: (r) => r.key }, (r) => {
      const line = r()
      if (line.header) {
        return HStack({ spacing: 6 }, [Text(() => sourceTitle(r().header!.source)).font("caption").secondary(), Spacer(), Text(() => String(r().header!.total)).font("caption2").secondary()])
          .paddingHorizontal(8)
          .paddingVertical(2)
      }
      if (line.more) {
        return Text(() => r().more!.label)
          .font("caption")
          .secondary()
          .paddingHorizontal(8)
          .cursor("pointer")
          .onTap(() => c.setFilter(r().more!.source))
      }
      return Row({
        title: () => r().hit!.title,
        subtitle: () => rowSubtitle(r().hit!),
        symbol: () => r().hit!.symbol,
        selected: () => c.active()?.id === r().hit!.id
      })
        .help(() => r().hit!.location)
        .onTap(() => c.open(r().hit!))
        .contextMenu(() => [Button(t("open", "Open"), () => c.open(r().hit!))])
    }),
    MissingFooter(c)
  ])
}
