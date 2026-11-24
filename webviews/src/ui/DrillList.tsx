// A drill-down combobox: a text field that filters an inline listbox of one level (a folder), with
// keys to enter the highlighted row and go up (drillKeys.ts). Items arrive asynchronously; the page
// owns the items, the highlight and the query, so it can restore the highlight after going up.
//
// Base UI 1.8 has no combobox with a caller-controlled highlight (Autocomplete only highlights
// from its own keyboard state), so this one widget is implemented here, in the wrapper, once:
// role=combobox + aria-activedescendant into a listbox, a polite status line for level changes and
// counts.
//
// A level longer than VIRTUAL_THRESHOLD rows mounts only the rows near the list's viewport (one
// viewport of overscan each side) and the highlighted row, between spacers, in each section's
// place: the section headings and the `after` line stay, and it costs the same at a thousand rows
// as at ten thousand. Windowed rows carry aria-posinset/aria-setsize. Each row is a memoized
// DrillRow with stable handlers: a highlight change re-renders the two rows it moved between.
import {
  memo,
  useCallback,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import { drillKeyAction } from "./drillKeys";
import { useUiDirection } from "./UiProvider";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";

export interface DrillSection<T> {
  id: string;
  /** A visible heading (and the group's name); none for the level's own rows. */
  label?: string;
  items: readonly T[];
}

export interface DrillListProps<T> {
  sections: readonly DrillSection<T>[];
  getKey(item: T): string;
  renderItem(item: T): ReactNode;
  /** Extra attributes of a row (`title`, `data-*`). */
  itemAttributes?(item: T): Record<string, string | undefined>;
  /** Index into the rows of all sections, in order. */
  highlight: number;
  onHighlight(index: number): void;
  query: string;
  onQueryChange(value: string): void;
  /** Tab, the inline-end arrow at the end of the text. */
  onEnter(item: T | undefined): void;
  /** The inline-start arrow at the start, Backspace on an empty query, Cmd-Up. */
  onUp(): void;
  /** Return. */
  onChoose(item: T | undefined): void;
  /** Escape on an empty query (Escape with text clears it). */
  onCancel(): void;
  /** A double click on a row. */
  onActivate(item: T): void;
  /** The field's accessible name and placeholder. */
  label: string;
  placeholder?: string;
  listLabel: string;
  /** Shown (outside the listbox) when the last section, the level itself, has no rows. */
  empty?: ReactNode;
  /** After the rows (a "more" line). */
  after?: ReactNode;
  /** A line under the field, also its description. */
  hint?: ReactNode;
  /** Announced politely when it changes: the level and its count, loading, failure. */
  status?: string;
  autoFocus?: boolean;
  fieldClassName?: string;
  listClassName?: string;
  rowClassName?: string;
  emptyClassName?: string;
  sectionClassName?: string;
  hintClassName?: string;
}

/** Above this many rows (a menu's worth, as ui/Listbox) the list mounts only what is near its view. */
export const VIRTUAL_THRESHOLD = 50;
/** A row's and a heading's height before one is measured. */
const ROW_HEIGHT = 28;
const HEADING_HEIGHT = 24;

function focusOnMount(element: HTMLInputElement | null): void {
  element?.focus({ preventScroll: true });
}

function scrollIntoViewRef(element: HTMLElement | null): void {
  if (!element) return;

  // `scrollIntoView` is allowed to scroll every ancestor by default. That is surprising for a
  // callback ref: replacing a virtualized level with a short level (for example, breadcrumb
  // navigation) can move the document scrollbar even though the highlighted row is visible.
  // Keep the focus-following behavior inside the list that owns the row.
  const scroller = element.closest<HTMLElement>('[role="listbox"]');
  if (!scroller) return;

  const row = element.getBoundingClientRect();
  const viewport = scroller.getBoundingClientRect();
  if (row.top < viewport.top) scroller.scrollTop -= viewport.top - row.top;
  else if (row.bottom > viewport.bottom) scroller.scrollTop += row.bottom - viewport.bottom;
}

export function DrillList<T>(props: DrillListProps<T>) {
  const scrollEdges = useScrollEdges();
  const { sections, getKey, renderItem, itemAttributes, highlight, onHighlight, query } = props;
  const dir = useUiDirection();
  const id = useId();
  const listId = `${id}-list`;
  const hintId = `${id}-hint`;
  // The rows of all sections, in order, are addressed by index without copying them: a level of
  // thousands is walked per section (a few), not per row.
  let total = 0;
  for (const section of sections) total += section.items.length;
  // -1 is no highlight (an empty level under Locations); arrows start from it.
  const current = total && highlight >= 0 ? Math.min(highlight, total - 1) : -1;
  const currentItem = current >= 0 ? drillItemAt(sections, current) : undefined;
  const levelEmpty = (sections.at(-1)?.items.length ?? 0) === 0;
  const optionId = (index: number) => `${id}-option-${index}`;

  // The list's window: the scroller's offset and height, and a row's and a heading's height.
  const windowed = total > VIRTUAL_THRESHOLD;
  const scroller = useRef<HTMLDivElement | null>(null);
  const [view, setView] = useState({ top: 0, height: 0 });
  const [rowPx, setRowPx] = useState(0);
  const [headingPx, setHeadingPx] = useState(0);
  const readView = useCallback(() => {
    const node = scroller.current;
    if (!node) return;
    setView((previous) =>
      previous.top === node.scrollTop && previous.height === node.clientHeight
        ? previous
        : { top: node.scrollTop, height: node.clientHeight },
    );
  }, []);
  const attachScroller = useCallback(
    (node: HTMLDivElement | null) => {
      scroller.current = node;
      scrollEdges(node);
    },
    [scrollEdges],
  );
  useLayoutEffect(() => {
    if (!windowed) return;
    readView();
    const node = scroller.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(readView);
    observer.observe(node);
    return () => observer.disconnect();
  }, [windowed, readView]);
  useLayoutEffect(() => {
    if (!windowed) return;
    const node = scroller.current;
    if (rowPx === 0) {
      const row = node?.querySelector<HTMLElement>("[role='option']");
      if (row && row.offsetHeight > 0) setRowPx(row.offsetHeight);
    }
    if (headingPx === 0) {
      const heading = node?.querySelector<HTMLElement>(".ui-drill-section");
      if (heading && heading.offsetHeight > 0) setHeadingPx(heading.offsetHeight);
    }
  }, [windowed, rowPx, headingPx, sections]);
  // The highlighted row is always mounted; it is brought into view when it moves, and when the
  // same index names a new result set (a filter that keeps the first row first).
  const scrollKey = `${props.listLabel}\0${query}\0${total}\0${current}\0${currentItem === undefined ? "" : getKey(currentItem)}`;
  useLayoutEffect(() => {
    if (current >= 0) scrollIntoViewRef(document.getElementById(optionId(current)));
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- scrollKey names everything the scroll follows.
  }, [scrollKey]);

  // The rows' handlers are stable (a memoized row must not re-render for a new closure); they read
  // the list's latest state when they run.
  const latest = useRef({ current, sections, onHighlight, onActivate: props.onActivate });
  useLayoutEffect(() => {
    latest.current = { current, sections, onHighlight, onActivate: props.onActivate };
  });
  const pressRow = useCallback((index: number) => latest.current.onHighlight(index), []);
  const hoverRow = useCallback((index: number) => {
    if (index !== latest.current.current) latest.current.onHighlight(index);
  }, []);
  const activateRow = useCallback((index: number) => {
    const item = drillItemAt(latest.current.sections, index);
    if (item !== undefined) latest.current.onActivate(item);
  }, []);

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const input = event.currentTarget;
    const action = drillKeyAction(event, {
      query,
      caretStart: input.selectionStart ?? query.length,
      caretEnd: input.selectionEnd ?? query.length,
      dir,
    });
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    const item = currentItem;
    switch (action.kind) {
      case "move":
        if (total)
          onHighlight(
            Math.max(0, Math.min(total - 1, (current < 0 && action.delta < 0 ? total : current) + action.delta)),
          );
        return;
      case "edge":
        onHighlight(action.to === "first" ? 0 : Math.max(0, total - 1));
        return;
      case "enter":
        return props.onEnter(item);
      case "up":
        return props.onUp();
      case "choose":
        return props.onChoose(item);
      case "clear":
        return props.onQueryChange("");
      case "cancel":
        return props.onCancel();
    }
  };

  const rowClassName = cx("ui-drill-row", props.rowClassName);
  const rowPitch = rowPx || ROW_HEIGHT;
  // Each section's first index and where its rows start in the list, from the measured heights
  // (a few sections).
  const places: { start: number; top: number }[] = [];
  let offset = 0;
  let rowsTop = 0;
  for (const section of sections) {
    if (section.label && section.items.length) rowsTop += headingPx || HEADING_HEIGHT;
    places.push({ start: offset, top: rowsTop });
    offset += section.items.length;
    rowsTop += section.items.length * rowPitch;
  }
  const list = (
    <div
      ref={attachScroller}
      id={listId}
      // `ui-virtual` marks a list that mounts only its visible rows.
      className={cx("ui-scroll-edge-fade", windowed && "ui-virtual", props.listClassName)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline listbox with rich rows; no native element fits.
      role="listbox"
      aria-label={props.listLabel}
      onScroll={windowed ? readView : undefined}
    >
      {sections.map((section, place) => {
        if (section.items.length === 0) return null;
        const { start, top: sectionTop } = places[place]!;
        const highlighted = current >= start && current < start + section.items.length ? current - start : -1;
        const segments = windowed
          ? drillSegments(section.items.length, highlighted, view.top - sectionTop, view.height, rowPitch)
          : [{ start: 0, end: section.items.length, before: 0 }];
        const rest = windowed ? (section.items.length - (segments.at(-1)?.end ?? 0)) * rowPitch : 0;
        // One flat keyed array: a row that moves between segments keeps its element.
        const items = [
          ...segments.flatMap((segment, at) => [
            segment.before > 0 && <div key={`\0space-${at}`} aria-hidden="true" style={{ height: segment.before }} />,
            ...section.items.slice(segment.start, segment.end).map((item, step) => {
              const index = start + segment.start + step;
              return (
                <DrillRow
                  key={getKey(item)}
                  item={item}
                  index={index}
                  id={optionId(index)}
                  className={rowClassName}
                  selected={index === current}
                  setSize={windowed ? total : undefined}
                  renderItem={renderItem}
                  itemAttributes={itemAttributes}
                  onPress={pressRow}
                  onHover={hoverRow}
                  onActivate={activateRow}
                />
              );
            }),
          ]),
          rest > 0 && <div key="\0space-rest" aria-hidden="true" style={{ height: rest }} />,
        ];
        if (!section.label) return items;
        const labelId = `${id}-section-${section.id}`;
        return (
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a group of options inside a listbox.
          <div key={section.id} role="group" aria-labelledby={labelId}>
            <div id={labelId} className={cx("ui-drill-section", props.sectionClassName)}>
              {section.label}
            </div>
            {items}
          </div>
        );
      })}
      {props.after}
    </div>
  );

  return (
    <>
      <input
        ref={props.autoFocus === false ? undefined : focusOnMount}
        className={cx("ui-field", props.fieldClassName)}
        type="text"
        // oxlint-disable-next-line jsx-a11y/no-redundant-roles -- a text input is a textbox to the browser; the combobox role is what tells assistive tech about the list.
        role="combobox"
        aria-expanded="true"
        aria-autocomplete="list"
        aria-controls={total ? listId : undefined}
        aria-activedescendant={current >= 0 ? optionId(current) : undefined}
        aria-describedby={props.hint ? hintId : undefined}
        aria-label={props.label}
        placeholder={props.placeholder}
        spellCheck={false}
        autoComplete="off"
        autoCapitalize="off"
        value={query}
        onChange={(event) => props.onQueryChange(event.target.value)}
        onKeyDown={onKeyDown}
      />
      {props.hint ? (
        <div id={hintId} className={cx("ui-drill-hint", props.hintClassName)}>
          {props.hint}
        </div>
      ) : null}
      {levelEmpty && props.empty ? (
        <div className={cx("ui-drill-empty", props.emptyClassName)}>{props.empty}</div>
      ) : null}
      {total === 0 ? null : list}
      <output className="ui-sr-only">{props.status}</output>
    </>
  );
}

interface DrillRowProps<T> {
  item: T;
  index: number;
  id: string;
  className: string;
  selected: boolean;
  /** Set when the list is windowed: the full length, for aria-setsize and aria-posinset. */
  setSize?: number;
  renderItem(item: T): ReactNode;
  itemAttributes?(item: T): Record<string, string | undefined>;
  onPress(index: number): void;
  onHover(index: number): void;
  onActivate(index: number): void;
}

const DrillRow = memo(function DrillRow<T>({
  item,
  index,
  id,
  className,
  selected,
  setSize,
  renderItem,
  itemAttributes,
  onPress,
  onHover,
  onActivate,
}: DrillRowProps<T>) {
  return (
    <div
      id={id}
      className={className}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native option cannot hold rich rows.
      role="option"
      tabIndex={-1}
      aria-selected={selected}
      aria-posinset={setSize === undefined ? undefined : index + 1}
      aria-setsize={setSize}
      {...itemAttributes?.(item)}
      onMouseDown={(event: MouseEvent) => {
        // Keeps focus in the search field for every press (a prevented mousedown still opens the
        // context menu); only an unmodified primary press moves the highlight.
        event.preventDefault();
        if (event.button !== 0 || event.ctrlKey) return;
        onPress(index);
      }}
      onMouseMove={() => onHover(index)}
      onDoubleClick={(event: MouseEvent) => {
        if (event.button !== 0 || event.ctrlKey) return;
        onActivate(index);
      }}
    >
      {renderItem(item)}
    </div>
  );
}) as <T>(props: DrillRowProps<T> & { key?: string }) => ReactNode;

/** The row at `index` across the sections, in order. */
function drillItemAt<T>(sections: readonly DrillSection<T>[], index: number): T | undefined {
  for (const section of sections) {
    if (index < section.items.length) return section.items[index];
    index -= section.items.length;
  }
  return undefined;
}

/** The row ranges of one section a windowed list mounts, each with the spacer height before it: the
 * rows in view with one viewport of overscan each side, and the highlighted row when it is outside
 * them, in order. `top` is the scroller's offset from the section's first row. Before the viewport
 * is measured (no layout yet) a viewport is taken as 400 px. */
export function drillSegments(
  count: number,
  highlighted: number,
  top: number,
  viewportPx: number,
  rowPx: number,
): { start: number; end: number; before: number }[] {
  const height = viewportPx > 0 ? viewportPx : 400;
  const overscan = Math.ceil(height / rowPx);
  const clamp = (value: number, low: number) => Math.min(count, Math.max(low, value));
  const start = clamp(Math.floor(top / rowPx) - overscan, 0);
  const end = clamp(Math.ceil((top + height) / rowPx) + overscan, start);
  const ranges: [number, number][] = start < end ? [[start, end]] : [];
  if (highlighted >= 0 && highlighted < count && (highlighted < start || highlighted >= end)) {
    ranges.push([highlighted, highlighted + 1]);
    ranges.sort((a, b) => a[0] - b[0]);
  }
  let at = 0;
  return ranges.map(([from, to]) => {
    const before = (from - at) * rowPx;
    at = to;
    return { start: from, end: to, before };
  });
}
