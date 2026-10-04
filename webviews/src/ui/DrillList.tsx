// A drill-down combobox: a text field that filters an inline listbox of one level (a folder), with
// keys to enter the highlighted row and go up (drillKeys.ts). Items arrive asynchronously; the page
// owns the items, the highlight and the query, so it can restore the highlight after going up.
//
// Base UI 1.8 has no combobox with a caller-controlled highlight (Autocomplete only highlights
// from its own keyboard state), so this one widget is implemented here, in the wrapper, once:
// role=combobox + aria-activedescendant into a listbox, a polite status line for level changes and
// counts, and virtualization (VirtualList) past VIRTUAL_THRESHOLD rows.
import { useId, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { drillKeyAction } from "./drillKeys";
import { useUiDirection } from "./UiProvider";
import { VirtualList } from "./VirtualList";
import { cx } from "./cx";

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
  if (element && typeof element.scrollIntoView === "function") element.scrollIntoView({ block: "nearest" });
}

export function DrillList<T>(props: DrillListProps<T>) {
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
    const item = current >= 0 ? rows[current] : undefined;
    switch (action.kind) {
      case "move":
        if (rows.length)
          onHighlight(
            Math.max(
              0,
              Math.min(rows.length - 1, (current < 0 && action.delta < 0 ? rows.length : current) + action.delta),
            ),
          );
        return;
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
        event.preventDefault();
        onHighlight(index);
      }}
      onMouseMove={() => index !== current && onHighlight(index)}
      onDoubleClick={() => props.onActivate(item)}
    >
      {renderItem(item)}
    </div>
  );

  // Virtualized: one flat run of rows (section headings are not repeated), each with its position.
  const virtual = rows.length > VIRTUAL_THRESHOLD;
  let offset = 0;
  const list = virtual ? (
    <VirtualList
      id={listId}
      className={props.listClassName}
      label={props.listLabel}
      count={rows.length}
      estimateSize={() => ROW_HEIGHT}
      activeIndex={current}
      renderRow={(index, style) => row(rows[index], index, style)}
    />
  ) : (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline listbox with rich rows; no native element fits.
    <div id={listId} className={props.listClassName} role="listbox" aria-label={props.listLabel}>
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
        ref={props.autoFocus === false ? undefined : focusOnMount}
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
