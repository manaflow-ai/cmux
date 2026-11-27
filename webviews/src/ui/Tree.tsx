// A focusable tree (a file tree): one Tab stop, Up/Down/Home/End move, Right opens a folder and then
// steps into it, Left closes it and then steps to its parent, Return or Space activates, and typing
// selects the next row whose text starts with it. A click selects and toggles a folder; a double
// click activates a leaf. The caller owns the selection and which folders are open; notes (a folder's
// "loading" or "empty" line) sit between rows but are never selected. Base UI 1.8 has no tree, so
// this is the wrapper's one implementation (aria-activedescendant), as Listbox is for lists.
//
// The lines are windowed (TanStack Virtual): only those near the viewport, about one viewport each
// side, are mounted, plus the selected row so `aria-activedescendant` always names one. The tree
// scrolls itself when its styles let it, else it windows against the closest scrolling ancestor.
// Rows are memoized on their line and selection with stable handlers, and sit in the flow, so a
// selection draws two rows and a scroll draws only the rows it brings in; a caller that keeps
// unchanged lines' objects (`useTreeLineCache`) has a change to one line draw that row alone. Keys
// find the selection, its parent and a typed name by indexes built once per `lines`, not by a scan.
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../agent-session/acpmux/stableHandlers";
import { cx } from "./cx";

export interface TreeItem {
  kind: "item";
  key: string;
  /** 0 for the root's children. */
  depth: number;
  /** The text typeahead matches. */
  text: string;
  expandable: boolean;
  expanded: boolean;
  content: ReactNode;
}

export interface TreeNote {
  kind: "note";
  key: string;
  content: ReactNode;
}

export type TreeLine = TreeItem | TreeNote;

export interface TreeProps {
  /** Every visible line, in order. */
  lines: readonly TreeLine[];
  selected?: string;
  label: string;
  onSelect(key: string): void;
  onExpand(key: string, open: boolean): void;
  onActivate(item: TreeItem): void;
  /** Takes focus when it mounts and whenever its window comes forward. */
  autoFocus?: boolean;
  className?: string;
  rowClassName?: string;
  rowStyle?(item: TreeItem): CSSProperties;
}

const TYPEAHEAD_RESET_MS = 600;
/** A line's height before the first of its kind is measured (the pages' rows are 24 to 28 px). */
const LINE_ESTIMATE = 26;
/** About one viewport of lines above and below the visible ones. */
const OVERSCAN = 20;

/** What `lines` says, read once per `lines` so no key press or row reads every line. */
interface TreeModel {
  items: TreeItem[];
  /** An item's place in `items`, and a line's in `lines`, by key. */
  itemIndex: Map<string, number>;
  lineIndex: Map<string, number>;
  /** Per item: its parent's index in `items` (-1 at the top), and its place among its siblings. */
  parent: Int32Array;
  position: Int32Array;
  siblings: Int32Array;
  /** The items by lowercased text then order, for typeahead; built on the first typed key. */
  byText?: { text: string; index: number }[];
}

function treeModel(lines: readonly TreeLine[]): TreeModel {
  const items: TreeItem[] = [];
  const itemIndex = new Map<string, number>();
  const lineIndex = new Map<string, number>();
  lines.forEach((line, index) => {
    lineIndex.set(line.key, index);
    if (line.kind !== "item") return;
    itemIndex.set(line.key, items.length);
    items.push(line);
  });
  const parent = new Int32Array(items.length);
  const position = new Int32Array(items.length);
  const siblings = new Int32Array(items.length);
  // Children counted under each parent (at its index + 1; 0 counts the top level).
  const children = new Int32Array(items.length + 1);
  const ancestors: number[] = [];
  items.forEach((item, index) => {
    while (ancestors.length && items[ancestors.at(-1)!]!.depth >= item.depth) ancestors.pop();
    const up = ancestors.at(-1) ?? -1;
    parent[index] = up;
    position[index] = ++children[up + 1]!;
    ancestors.push(index);
  });
  for (let index = 0; index < items.length; index++) siblings[index] = children[parent[index]! + 1]!;
  return { items, itemIndex, lineIndex, parent, position, siblings };
}

/** The first item from `start` on (wrapping) whose text starts with `text`, else -1. */
function typedMatch(model: TreeModel, text: string, start: number): number {
  model.byText ??= model.items
    .map((item, index) => ({ text: item.text.toLowerCase(), index }))
    .sort((a, b) => (a.text < b.text ? -1 : a.text > b.text ? 1 : a.index - b.index));
  const sorted = model.byText;
  let low = 0;
  let high = sorted.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (sorted[middle]!.text < text) low = middle + 1;
    else high = middle;
  }
  // The texts that start with `text` sort together from `low`.
  let after = -1;
  let first = -1;
  for (let at = low; at < sorted.length && sorted[at]!.text.startsWith(text); at++) {
    const { index } = sorted[at]!;
    if (first < 0 || index < first) first = index;
    if (index >= start && (after < 0 || index < after)) after = index;
  }
  return after >= 0 ? after : first;
}

/** The closest element from `node` up that scrolls vertically: the tree's viewport. */
function scrollParentOf(node: HTMLElement): HTMLElement {
  for (let at: HTMLElement | null = node; at; at = at.parentElement) {
    const overflow = at.ownerDocument.defaultView?.getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  // Nothing scrolls: the tree is its own viewport, as tall as its lines, and mounts them all.
  return node;
}

export function Tree({
  lines,
  selected,
  label,
  onSelect,
  onExpand,
  onActivate,
  autoFocus = true,
  className,
  rowClassName,
  rowStyle,
}: TreeProps) {
  const element = useRef<HTMLDivElement>(null);
  const viewport = useRef<HTMLElement | null>(null);
  const typed = useRef({ text: "", at: 0 });
  const id = useId();
  const rowId = (key: string) => `${id}-${encodeURIComponent(key)}`;
  const model = useMemo(() => treeModel(lines), [lines]);
  const { items } = model;
  const index = selected === undefined ? -1 : (model.itemIndex.get(selected) ?? -1);
  const current = index >= 0 ? items[index] : undefined;
  const selectedLine = current ? model.lineIndex.get(current.key)! : -1;

  useEffect(() => {
    if (!autoFocus) return;
    const focus = () => element.current?.focus({ preventScroll: true });
    focus();
    window.addEventListener("focus", focus);
    return () => window.removeEventListener("focus", focus);
  }, [autoFocus]);

  // Where the lines start in the viewport's content: the tree's own top padding, plus what sits
  // above the tree in a scrolling ancestor. It moves only when a box between them resizes.
  const [scrollMargin, setScrollMargin] = useState(0);
  const findViewport = useCallback(() => {
    if (!viewport.current && element.current) viewport.current = scrollParentOf(element.current);
    return viewport.current;
  }, []);
  const measureMargin = useCallback(() => {
    const scroller = findViewport();
    const tree = element.current;
    if (!scroller || !tree) return;
    const padding = parseFloat(tree.ownerDocument.defaultView?.getComputedStyle(tree).paddingTop ?? "") || 0;
    const next =
      tree === scroller
        ? padding
        : tree.getBoundingClientRect().top -
          scroller.getBoundingClientRect().top +
          scroller.scrollTop -
          scroller.clientTop +
          tree.clientTop +
          padding;
    setScrollMargin((previous) => (previous === next ? previous : next));
  }, [findViewport]);
  useLayoutEffect(() => {
    measureMargin();
    const scroller = findViewport();
    if (!scroller || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureMargin);
    for (let node: HTMLElement | null = element.current; node; node = node.parentElement) {
      observer.observe(node);
      if (node === scroller) break;
    }
    return () => observer.disconnect();
  }, [findViewport, measureMargin]);

  // One function per `lines`: TanStack measures every line again when it changes.
  const lineKey = useCallback((at: number) => lines[at]!.key, [lines]);
  // The first mounted line of each kind sizes every one not yet mounted, so the lines a scroll
  // brings in measure as estimated: TanStack places all N lines again whenever a measure differs.
  const sizes = useRef(new Map<TreeLine["kind"], number>());
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns a mutable instance, so the React Compiler skips this component, as in ui/VirtualList.
  const virtualizer = useVirtualizer({
    count: lines.length,
    getScrollElement: findViewport,
    scrollMargin,
    estimateSize: (at) => sizes.current.get(lines[at]?.kind ?? "item") ?? LINE_ESTIMATE,
    getItemKey: lineKey,
    overscan: OVERSCAN,
    // The selected row stays mounted: `aria-activedescendant` names it, and the keys move from it.
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (selectedLine >= 0 && !indexes.includes(selectedLine)) {
        indexes.push(selectedLine);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      const kind = node?.dataset.kind as TreeLine["kind"] | undefined;
      if (node && kind && !sizes.current.has(kind) && node.offsetHeight > 0) sizes.current.set(kind, node.offsetHeight);
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );

  // A line's index moves when lines open or close above it. Its row keeps its props (the index is
  // not one it draws again for) and is told here, so TanStack measures the right line on a resize.
  useLayoutEffect(() => {
    for (const [key, node] of virtualizer.elementsCache) {
      const at = model.lineIndex.get(String(key));
      if (at !== undefined && node.getAttribute("data-index") !== String(at))
        node.setAttribute("data-index", String(at));
    }
  }, [virtualizer, model]);

  // The selected row comes into view as the keys move it (and once it is listed, if it was not yet).
  // A selection that leaves the lines (none while Bookmarks searches, a closed folder) is revealed
  // again when it comes back, as a row that mounted selected scrolled itself into view.
  const revealed = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    if (selectedLine < 0) revealed.current = undefined;
    if (selected === revealed.current || selectedLine < 0) return;
    revealed.current = selected;
    virtualizer.scrollToIndex(selectedLine, { align: "auto" });
  });

  const move = (to: number) => {
    const item = items[Math.max(0, Math.min(items.length - 1, to))];
    if (item) onSelect(item.key);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const handled = (() => {
      switch (event.key) {
        case "ArrowDown":
          return (move(index + 1), true);
        case "ArrowUp":
          return (move(index < 0 ? 0 : index - 1), true);
        case "Home":
          return (move(0), true);
        case "End":
          return (move(items.length - 1), true);
        case "ArrowRight":
          if (!current?.expandable) return false;
          if (current.expanded) move(index + 1);
          else onExpand(current.key, true);
          return true;
        case "ArrowLeft": {
          if (!current) return false;
          const up = current.expanded ? undefined : items[model.parent[index]!];
          if (current.expanded) onExpand(current.key, false);
          else if (up) onSelect(up.key);
          return true;
        }
        case "Enter":
        case " ":
          return current ? (onActivate(current), true) : false;
      }
      if (event.key.length !== 1) return false;
      const now = event.timeStamp;
      const text = (now - typed.current.at < TYPEAHEAD_RESET_MS ? typed.current.text : "") + event.key.toLowerCase();
      typed.current = { text, at: now };
      const start = text.length === 1 ? index + 1 : Math.max(0, index);
      const match = items[typedMatch(model, text, start)];
      if (match) onSelect(match.key);
      return true;
    })();
    if (handled) event.preventDefault();
  };

  // One function per handler for every render: a memo row draws again only when its own props change.
  const rowHandlers = useStableHandlers({
    onRowPointerDown: (item: TreeItem) => {
      onSelect(item.key);
      element.current?.focus({ preventScroll: true });
    },
    onRowClick: (item: TreeItem) => item.expandable && onExpand(item.key, !item.expanded),
    onRowDoubleClick: (item: TreeItem) => !item.expandable && onActivate(item),
  });

  // The mounted lines sit in the flow, each run of lines not mounted one empty block of their
  // height, so a line moved by a scroll or by lines opening above it keeps its props and does not
  // draw again. Before the first measure (no viewport yet) there is no range, so the selected row is
  // added at its estimated place.
  const placed = virtualizer.getVirtualItems().map(({ index: at, start, end }) => ({ at, start, end }));
  if (selectedLine >= 0 && !placed.some(({ at }) => at === selectedLine)) {
    const estimate = virtualizer.measurementsCache[selectedLine];
    const start = estimate?.start ?? scrollMargin;
    placed.push({ at: selectedLine, start, end: estimate?.end ?? start + LINE_ESTIMATE });
    placed.sort((a, b) => a.at - b.at);
  }
  const children: ReactNode[] = [];
  let reached = scrollMargin;
  const gap = (height: number) => {
    if (height > 0) children.push(<div key={`\u0000gap:${children.length}`} aria-hidden="true" style={{ height }} />);
  };
  for (const { at, start, end } of placed) {
    gap(start - reached);
    reached = end;
    const line = lines[at]!;
    if (line.kind === "note") {
      children.push(<TreeNoteLine key={line.key} index={at} content={line.content} measure={measure} />);
      continue;
    }
    const item = model.itemIndex.get(line.key)!;
    children.push(
      <TreeRow
        key={line.key}
        index={at}
        measure={measure}
        id={rowId(line.key)}
        item={line}
        selected={line.key === selected}
        position={model.position[item]!}
        siblings={model.siblings[item]!}
        className={rowClassName}
        style={rowStyle?.(line)}
        {...rowHandlers}
      />,
    );
  }
  gap(virtualizer.getTotalSize() + scrollMargin - reached);

  return (
    <div
      ref={element}
      className={cx("ui-tree", className)}
      role="tree"
      tabIndex={0}
      aria-label={label}
      aria-activedescendant={current ? rowId(current.key) : undefined}
      onKeyDown={onKeyDown}
    >
      {children}
    </div>
  );
}

/** Where a windowed line sits: its index, by which TanStack measures it (`data-index`). */
interface Placed {
  index: number;
  measure: (element: HTMLElement | null) => void;
}

function sameStyle(a: CSSProperties | undefined, b: CSSProperties | undefined): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  const keys = Object.keys(a) as (keyof CSSProperties)[];
  return keys.length === Object.keys(b).length && keys.every((key) => Object.is(a[key], b[key]));
}

/** Equal props, but for `index` (the tree sets a moved line's attribute itself) and `style`, equal
 *  by its values: the caller's `rowStyle` gives a new object each render. */
function samePlaced<P extends Placed & { style?: CSSProperties }>(before: P, after: P): boolean {
  const keys = Object.keys(after) as (keyof P)[];
  return (
    keys.length === Object.keys(before).length &&
    keys.every((key) =>
      key === "index"
        ? true
        : key === "style"
          ? sameStyle(before.style, after.style)
          : Object.is(before[key], after[key]),
    )
  );
}

// Its own block, so a note's margins count in its measured height.
const NOTE_STYLE: CSSProperties = { display: "flow-root" };

const TreeNoteLine = memo(function TreeNoteLine({ index, content, measure }: Placed & { content: ReactNode }) {
  return (
    <div ref={measure} data-index={index} data-kind="note" style={NOTE_STYLE}>
      {content}
    </div>
  );
}, samePlaced);

interface RowProps extends Placed {
  id: string;
  item: TreeItem;
  selected: boolean;
  /** 1-based place among its siblings, and their count: nesting is flattened, so each row says it. */
  position: number;
  siblings: number;
  className?: string;
  style?: CSSProperties;
  onRowPointerDown: (item: TreeItem) => void;
  onRowClick: (item: TreeItem) => void;
  onRowDoubleClick: (item: TreeItem) => void;
}

const TreeRow = memo(function TreeRow({
  index,
  measure,
  id,
  item,
  selected,
  position,
  siblings,
  className,
  style,
  onRowPointerDown,
  onRowClick,
  onRowDoubleClick,
}: RowProps) {
  return (
    // The tree above owns focus and every key, so a row takes only the pointer.
    // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/interactive-supports-focus
    <div
      ref={measure}
      data-index={index}
      data-kind="item"
      id={id}
      className={cx("ui-tree-row", className, selected && "is-selected")}
      role="treeitem"
      aria-level={item.depth + 1}
      aria-selected={selected}
      aria-expanded={item.expandable ? item.expanded : undefined}
      aria-posinset={position}
      aria-setsize={siblings}
      style={style}
      onPointerDown={() => onRowPointerDown(item)}
      onClick={() => onRowClick(item)}
      onDoubleClick={() => onRowDoubleClick(item)}
    >
      {item.content}
    </div>
  );
}, samePlaced);

/** Builds a tree's lines, keeping the object of each line whose fields and `deps` are unchanged. */
export interface TreeLineBuilder {
  item(fields: Omit<TreeItem, "kind" | "content">, deps: readonly unknown[], content: () => ReactNode): TreeItem;
  note(key: string, deps: readonly unknown[], content: () => ReactNode): TreeNote;
}

type Kept = Map<string, { line: TreeLine; deps: readonly unknown[] }>;

const sameDeps = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length === b.length && a.every((value, at) => Object.is(value, b[at]));

class TreeLineCache {
  private kept: Kept = new Map();

  /** The lines `build` makes; a line keeps its last object while its fields and `deps` match. */
  build(build: (lines: TreeLineBuilder) => TreeLine[]): TreeLine[] {
    const previous = this.kept;
    const next: Kept = new Map();
    const reuse = <L extends TreeLine>(
      key: string,
      deps: readonly unknown[],
      fits: (line: TreeLine) => line is L,
      make: () => L,
    ): L => {
      const old = previous.get(key);
      const line = old && sameDeps(old.deps, deps) && fits(old.line) ? old.line : make();
      next.set(key, { line, deps });
      return line;
    };
    const lines = build({
      item: (fields, deps, content) =>
        reuse(
          fields.key,
          deps,
          (line): line is TreeItem =>
            line.kind === "item" &&
            line.depth === fields.depth &&
            line.text === fields.text &&
            line.expandable === fields.expandable &&
            line.expanded === fields.expanded,
          () => ({ kind: "item", ...fields, content: content() }),
        ),
      note: (key, deps, content) =>
        reuse(
          key,
          deps,
          (line): line is TreeNote => line.kind === "note",
          () => ({ kind: "note", key, content: content() }),
        ),
    });
    this.kept = next;
    return lines;
  }
}

/** Keeps unchanged lines' objects across builds, so their memoized rows skip the render:
 *  `useMemo(() => cache.build((line) => [line.item(...), ...]), [data])`. */
export function useTreeLineCache(): TreeLineCache {
  return useState(() => new TreeLineCache())[0];
}
