// A composer menu's rows past MENU_WINDOW_AT draw only near the menu's viewport (Leo, 2026-11-18:
// "we draw the visible area, right?"). The + menu takes the host's catalog rows and the mode menu
// takes the agent's modes, and neither bounds them. The rows stay in flow between spacers, so the
// menu keeps its width and row CSS, and each mounted row is measured once it draws. A menu at or
// under the bound draws every row as before.
//
// Base UI's menu moves focus across its mounted items only, so a windowed menu takes the keys that
// would stop at the window's edge: the arrows (wrapping), Home, End and typeahead, over every row.
// The focused row stays mounted when the menu scrolls away from it, and the menu opens at its
// current row; a keyboard open focuses that row.
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { defaultRangeExtractor, useVirtualizer, type Range, type Virtualizer } from "@tanstack/react-virtual";
import { focusRoute } from "./focusRoute";

/** Menus with more rows than this draw only the rows near their viewport. */
export const MENU_WINDOW_AT = 50;
/** Base UI's typeahead reset (TYPEAHEAD_RESET_MS). */
const TYPEAHEAD_RESET_MS = 500;
const SCROLLER = ".ui-popup-scroll";
/** The shortest menu row, for how many rows a viewport can hold. */
const MIN_ROW_HEIGHT = 20;
/** A windowed menu row's place in the menu. Only a windowed menu draws it (popupHost keeps such a menu in the page). */
export const ROW_ATTRIBUTE = "data-menu-row";

/** One open windowed menu: where the keyboard is, across its sections. Mutated by events, never read in render. */
export class MenuWindow {
  /** Each section's first row in the menu's order. */
  private starts: number[] = [0];
  total = 0;
  private label: (row: number) => string = () => "";
  /** The menu row that last had focus: it stays mounted. */
  focused = -1;
  /** A row the keyboard moved to before it mounted: it takes focus once drawn. */
  pending: number | undefined;
  /** The row a keyboard open lands on (the current one). */
  private opensAt: number | undefined;
  private settled = false;
  private typed = "";
  private typedFrom = -1;
  private typedTimer: ReturnType<typeof setTimeout> | undefined;
  private scrollers = new Map<number, (index: number) => void>();

  /** The menu's sections (their row counts), row labels for typeahead and the row it opens at. */
  update(sizes: readonly number[], label: (row: number) => string, opensAt: number | undefined) {
    this.starts = sectionStarts(sizes);
    this.total = sizes.reduce((sum, size) => sum + size, 0);
    this.label = label;
    this.opensAt = opensAt;
  }

  private start(section: number): number {
    return this.starts[section] ?? 0;
  }

  private sectionOf(row: number): number {
    let section = 0;
    while (section + 1 < this.starts.length && this.starts[section + 1]! <= row) section++;
    return section;
  }

  /** A section's rows, mounted: it scrolls to its own row `index`. */
  register(section: number, scrollTo: (index: number) => void): () => void {
    this.scrollers.set(section, scrollTo);
    return () => {
      if (this.scrollers.get(section) === scrollTo) this.scrollers.delete(section);
    };
  }

  /** A row took focus. */
  rowFocused(row: number) {
    this.settled = true;
    this.focused = row;
  }

  /**
   * A keyboard open: Base UI highlights its first mounted item and focuses it a frame later, by
   * which time the menu has scrolled to its current row and that item is gone, so focus stayed on
   * the menu button. The row the menu opened at takes it (row 0 when it has no current row).
   */
  settleOpen(scope: HTMLElement) {
    if (this.settled) return;
    const active = scope.ownerDocument.activeElement;
    if (!scope.querySelector("[data-highlighted]") || (active && scope.contains(active))) return;
    this.settled = true;
    this.moveTo(this.opensAt ?? 0, scope);
  }

  /**
   * Focus menu row `row`: at once when it is drawn, else once its section has scrolled to it. The row
   * with focus stays drawn until then (a removed focused row would hand focus to Base UI's recovery).
   */
  moveTo(row: number, scope: HTMLElement) {
    const element = scope.querySelector<HTMLElement>(`[${ROW_ATTRIBUTE}="${row}"]`);
    if (element) {
      this.pending = undefined;
      focusRow(element);
      return;
    }
    this.pending = row;
    const section = this.sectionOf(row);
    this.scrollers.get(section)?.(row - this.start(section));
  }

  /** The keys Base UI would take over the mounted items only. True when it took the key. */
  keyDown(event: KeyboardEvent<HTMLElement>): boolean {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || this.total === 0) return false;
    const scope = event.currentTarget;
    const on = (event.target as Element).closest?.(`[${ROW_ATTRIBUTE}]`);
    // A key before the last one's row has drawn moves on from that row.
    const from = this.pending ?? (on && scope.contains(on) ? Number(on.getAttribute(ROW_ATTRIBUTE)) : -1);
    let target: number | undefined;
    switch (event.key) {
      case "ArrowDown":
        target = from < 0 ? 0 : (from + 1) % this.total;
        break;
      case "ArrowUp":
        target = from < 0 ? this.total - 1 : (from - 1 + this.total) % this.total;
        break;
      case "Home":
        target = 0;
        break;
      case "End":
        target = this.total - 1;
        break;
      default:
        target = this.typeahead(event.key, from);
    }
    if (target === undefined) return false;
    event.preventDefault();
    (event as { preventBaseUIHandler?: () => void }).preventBaseUIHandler?.();
    if (target !== from) this.moveTo(target, scope);
    return true;
  }

  /** Base UI's typeahead (useTypeahead), over every row: the next row whose label starts with what was typed. */
  private typeahead(key: string, from: number): number | undefined {
    if (key.length !== 1 || (key === " " && this.typed === "")) return undefined;
    clearTimeout(this.typedTimer);
    this.typedTimer = setTimeout(() => {
      this.typed = "";
    }, TYPEAHEAD_RESET_MS);
    // The same letter again cycles through the rows it starts.
    const fresh = this.typed === "";
    this.typed = this.typed === key ? key : this.typed + key;
    if (fresh) this.typedFrom = from;
    const query = this.typed.toLowerCase();
    const start = this.typed.length === 1 ? from + 1 : Math.max(this.typedFrom, 0);
    // Stops at the first match; a key with no match walks the rows once, as Base UI's does.
    for (let offset = 0; offset < this.total; offset++) {
      const row = (start + offset) % this.total;
      if (this.label(row).toLowerCase().startsWith(query)) {
        if (this.typed.length === 1) this.typedFrom = row;
        return row;
      }
    }
    if (key !== " ") this.typed = "";
    return key === " " ? from : undefined;
  }

  private swallowSpaceUp = false;

  /**
   * Space while a typeahead string is pending continues it (Base UI's items ignore it then, through
   * Base UI's own typeahead, which a windowed menu replaces), so the row under focus does not act.
   * A document capture listener, ahead of the row's own key handlers.
   */
  spaceKey(event: globalThis.KeyboardEvent) {
    if (event.key !== " ") return;
    if (event.type === "keyup") {
      if (!this.swallowSpaceUp) return;
      this.swallowSpaceUp = false;
    } else {
      const scope = (event.target as Element | null)?.closest?.<HTMLElement>(".ui-popup");
      const on = (event.target as Element).closest?.(`[${ROW_ATTRIBUTE}]`);
      if (this.typed === "" || !scope || !on || !scope.contains(on)) return;
      const from = Number(on.getAttribute(ROW_ATTRIBUTE));
      const target = this.typeahead(" ", from);
      if (target !== undefined && target !== from) this.moveTo(target, scope);
      this.swallowSpaceUp = true;
    }
    event.preventDefault();
    event.stopPropagation();
  }

  /**
   * Base UI keeps the highlighted item as an index among the mounted items, which moves when rows
   * mount or unmount above it: the focused row tells it its place again, so the highlight stays on it.
   */
  resync(scope: HTMLElement) {
    const active = scope.ownerDocument.activeElement as HTMLElement | null;
    const row = active?.parentElement;
    if (!active || !row?.hasAttribute(ROW_ATTRIBUTE) || !scope.contains(row) || active.hasAttribute("data-highlighted"))
      return;
    active.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
  }

  /** The menu closed: the next open starts afresh. */
  reset() {
    clearTimeout(this.typedTimer);
    this.typed = "";
    this.focused = -1;
    this.pending = undefined;
    this.settled = false;
    this.swallowSpaceUp = false;
  }
}

/** The person's key (an arrow, Home, End, typeahead or a keyboard open) moves to this row. */
function focusRow(element: HTMLElement) {
  const item = element.firstElementChild as HTMLElement | null;
  focusRoute(item, "person", "a key moved through a long menu: the row it names", { preventScroll: true });
  element.scrollIntoView({ block: "nearest" });
}

/**
 * The menu's window state, or `undefined` for a menu at or under MENU_WINDOW_AT rows (it draws them
 * all). Whether a menu windows does not follow `open`, so a closing menu does not draw every row in
 * its fade; each open starts afresh.
 */
export function useMenuWindow(
  open: boolean,
  sizes: readonly number[],
  label: (row: number) => string,
  opensAt: number | undefined,
): MenuWindow | undefined {
  const [menu] = useState(() => new MenuWindow());
  const total = sizes.reduce((sum, size) => sum + size, 0);
  useLayoutEffect(() => {
    menu.update(sizes, label, opensAt);
  });
  useLayoutEffect(() => {
    if (!open) return;
    const space = (event: globalThis.KeyboardEvent) => menu.spaceKey(event);
    document.addEventListener("keydown", space, true);
    document.addEventListener("keyup", space, true);
    return () => {
      document.removeEventListener("keydown", space, true);
      document.removeEventListener("keyup", space, true);
      menu.reset();
    };
  }, [open, menu]);
  return total > MENU_WINDOW_AT ? menu : undefined;
}

/** Each section's first row in the menu's order. */
export function sectionStarts(sizes: readonly number[]): number[] {
  const starts: number[] = [];
  let next = 0;
  for (const size of sizes) {
    starts.push(next);
    next += size;
  }
  return starts;
}

const ROW_STYLE = Object.freeze({ display: "flow-root" });

/**
 * One section's rows in a windowed menu: those within a viewport of the menu's viewport each side,
 * and the focused row. `row(index)` draws row `index` (a memoized row, so a row that stays mounted
 * does not draw again as the menu scrolls).
 */
export function MenuWindowRows({
  menu,
  section,
  start,
  count,
  estimate,
  opensAt,
  row,
}: {
  menu: MenuWindow;
  section: number;
  /** The section's first row in the menu's order (sectionStarts). */
  start: number;
  count: number;
  /** A row's height before it is measured. */
  estimate: number;
  /** This section's row the menu opens scrolled to. */
  opensAt?: number;
  row(index: number): ReactNode;
}) {
  const top = useRef<HTMLDivElement | null>(null);
  const [margin, setMargin] = useState(0);
  const [viewport, setViewport] = useState(0);
  const scroller = useCallback(() => top.current?.closest<HTMLElement>(SCROLLER) ?? null, []);
  // The virtualizer, for the range to read its place (set after the first draw, which has no viewport).
  const [self] = useState<{ current?: Virtualizer<HTMLElement, Element> }>(() => ({}));
  // The rows within one viewport of the visible ones, by their measured place: a section wholly out of
  // that band draws none (TanStack's count overscan would draw its first rows). The focused row stays
  // drawn, so focus is never on a removed element.
  const rangeExtractor = useCallback(
    (range: Range) => {
      let indexes = defaultRangeExtractor(range);
      const virtualizer = self.current;
      const height = virtualizer?.scrollRect?.height ?? 0;
      if (virtualizer && height > 0) {
        const offset = virtualizer.scrollOffset ?? 0;
        const measurements = virtualizer.measurementsCache;
        indexes = indexes.filter((index) => {
          const item = measurements[index];
          return item !== undefined && item.end > offset - height && item.start < offset + 2 * height;
        });
      }
      const focused = menu.focused - start;
      if (focused >= 0 && focused < count && !indexes.includes(focused)) {
        indexes.push(focused);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
    [menu, start, count, self],
  );
  const virtualizer = useVirtualizer({
    count,
    getScrollElement: scroller,
    estimateSize: () => estimate,
    // Enough rows for a viewport each side at the smallest row; the range keeps those within one.
    overscan: Math.max(1, Math.ceil(viewport / MIN_ROW_HEIGHT)),
    scrollMargin: margin,
    rangeExtractor,
  });
  // Where the rows start in the scroller, and the scroller's height: measured when they mount and when
  // the scroller or a section in it changes size (one observer per list, never one per row).
  useLayoutEffect(() => {
    const element = scroller();
    if (!element) return;
    const measure = () => {
      if (!top.current) return;
      const next = top.current.getBoundingClientRect().top - element.getBoundingClientRect().top + element.scrollTop;
      setMargin((old) => (Math.abs(old - next) < 0.5 ? old : next));
      setViewport((old) => (old === element.clientHeight ? old : element.clientHeight));
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    for (const child of element.children) observer.observe(child);
    return () => observer.disconnect();
  }, [scroller, start]);
  useLayoutEffect(() => {
    self.current = virtualizer;
  }, [self, virtualizer]);
  useEffect(
    () => menu.register(section, (index) => virtualizer.scrollToIndex(index, { align: "auto" })),
    [menu, section, virtualizer],
  );
  // Open at the current row.
  const opened = useRef(false);
  useLayoutEffect(() => {
    if (opened.current || viewport === 0) return;
    opened.current = true;
    if (opensAt !== undefined && opensAt >= 0) virtualizer.scrollToIndex(opensAt, { align: "center" });
  }, [opensAt, viewport, virtualizer]);
  // A row the keyboard moved to before it was drawn takes focus once it is, the frame after Base UI has
  // counted it among its items (its index is the highlight); and the focused row keeps the highlight
  // when rows above it come and go.
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      const scope = top.current?.closest<HTMLElement>(".ui-popup");
      if (!scope) return;
      const pending = menu.pending;
      if (pending !== undefined && pending >= start && pending < start + count) {
        const element = scope.querySelector<HTMLElement>(`[${ROW_ATTRIBUTE}="${pending}"]`);
        if (element) {
          menu.pending = undefined;
          focusRow(element);
          return;
        }
      }
      menu.settleOpen(scope);
      menu.resync(scope);
    });
    return () => cancelAnimationFrame(frame);
  });
  const items = virtualizer.getVirtualItems();
  const rows: ReactNode[] = [];
  let cursor = margin;
  for (const item of items) {
    if (rows.length > 0 && item.start > cursor)
      rows.push(<div key={`gap-${item.index}`} aria-hidden="true" style={{ height: item.start - cursor }} />);
    rows.push(
      <div
        key={item.index}
        data-index={item.index}
        {...{ [ROW_ATTRIBUTE]: start + item.index }}
        ref={virtualizer.measureElement}
        style={ROW_STYLE}
        onFocus={() => menu.rowFocused(start + item.index)}
      >
        {row(item.index)}
      </div>,
    );
    cursor = item.end;
  }
  const first = items[0]?.start ?? margin;
  const end = virtualizer.getTotalSize() + margin;
  return (
    <>
      <div ref={top} aria-hidden="true" style={{ height: Math.max(0, first - margin) }} />
      {rows}
      <div aria-hidden="true" style={{ height: Math.max(0, end - cursor) }} />
    </>
  );
}
