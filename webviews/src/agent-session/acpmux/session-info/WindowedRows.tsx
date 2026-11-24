// A Session Info list opened to any length costs the same: it mounts only the rows in view and an
// overscan of a viewport above and under them, holds the room of the rows it leaves out in a box above
// and a box under them (so the list and the panel's scroll take their whole height at once), and
// moves that window as the list scrolls, removing the rows that leave it (Leo, 2026-11-06: "If I open
// up this 5,427 finished, it'll lag"; 2026-11-18: "we draw the visible area, right? Like, that's what
// we're supposed to do"). The same rule as the transcript's opened runs (conversation/ToolGroupRow.tsx
// StepList).
//
// The keyboard reaches every row without mounting them all: the row focus is in stays mounted wherever
// the scroll goes, Tab from the last mounted row (Shift-Tab from the first) mounts the row focus goes
// to, and Shift-Tab into the list from below (Tab from above) mounts its true last (first) row's window.
// A row's memo boundary is its own component (what `render` returns, with stable props): moving the
// window renders the rows that come into it and none of those that stay.
//
// The press that opens a list mounts the rows that can show and FIRST_PAINT_OVERSCAN_ROWS under them,
// in one commit, and keeps them while they hold the view; the viewports of overscan apply from its
// first scroll. So the open's frame mounts no row only to remove it before paint, and no more rows
// than the grow-only list it replaced.
import { useLayoutEffect, useRef, useState, type Key, type ReactElement, type ReactNode, type RefObject } from "react";

/// The least height a list row draws at, in px: the rows a window can show are its height over this.
const ROW_MIN_PX = 24;
/// The rows mounted past each edge of the view, in viewports (a list may declare up to the most).
export const OVERSCAN_VIEWS = 1;
export const MAX_OVERSCAN_VIEWS = 2;

/// The rows mounted past the view's edge from a list's open until its first scroll.
export const FIRST_PAINT_OVERSCAN_ROWS = 8;

/// The rows a list mounts at its open, for a window `viewHeight` px tall: as many as can show and
/// FIRST_PAINT_OVERSCAN_ROWS under them (a list opens at its top).
export function firstRowCount(viewHeight: number): number {
  return Math.max(1, Math.ceil(viewHeight / ROW_MIN_PX)) + FIRST_PAINT_OVERSCAN_ROWS;
}

/// What the keyboard can focus in a row.
const FOCUSABLE = 'button:not([disabled]), a[href], input, select, textarea, [tabindex]:not([tabindex="-1"])';

const viewHeight = () => (typeof window === "undefined" ? 800 : window.innerHeight || 800);

/// The elements that scroll the rows of list `node`, nearest first: the list itself when it scrolls
/// (Outputs' and the ended subagents' capped lists), then its ancestors that do. A row shows where all
/// of them show it.
function scrollersOf(node: Element): HTMLElement[] {
  const view = node.ownerDocument.defaultView;
  const scrollers: HTMLElement[] = [];
  for (let at: Element | null = node; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll") scrollers.push(at as HTMLElement);
  }
  return scrollers;
}

const focusables = (row: Element): HTMLElement[] =>
  row.matches(FOCUSABLE) ? [row as HTMLElement] : [...row.querySelectorAll<HTMLElement>(FOCUSABLE)];

const keyOf = (node: ReactNode): Key | null =>
  node !== null && typeof node === "object" && "key" in node ? (node as ReactElement).key : null;

type Range = { start: number; end: number };
/// The row focus is in, kept mounted while it is the same row (its key).
type Pin = { index: number; key: Key | null };
/// A row to focus once it mounts: its first focusable (Tab came to it) or its last (Shift-Tab).
type Pending = { index: number; edge: "first" | "last" };

/// `items` drawn by `render` as the rows of the list it sits in (a `<ul>`'s `<li>`s): the rows in view
/// and `overscan` viewports of rows either side, between boxes (`li[data-rows-rest]`) as tall as the
/// rows left out. A list that fits draws as it did, every row and no box. A windowed list's rows carry
/// `aria-setsize` and `aria-posinset`, so a screen reader reads each row's place in the whole list.
export function WindowedRows<T>({
  items,
  render,
  overscan = OVERSCAN_VIEWS,
}: {
  items: readonly T[];
  render: (item: T, index: number) => ReactNode;
  /// Viewports of rows mounted past each edge of the view (default one, at most two).
  overscan?: number;
}) {
  const views = Math.min(MAX_OVERSCAN_VIEWS, Math.max(0, overscan));
  const total = items.length;
  const opening = firstRowCount(viewHeight());
  const [range, setRange] = useState<Range>(() => ({ start: 0, end: opening }));
  const [pin, setPin] = useState<Pin | null>(null);
  // A list that fits mounts every row, with no box and no listener; folded back to fit, it opens again
  // at its top, with the open's rows (its overscan grows again at its next first scroll).
  const windowed = total > opening;
  if (!windowed && (range.start !== 0 || range.end !== opening)) setRange({ start: 0, end: opening });
  let { start, end } = windowed ? range : { start: 0, end: total };
  // A list that lost rows keeps its window's size, at its end.
  if (end > total) {
    start = Math.max(0, total - (end - start));
    end = total;
  }
  // The row focus is in, while it is still that row, where it falls outside the window.
  let kept: { index: number; node: ReactNode } | null = null;
  if (windowed && pin && pin.index < total && (pin.index < start || pin.index >= end)) {
    const node = render(items[pin.index]!, pin.index);
    if (keyOf(node) === pin.key) kept = { index: pin.index, node };
  }

  const top = useRef<HTMLLIElement>(null);
  const gap = useRef<HTMLLIElement>(null);
  const bottom = useRef<HTMLLIElement>(null);
  const list = useRef<HTMLElement | null>(null);
  const pitch = useRef(ROW_MIN_PX);
  const pending = useRef<Pending | null>(null);
  // Whether the list has scrolled (or resized) since it opened: the viewports of overscan apply from then.
  const settled = useRef(false);
  // The window the boxes were last sized for (its start, end, length and kept row).
  const sized = useRef("");
  // The keys of the mounted rows by place, for the row focus comes to.
  const keys = useRef(new Map<number, Key | null>());
  // What the listeners read: the window as it is in the last commit.
  const now = useRef({ start, end, total, kept: kept?.index, views });
  now.current = { start, end, total, kept: kept?.index, views };

  /// The first mounted row of the window (after the kept row above it, if there is one).
  const windowLead = () => {
    const at = now.current;
    return ((at.kept !== undefined && at.kept < at.start ? gap.current : top.current)?.nextElementSibling ??
      null) as HTMLElement | null;
  };
  /// The mounted row at `index`, if it is mounted.
  const rowAt = (index: number): HTMLElement | null => {
    const at = now.current;
    if (at.kept === index)
      return ((at.kept < at.start ? top.current : gap.current)?.nextElementSibling ?? null) as HTMLElement | null;
    if (index < at.start || index >= at.end) return null;
    let row: Element | null = windowLead();
    for (let step = at.start; row && step < index; step += 1) row = row.nextElementSibling;
    return row as HTMLElement | null;
  };
  /// A row element's place in `items`: the box before it names the row after it.
  const indexOf = (row: Element): number | undefined => {
    let steps = 0;
    let at = row.previousElementSibling;
    while (at && !at.hasAttribute("data-rows-next")) {
      steps += 1;
      at = at.previousElementSibling;
    }
    const next = at?.getAttribute("data-rows-next");
    if (!next || next === "end") return undefined;
    const index = Number(next) + steps;
    return index < now.current.total ? index : undefined;
  };

  // Each commit: the boxes' heights at the rows' pitch (measured again when the window moved, so a
  // parent's render that keeps the window reads no layout), each row's place for a screen reader, and
  // the row the keyboard was sent to focused (its scroll into view measures the view again).
  useLayoutEffect(() => {
    if (!windowed) {
      settled.current = false;
      sized.current = "";
      // Folded back to fit: every row is mounted again, in its own place.
      if (list.current) {
        for (const row of list.current.children) {
          row.removeAttribute("aria-setsize");
          row.removeAttribute("aria-posinset");
        }
        list.current = null;
      }
      return;
    }
    list.current = top.current?.parentElement ?? null;
    const first = kept && kept.index < start ? gap.current : top.current;
    const last = kept && kept.index >= end ? gap.current : bottom.current;
    const lead = first?.nextElementSibling;
    const tail = last?.previousElementSibling;
    const shape = `${start} ${end} ${total} ${kept?.index ?? ""}`;
    const moved = shape !== sized.current;
    sized.current = shape;
    if (moved && lead && tail && lead !== last && end > start) {
      const measured = (tail.getBoundingClientRect().bottom - lead.getBoundingClientRect().top) / (end - start);
      // jsdom draws no boxes: the least row height stands in.
      if (measured > 1) pitch.current = measured;
    }
    const size = (element: HTMLLIElement | null, rows: number) => {
      if (!element) return;
      element.style.height = `${Math.max(0, rows) * pitch.current}px`;
      element.style.display = rows > 0 ? "" : "none";
    };
    if (!moved) {
      // The same window: the boxes keep their heights.
    } else if (kept && kept.index < start) {
      size(top.current, kept.index);
      size(gap.current, start - kept.index - 1);
      size(bottom.current, total - end);
    } else if (kept) {
      size(top.current, start);
      size(gap.current, kept.index - end);
      size(bottom.current, total - kept.index - 1);
    } else {
      size(top.current, start);
      size(bottom.current, total - end);
    }
    // The list's whole length and each mounted row's place in it, the same list's rows drawn before
    // and after these counted in.
    if (top.current && bottom.current) {
      const before: Element[] = [];
      for (let at = top.current.previousElementSibling; at; at = at.previousElementSibling) before.unshift(at);
      const after: Element[] = [];
      for (let at = bottom.current.nextElementSibling; at; at = at.nextElementSibling) after.push(at);
      const setSize = String(before.length + total + after.length);
      // Written only where a row's place changed: a scroll step writes the rows it mounts.
      const place = (row: Element | null | undefined, position: number) => {
        if (!row) return;
        const posinset = String(position);
        if (row.getAttribute("aria-setsize") !== setSize) row.setAttribute("aria-setsize", setSize);
        if (row.getAttribute("aria-posinset") !== posinset) row.setAttribute("aria-posinset", posinset);
      };
      before.forEach((row, index) => place(row, index + 1));
      after.forEach((row, index) => place(row, before.length + total + index + 1));
      if (kept) place(rowAt(kept.index), before.length + kept.index + 1);
      let row = lead && lead !== last ? lead : null;
      for (let index = start; row && index < end; index += 1, row = row.nextElementSibling) {
        place(row, before.length + index + 1);
      }
    }
    const wanted = pending.current;
    if (wanted) {
      const row = rowAt(wanted.index);
      if (row) {
        pending.current = null;
        const targets = focusables(row);
        (wanted.edge === "first" ? targets[0] : targets[targets.length - 1])?.focus();
      }
    }
  });

  // The view, the scroll and the keyboard, while the list leaves rows out.
  useLayoutEffect(() => {
    const host = top.current?.parentElement;
    if (!windowed || !host) return;
    const scrollers = scrollersOf(host);
    /// The window for the view now: the rows it shows and the overscan either side. Reads one row's
    /// box and each scroller's, never the rows'.
    const measure = () => {
      const at = now.current;
      const lead = windowLead();
      if (!lead || lead === bottom.current || lead === gap.current) return;
      let viewTop = 0;
      let viewBottom = viewHeight();
      for (const scroller of scrollers) {
        const box = scroller.getBoundingClientRect();
        // jsdom draws no boxes: a scroller with no height bounds nothing.
        if (box.height <= 0) continue;
        viewTop = Math.max(viewTop, box.top);
        viewBottom = Math.min(viewBottom, box.bottom);
      }
      if (viewBottom <= viewTop) return;
      const origin = lead.getBoundingClientRect().top - at.start * pitch.current;
      const clamp = (value: number) => Math.max(0, Math.min(at.total, value));
      const first = clamp(Math.floor((viewTop - origin) / pitch.current));
      const last = clamp(Math.ceil((viewBottom - origin) / pitch.current));
      // Until the first scroll, a window that holds the rows in view stays as it is: the open's frame
      // mounts no row only to remove it again.
      if (!settled.current && at.start <= first && at.end >= last) return;
      const over = settled.current
        ? Math.ceil((at.views * (viewBottom - viewTop)) / pitch.current)
        : FIRST_PAINT_OVERSCAN_ROWS;
      const next = { start: clamp(first - over), end: clamp(last + over) };
      if (next.end > next.start && (next.start !== at.start || next.end !== at.end)) setRange(next);
    };
    measure();
    /// A scroll or a resize: from now the window holds the viewports of overscan.
    const moved = () => {
      settled.current = true;
      measure();
    };
    /// Mounts row `index` in a window of the same size and focuses it once it is there.
    const reach = (index: number, edge: Pending["edge"]) => {
      const at = now.current;
      const size = at.end - at.start;
      const from = Math.max(0, Math.min(edge === "first" ? index - size + 1 : index, at.total - size));
      pending.current = { index, edge };
      setPin(null);
      setRange({ start: from, end: Math.min(at.total, from + size) });
    };
    const mountedEdges = () => {
      const at = now.current;
      return {
        first: at.kept !== undefined ? Math.min(at.kept, at.start) : at.start,
        last: at.kept !== undefined ? Math.max(at.kept, at.end - 1) : at.end - 1,
      };
    };
    /// Where `node` is against the windowed rows, which lie between the box above them and the box under
    /// them (the rows of the same list outside those boxes are not theirs).
    const precedesRows = (node: Node) =>
      !!top.current && !!(top.current.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_PRECEDING);
    const followsRows = (node: Node) =>
      !!bottom.current &&
      node !== bottom.current &&
      !!(bottom.current.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING);
    const withinRows = (node: Node) => host.contains(node) && !precedesRows(node) && !followsRows(node);
    const focusIn = (event: FocusEvent) => {
      const row = (event.target as Element | null)?.closest?.("li");
      if (!row || row.parentElement !== host) return;
      const index = indexOf(row);
      if (index === undefined) return;
      const at = now.current;
      const edges = mountedEdges();
      const from = event.relatedTarget as Node | null;
      // Shift-Tab from what follows the rows lands on their true last row, Tab from what precedes them
      // on their true first row: that row's window mounts, not every row. What precedes or follows
      // them may sit in the same list (the summary card's rows before its chats, SubagentStatusList).
      if (from && !withinRows(from)) {
        if (followsRows(from) && index === edges.last && index < at.total - 1) {
          reach(at.total - 1, "last");
          return;
        }
        if (precedesRows(from) && index === edges.first && index > 0) {
          reach(0, "first");
          return;
        }
      }
      setPin({ index, key: keys.current.get(index) ?? null });
    };
    const focusOut = (event: FocusEvent) => {
      const to = event.relatedTarget as Node | null;
      if (!to || !withinRows(to)) setPin(null);
    };
    const keyDown = (event: KeyboardEvent) => {
      if (event.key !== "Tab" || event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
      const target = event.target as HTMLElement | null;
      const row = target?.closest?.("li");
      if (!target || !row || row.parentElement !== host) return;
      const index = indexOf(row);
      if (index === undefined) return;
      const targets = focusables(row);
      const edges = mountedEdges();
      if (!event.shiftKey) {
        if (index !== edges.last || index >= now.current.total - 1 || targets[targets.length - 1] !== target) return;
        event.preventDefault();
        reach(index + 1, "first");
      } else {
        if (index !== edges.first || index <= 0 || targets[0] !== target) return;
        event.preventDefault();
        reach(index - 1, "last");
      }
    };
    const scrolled: EventTarget[] = [...scrollers, window];
    for (const target of scrolled) target.addEventListener("scroll", moved, { passive: true });
    window.addEventListener("resize", moved);
    // A panel that changes height without the window: one observer, on the nearest scroller.
    const resized = scrollers[0] && typeof ResizeObserver !== "undefined" ? new ResizeObserver(measure) : null;
    if (scrollers[0]) resized?.observe(scrollers[0]);
    host.addEventListener("focusin", focusIn);
    host.addEventListener("focusout", focusOut);
    host.addEventListener("keydown", keyDown);
    return () => {
      for (const target of scrolled) target.removeEventListener("scroll", moved);
      window.removeEventListener("resize", moved);
      resized?.disconnect();
      host.removeEventListener("focusin", focusIn);
      host.removeEventListener("focusout", focusOut);
      host.removeEventListener("keydown", keyDown);
    };
    // The listeners read the window through `now`: set up once while the list leaves rows out.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [windowed]);

  if (!windowed) return <>{items.map(render)}</>;
  keys.current.clear();
  const box = (key: string, next: number | "end", ref: RefObject<HTMLLIElement | null>) => (
    <li
      key={key}
      ref={ref}
      className="acpmux-session-info-rows-rest"
      data-rows-rest=""
      data-rows-next={next}
      aria-hidden
    />
  );
  const rows: ReactNode[] = [];
  if (kept && kept.index < start) {
    keys.current.set(kept.index, keyOf(kept.node));
    rows.push(box("\u0000rows-top", kept.index, top), kept.node, box("\u0000rows-gap", start, gap));
  } else {
    rows.push(box("\u0000rows-top", start, top));
  }
  for (let index = start; index < end; index += 1) {
    const node = render(items[index]!, index);
    keys.current.set(index, keyOf(node));
    rows.push(node);
  }
  if (kept && kept.index >= end) {
    keys.current.set(kept.index, keyOf(kept.node));
    rows.push(box("\u0000rows-gap-under", kept.index, gap), kept.node);
  }
  rows.push(box("\u0000rows-bottom", "end", bottom));
  return <>{rows}</>;
}
