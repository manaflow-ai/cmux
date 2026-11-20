// The History list once it is long: only the lines near the viewport are in the DOM (TanStack
// Virtual), with the selected row always among them, so the page's 1,000 entries (PAGE_LIMIT) cost a
// screenful of rows to open, filter or search, not a thousand. A short list keeps its plain sections
// (HistoryPage): the cost only matters past a screenful or two.
import { useLayoutEffect, useMemo, useRef, type ReactNode, type RefObject } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import type { HistoryGroup } from "./model";
import type { HistoryEntry } from "./types";

/** At this many entries the list mounts only the lines in view. */
export const HISTORY_VIRTUAL_FROM = 150;

type Line = { key: string; group: HistoryGroup; entry?: HistoryEntry };

// A first guess before each line is measured: a group's title, a row with its detail line.
const TITLE_HEIGHT = 36;
const ROW_HEIGHT = 40;

export function HistoryLines({
  groups,
  selection,
  title,
  row,
  scroller,
}: {
  groups: readonly HistoryGroup[];
  selection: string | undefined;
  title(group: HistoryGroup): ReactNode;
  row(entry: HistoryEntry): ReactNode;
  /** The scrolling element: HistoryPage owns it with the listbox role and its keys. */
  scroller: RefObject<HTMLDivElement | null>;
}) {
  const lines = useMemo(
    () =>
      groups.flatMap((group): Line[] => [
        { key: `group:${group.id}`, group },
        ...group.entries.map((entry) => ({ key: entry.id, group, entry })),
      ]),
    [groups],
  );
  const selected = selection === undefined ? -1 : lines.findIndex((line) => line.entry?.id === selection);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- the virtualizer is read only here, never passed to a memoized child
  const virtualizer = useVirtualizer({
    count: lines.length,
    getScrollElement: () => scroller.current,
    estimateSize: (index) => (lines[index]?.entry ? ROW_HEIGHT : TITLE_HEIGHT),
    getItemKey: (index) => lines[index]!.key,
    overscan: 8,
    // The selected row stays mounted while it is scrolled away, so the keys that move it never lose it.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (selected >= 0 && !indexes.includes(selected)) {
        indexes.push(selected);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  // A new selection (the arrows, a click) is scrolled into view, once per change.
  const shown = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    if (selected < 0 || shown.current === selection) return;
    shown.current = selection;
    virtualizer.scrollToIndex(selected, { align: "auto" });
  });
  return (
    <div className="history-lines" style={{ height: virtualizer.getTotalSize() }}>
      {virtualizer.getVirtualItems().map((item) => {
        const line = lines[item.index]!;
        return (
          <div
            key={item.key}
            ref={virtualizer.measureElement}
            data-index={item.index}
            className="history-line"
            style={{ transform: `translateY(${item.start}px)` }}
          >
            {line.entry ? row(line.entry) : title(line.group)}
          </div>
        );
      })}
    </div>
  );
}
