/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Variant "preview": field, source chips, regex and scope toggles, a results
// list, and a preview of the selected result with the match highlighted. A
// tap selects; a tap on the selected row, the Open button or Return opens.

import { t } from "../l10n.ts"
import type { Hit } from "../model.ts"
import type { Controller, Density } from "./controller.ts"
import { lines } from "./grouped.ts"
import { Highlighted, MissingFooter, RecentSearches, RegexChip, ScopeChip, SearchField, SourceChips, Status, sourceTitle, titleSegments } from "./parts.ts"

function PreviewPanel(c: Controller) {
  return () => {
    const hit = c.active()
    if (!c.query().trim()) return null
    if (!hit) return Text(t("preview.none", "Select a result to preview it here")).font("caption").secondary().padding(8)
    return PreviewOf(c, hit)
  }
}

function PreviewOf(c: Controller, hit: Hit) {
  const mono = hit.kind === "terminalText" || hit.kind === "fileContent"
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [Icon(hit.symbol).secondary(), Highlighted(() => titleSegments(hit), { font: "headline" })]),
    hit.location ? Text(hit.location).font("caption").secondary().lineLimit(2).truncation("middle") : null,
    hit.preview ? Highlighted(() => hit.preview!, { monospaced: mono, font: "callout" }).padding(8).background("hover").cornerRadius(6) : null,
    hit.screenOnly ? Text(t("screenOnly", "Visible screen only")).font("caption2").secondary() : null,
    HStack([Spacer(), Button(t("open", "Open"), () => c.open(hit))])
  ]).padding(8)
}

/**
 * The pane puts the list and the preview side by side; the sidebar section
 * stacks them (the renderer gives no container width, so density decides).
 */
export function PreviewView(c: Controller, density: Density) {
  const rows = () => lines(c)
  const list = VStack({ spacing: 4 }, [
    () => Status(c),
    () => (c.query().trim() ? null : RecentSearches(c)),
    ForEach({ items: rows, key: (r) => r.key }, (r) => {
      const line = r()
      if (line.header) return Text(() => sourceTitle(r().header!.source)).font("caption").secondary().paddingHorizontal(8).paddingVertical(2)
      if (line.more) return Text(() => r().more!.label).font("caption").secondary().paddingHorizontal(8).cursor("pointer").onTap(() => c.setFilter(r().more!.source))
      return Row({ title: () => r().hit!.title, subtitle: () => r().hit!.location, symbol: () => r().hit!.symbol, selected: () => c.active()?.id === r().hit!.id }).onTap(() => {
        const hit = r().hit!
        if (c.selectedId() === hit.id) c.open(hit)
        else c.select(hit)
      })
    }),
    MissingFooter(c),
    // HStack has no alignment prop yet: trailing spacers pin both columns to the top.
    density === "full" ? Spacer() : null
  ])
  return VStack({ spacing: 6 }, [
    SearchField(c, true).paddingHorizontal(6),
    SourceChips(c).paddingHorizontal(4),
    HStack({ spacing: 2 }, [RegexChip(c), ScopeChip(c), Spacer()]).paddingHorizontal(4),
    Divider(),
    density === "full"
      ? HStack({ spacing: 0 }, [list.frame({ minWidth: 220, maxWidth: 340 }), Divider(), VStack([PreviewPanel(c), Spacer()]).frame({ maxWidth: "infinity" })])
      : VStack({ spacing: 6 }, [list, Divider(), PreviewPanel(c)])
  ])
}
