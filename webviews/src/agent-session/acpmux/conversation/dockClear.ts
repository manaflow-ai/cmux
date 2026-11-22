// The rows of the floating bottom stack that paint nothing of their own (a "Needs your input" line
// with its Dismiss over a pinned card, data-dock-clear), as holes in the transcript's mask: the
// transcript stays visible behind them, where the mask hid it under the stack's whole height. Leo,
// 2026-11-17, of that line over his wallpaper with "Worked for" cut off under it: "why do you have
// the entire row blanked out? don't ever do that. this needs your input dismiss row erases things
// behind it".

/// One clear row: its top and bottom, in px from the view's bottom edge (the stack sits on it).
export type ClearSpan = { top: number; bottom: number };

/// The clear rows in `dock` against the view's bottom edge `viewBottom` (client px). A row's hole
/// runs down to the top of the part under it (its card), so the gap between them shows the
/// transcript too.
export function dockClearSpans(dock: ParentNode, viewBottom: number): ClearSpan[] {
  const spans: ClearSpan[] = [];
  for (const row of dock.querySelectorAll<HTMLElement>("[data-dock-clear]")) {
    const box = row.getBoundingClientRect();
    if (box.height <= 0) continue;
    const next = row.nextElementSibling?.getBoundingClientRect().top ?? box.bottom;
    const bottom = Math.max(box.bottom, next);
    spans.push({ top: viewBottom - box.top, bottom: Math.max(0, viewBottom - bottom) });
  }
  return spans.sort((a, b) => b.top - a.top);
}

/// The stops the view mask (conversation.css --acpmux-view-mask) adds past its foot for `spans`:
/// full ink inside each, none between. Empty for none. Leads with a comma, so it follows the
/// gradient's last stop.
export function dockClearStops(spans: readonly ClearSpan[]): string {
  const at = (px: number) => `calc(100% - ${Math.round(px * 10) / 10}px)`;
  return spans
    .map(
      ({ top, bottom }) => `, transparent ${at(top)}, #000 ${at(top)}, #000 ${at(bottom)}, transparent ${at(bottom)}`, // colour-allow: a mask stop, only its alpha counts
    )
    .join("");
}
