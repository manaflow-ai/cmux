/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Variant "palette": one ranked list with no group headers, drawn the way the
// Cmd-Shift-P palette draws a page (icon, highlighted text, source on the
// right). This is the page a proposed `searchProviders` contribution would
// give the palette; until the palette can host it, the app renders it itself.

import { t } from "../l10n.ts"
import type { Hit } from "../model.ts"
import type { Controller, Density } from "./controller.ts"
import { Highlighted, MissingFooter, SearchField, Status, RecentSearches, sourceTitle, titleSegments } from "./parts.ts"

/** Body text of a palette row: the matched line for text hits, else the highlighted title. */
const mainSegments = (hit: Hit) => hit.preview ?? titleSegments(hit)
const sideText = (hit: Hit) => (hit.preview ? hit.title : hit.location || sourceTitle(hit.source))

export function PaletteView(c: Controller, density: Density) {
  const cap = density === "compact" ? 12 : 30
  const items = () => c.response().ranked.slice(0, cap)
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [Icon("magnifyingglass").secondary(), SearchField(c, density === "full")]).paddingHorizontal(8).paddingVertical(4),
    Divider(),
    () => Status(c),
    () => (c.query().trim() ? null : RecentSearches(c)),
    ForEach({ items, key: (h) => h.id }, (h) =>
      HStack({ spacing: 8 }, [
        Icon(() => h().symbol).secondary().frame({ width: 16 }),
        Highlighted(() => mainSegments(h()), { monospaced: !!h().preview && h().kind !== "appItem" }).layoutPriority(1),
        Text(() => sideText(h())).font("caption").color("tertiary").lineLimit(1).truncation("middle").frame({ maxWidth: 110 })
      ])
        .paddingHorizontal(8)
        .paddingVertical(5)
        .background(() => (c.active()?.id === h().id ? "selected" : null))
        .hoverBackground("hover")
        .cornerRadius(6)
        .help(() => h().location)
        .onTap(() => c.open(h()))
    ),
    MissingFooter(c),
    () => (c.response().ranked.length ? Text(t("hint.palette", "↩ Open  ⎋ Clear")).font("caption2").color("tertiary").paddingHorizontal(8).paddingVertical(4) : null)
  ])
}
