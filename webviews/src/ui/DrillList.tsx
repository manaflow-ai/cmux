// A drill-down combobox: a text field that filters an inline listbox of one level (a folder), with
// keys to enter the highlighted row and go up (drillKeys.ts). Items arrive asynchronously; the page
// owns the items, the highlight and the query, so it can restore the highlight after going up.
//
// Base UI 1.8 has no combobox with a caller-controlled highlight (Autocomplete only highlights
// from its own keyboard state), so this one widget is implemented here, in the wrapper, once:
// role=combobox + aria-activedescendant into a listbox, a polite status line for level changes and
// counts, and virtualization (VirtualList) past VIRTUAL_THRESHOLD rows.
import { useCallback, useId, useRef, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { drillKeyAction } from "./drillKeys";
import type { ListCommand } from "./keyStyle";
import { useKeyStyleSettings, useListKeys } from "./useListKeys";
import { useUiDirection } from "./UiProvider";
import { VirtualList } from "./VirtualList";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import { focusRoute } from "./focusRoute";

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

/** Above this many rows the list renders only what is visible. */
export const VIRTUAL_THRESHOLD = 120;
const ROW_HEIGHT = 28;

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
  const rows = sections.flatMap((section) => section.items);
  // -1 is no highlight (an empty level under Locations); arrows start from it.
  const current = rows.length && highlight >= 0 ? Math.min(highlight, rows.length - 1) : -1;
  const levelEmpty = (sections.at(-1)?.items.length ?? 0) === 0;
  const optionId = (index: number) => `${id}-option-${index}`;
  const field = useRef<HTMLInputElement | null>(null);
  const autoFocus = props.autoFocus !== false; // focus-route: reads the prop; focusOnMount moves the keyboard
  const attachField = useCallback(
    (element: HTMLInputElement | null) => {
      field.current = element;
      if (autoFocus) focusOnMount(element);
    },
    [autoFocus],
  );

  const moveBy = (delta: number) => {
    if (rows.length)
      onHighlight(Math.max(0, Math.min(rows.length - 1, (current < 0 && delta < 0 ? rows.length : current) + delta)));
  };
  const highlighted = () => (current >= 0 ? rows[current] : undefined);
  // `app.keyStyle`. In the field only Vim's Esc and Emacs' Ctrl-N/P/G reach here (the layer's
  // inText rows); leaving the field gives the keyboard to the list. In the list, Vim's j/k, gg/G,
  // Ctrl-D/U, l (enter), h (up), / (the field) and Esc (the field's Esc), and Emacs' alike.
  const onListCommand = (command: ListCommand, inField: boolean): boolean | void => {
    switch (command) {
      case "list.next":
        return moveBy(1);
      case "list.previous":
        return moveBy(-1);
      case "list.pageDown":
        return moveBy(10);
      case "list.pageUp":
        return moveBy(-10);
      case "list.first":
        return onHighlight(0);
      case "list.last":
        return onHighlight(Math.max(0, rows.length - 1));
      case "list.open":
        return props.onEnter(highlighted());
      case "list.back":
        return props.onUp();
      case "list.search":
        return void focusRoute(field.current, "person", "key style list key", { preventScroll: true });
      case "list.leave": {
        // The field gives the keyboard to its list; the list does what the field's Esc does.
        if (!inField) return props.onCancel();
        const list = field.current?.ownerDocument.getElementById(listId);
        if (!list) return false;
        focusRoute(list, "person", "key style list key", { preventScroll: true });
        return;
      }
    }
  };
  const fieldKeys = useListKeys({ onCommand: (command) => onListCommand(command, true) });
  const listKeys = useListKeys({ onCommand: (command) => onListCommand(command, false) });
  // Only a key style gives the list the keyboard; in Standard a press on its gaps never takes focus
  // from the field.
  const listTakesKeys = useKeyStyleSettings().keyStyle !== "standard";
  const onListKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    listKeys(event);
    if (event.defaultPrevented || event.key !== "Enter" || event.metaKey || event.ctrlKey || event.altKey) return;
    // The list has the keyboard only after a key style's leave: Return still chooses.
    event.preventDefault();
    props.onChoose(highlighted());
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    fieldKeys(event);
    if (event.defaultPrevented) return;
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
    const item = current >= 0 ? rows[current] : undefined;
    switch (action.kind) {
      case "move":
        return moveBy(action.delta);
      case "edge":
        onHighlight(action.to === "first" ? 0 : Math.max(0, rows.length - 1));
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

  const row = (item: T, index: number, style?: CSSProperties) => (
    <div
      key={getKey(item)}
      id={optionId(index)}
      ref={index === current && !style ? scrollIntoViewRef : undefined}
      style={style}
      className={cx("ui-drill-row", props.rowClassName)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native option cannot hold rich rows.
      role="option"
      tabIndex={-1}
      aria-selected={index === current}
      aria-posinset={style ? index + 1 : undefined}
      aria-setsize={style ? rows.length : undefined}
      {...itemAttributes?.(item)}
      onMouseDown={(event) => {
        // Keeps focus in the search field for every press (a prevented mousedown still opens the
        // context menu); only an unmodified primary press moves the highlight.
        event.preventDefault();
        if (event.button !== 0 || event.ctrlKey) return;
        onHighlight(index);
      }}
      onMouseMove={() => index !== current && onHighlight(index)}
      onDoubleClick={(event) => {
        if (event.button !== 0 || event.ctrlKey) return;
        props.onActivate(item);
      }}
    >
      {renderItem(item)}
    </div>
  );

  // Virtualized: one flat run of rows (section headings are not repeated), each with its position.
  const virtual = rows.length > VIRTUAL_THRESHOLD;
  let offset = 0;
  const list = virtual ? (
    <VirtualList
      fade
      id={listId}
      className={props.listClassName}
      label={props.listLabel}
      count={rows.length}
      estimateSize={() => ROW_HEIGHT}
      activeIndex={current}
      tabIndex={listTakesKeys ? -1 : undefined}
      onKeyDown={onListKeyDown}
      activeScrollKey={`${props.listLabel}\0${query}\0${rows.length}\0${current >= 0 ? getKey(rows[current]) : ""}`}
      renderRow={(index, style) => row(rows[index], index, style)}
    />
  ) : (
    <div
      ref={scrollEdges}
      id={listId}
      className={cx("ui-scroll-edge-fade", props.listClassName)}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline listbox with rich rows; no native element fits.
      role="listbox"
      aria-label={props.listLabel}
      tabIndex={listTakesKeys ? -1 : undefined}
      onKeyDown={onListKeyDown}
    >
      {sections.map((section) => {
        const start = offset;
        offset += section.items.length;
        if (section.items.length === 0) return null;
        const items = section.items.map((item, index) => row(item, start + index));
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
        ref={attachField}
        className={cx("ui-field", props.fieldClassName)}
        type="text"
        // oxlint-disable-next-line jsx-a11y/no-redundant-roles -- a text input is a textbox to the browser; the combobox role is what tells assistive tech about the list.
        role="combobox"
        aria-expanded="true"
        aria-autocomplete="list"
        aria-controls={rows.length ? listId : undefined}
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
      {rows.length === 0 ? null : list}
      <output className="ui-sr-only">{props.status}</output>
    </>
  );
}
