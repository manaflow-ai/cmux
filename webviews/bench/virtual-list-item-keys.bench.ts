/// <reference types="bun" />
// l10n-allow-file: bench output labels, not shipped UI.

/**
 * Model-only bench for VirtualList's measured rows (the Tasks board's cards) when the list changes under them.
 *
 * TanStack Virtual keeps each measured row height by the row's key, and the key is the index unless the list gives
 * `getItemKey` (https://tanstack.com/virtual/latest/docs/api/virtualizer#getitemkey). When a card leaves a column
 * (moved, done, filtered) or the column is reordered, index keys hand every later card the height of the card that
 * used to sit at its index. So the first frame places those cards wrong, and they jump once they are measured again.
 * With item keys each card keeps its own height.
 *
 * It runs TanStack's own virtualizer (no DOM), measures every card, applies the change, and counts the cards whose
 * place before re-measuring differs from their real place, in the first viewport (800 px) and in the whole column.
 *
 *   bun bench/virtual-list-item-keys.bench.ts
 *   CARDS=500 bun bench/virtual-list-item-keys.bench.ts
 */
import { Virtualizer, type VirtualizerOptions } from "@tanstack/virtual-core";

const cards = Number(process.env.CARDS ?? 200);
if (!Number.isSafeInteger(cards) || cards < 4) throw new Error("CARDS must be an integer of at least 4");
const VIEWPORT = 800;

// Card heights as the board draws them: one to three title lines, with or without a session progress row.
let seed = 7;
const random = () => (seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31;
type Card = { id: string; height: number };
const column: Card[] = Array.from({ length: cards }, (_, index) => ({
  id: `task-${index}`,
  height: 72 + 20 * Math.floor(random() * 3) + (random() < 0.4 ? 28 : 0),
}));

function virtualizer(rows: Card[], keyed: boolean): Virtualizer<HTMLElement, HTMLElement> {
  const options: VirtualizerOptions<HTMLElement, HTMLElement> = {
    count: rows.length,
    getScrollElement: () => null,
    estimateSize: () => 96,
    scrollToFn: () => {},
    observeElementRect: () => undefined,
    observeElementOffset: () => undefined,
    ...(keyed ? { getItemKey: (index: number) => rows[index]!.id } : {}),
  };
  const v = new Virtualizer(options);
  return v;
}

function misplaced(rows: Card[], keyed: boolean, change: (rows: Card[]) => Card[]) {
  const v = virtualizer(rows, keyed);
  // resizeItem ignores an index the virtualizer has not placed yet, so place them all first, as the first render
  // does; then check every height took, or the bench would compare two unmeasured columns.
  v.getTotalSize();
  rows.forEach((card, index) => v.resizeItem(index, card.height));
  const measured = rows.reduce((sum, card) => sum + card.height, 0);
  if (v.getTotalSize() !== measured) throw new Error(`measured ${v.getTotalSize()} px, cards add up to ${measured} px`);
  const next = change(rows);
  v.setOptions({ ...v.options, count: next.length, ...(keyed ? { getItemKey: (index) => next[index]!.id } : {}) });
  v.getTotalSize();
  let truth = 0;
  let inView = 0;
  let all = 0;
  let maxPx = 0;
  next.forEach((card, index) => {
    const shown = v.measurementsCache[index]!;
    const off = Math.abs(shown.start - truth) + Math.abs(shown.size - card.height);
    if (off > 0) {
      all++;
      if (truth < VIEWPORT) inView++;
      maxPx = Math.max(maxPx, Math.abs(shown.start - truth));
    }
    truth += card.height;
  });
  return { cards_misplaced_in_view: inView, cards_misplaced: all, max_offset_px: maxPx };
}

const changes: Record<string, (rows: Card[]) => Card[]> = {
  top_card_moved_out: (rows) => rows.slice(1),
  card_in_view_moved_out: (rows) => rows.filter((_, index) => index !== 3),
  top_card_moved_to_bottom: (rows) => [...rows.slice(1), rows[0]!],
  filtered_to_every_other: (rows) => rows.filter((_, index) => index % 2 === 0),
};

const report: Record<string, unknown> = {
  cards,
  viewport_px: VIEWPORT,
  engine: `bun ${Bun.version} (JavaScriptCore)`,
  scope: "model-only: TanStack virtual-core placement before re-measure; no React, DOM or frame claim",
};
let indexInView = 0;
let keyInView = 0;
for (const [name, change] of Object.entries(changes)) {
  const before = misplaced(column, false, change);
  const after = misplaced(column, true, change);
  indexInView += before.cards_misplaced_in_view;
  keyInView += after.cards_misplaced_in_view;
  report[name] = { index_keys: before, item_keys: after };
}
report.all_cards_misplaced_in_view = { index_keys: indexInView, item_keys: keyInView };
console.log(JSON.stringify(report, null, 2));
