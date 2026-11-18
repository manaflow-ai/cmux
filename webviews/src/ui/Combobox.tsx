// A text field with suggestions over Base UI Autocomplete (a popup listbox under the field). The
// caller computes the suggestions (they may arrive asynchronously) from `onQuery`. Return submits
// the highlighted suggestion or the typed text, Tab completes, Escape cancels; Base UI owns the
// combobox role, aria-activedescendant and the arrows.
//
// A list of more than COMBOBOX_VIRTUAL_AFTER scrolling rows mounts only the rows near its scroller's
// viewport (VirtualRows), with or without pinned actions and with or without `virtualRows`, so a
// picker over thousands draws and filters as one over a menu's worth. Each row is a memoized
// ComboboxOption with stable handlers and style: a caller's re-render (a highlight preview, a live
// update) re-renders only the rows it changed.
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type RefObject,
  memo,
} from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import {
  defaultRangeExtractor,
  measureElement,
  useVirtualizer,
  type Range,
  type Virtualizer,
} from "@tanstack/react-virtual";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import { ScrollArea } from "./ScrollArea";
import { virtualRowStyle } from "./VirtualList";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./popupProtocol";
import { popupAction, popupActionByValue, popupSearchId } from "./popupDescriptors";

type BaseUIKeyEvent = KeyboardEvent<HTMLInputElement> & { preventBaseUIHandler?: () => void };

/** Up to this many scrolling rows all mount (a menu's worth); past it only those near the viewport. */
export const COMBOBOX_VIRTUAL_AFTER = 50;
/** A row's height before one is measured, when the caller gives no `virtualRows.estimate`. */
const ESTIMATED_ROW_PX = 28;

export interface ComboboxProps {
  /** The field's text when it opens. */
  defaultValue?: string;
  suggestions: readonly string[];
  /** Actions that stay put while the remaining suggestions scroll: below the field, or with
   * `pinnedPlacement: "bottom"` under the list (the arrows reach them after the last row either way). */
  pinnedSuggestions?: readonly string[];
  pinnedPlacement?: "top" | "bottom";
  /** A line in the list's place (a list's "nothing here yet"): with `pinnedSuggestions`, after the
   * scrolling rows and before bottom-pinned actions, so it never lands under them; without, after the
   * list. Not a row: the arrows never reach it. With `pinnedSuggestions` it sits inside the listbox
   * (the pinned actions are options of the same list), in a `role="presentation"` wrapper, so it takes
   * non-interactive text only: no buttons, links or live regions (an action belongs in
   * `pinnedSuggestions`). The native popup (`native`, when the host draws the list) does not draw it. */
  listEnd?: ReactNode;
  /** The text changed (typing, completion): compute new suggestions. */
  onQuery(value: string): void;
  /** Return: the highlighted suggestion, else the text. */
  onSubmit(value: string): void;
  /** Escape, or focus leaving the field. */
  onCancel(): void;
  label: string;
  placeholder?: string;
  readOnly?: boolean;
  inputClassName?: string;
  /** Content alongside the field, inside the search row. */
  inputRow?: { className: string; start: ReactNode };
  listClassName?: string;
  itemClassName?: string;
  inputRef?: React.Ref<HTMLInputElement>;
  /** Render the suggestions under the field in place (inside a popover) instead of in a popup. */
  inline?: boolean;
  /** With `inline`: the list keeps its tallest height while mounted (until the window resizes), so
   * narrowing it never resizes the popover and a field above it never moves under the caret
   * (cx-6k6cg). For a list with no empty-state message of its own after it. */
  keepHeight?: boolean;
  /** Keep a multi-control panel open when focus moves to its buttons. */
  cancelOnBlur?: boolean;
  /** Disabled rows remain visible but cannot be highlighted or submitted. */
  isItemDisabled?(value: string): boolean;
  /** true: the first row highlights while filtering; "always": also before any typing. */
  autoHighlight?: boolean | "always";
  /** Handle a shortcut while the Base UI input owns focus. `preventDefault` skips the Combobox's own
   * handling; `preventBaseUIHandler` also skips Base UI's (Return clicking the highlighted row). */
  onCommand?(event: BaseUIKeyEvent): void;
  /** Class for the Base UI root when the field and list are laid out together. */
  rootClassName?: string;
  /** A row's content (a name over a path); default: the suggestion text. The row still submits
   * and completes its suggestion string. */
  renderItem?(value: string): ReactNode;
  /** A rich row's accessible name; its identity remains the stable suggestion string. */
  itemLabel?(value: string): string | undefined;
  /** The committed choice, distinct from the transient keyboard highlight. */
  isItemCurrent?(value: string): boolean;
  /** Readable Tab completion for suggestions identified by an opaque key. */
  completionText?(value: string): string;
  /** Set false when Tab should move focus to the next control. */
  completeOnTab?: boolean;
  /** The highlighted suggestion changed; undefined when none is. `by` says whether the arrow keys
   * ("keyboard") or the pointer ("pointer") moved it, so a caller can treat a passing pointer as
   * less deliberate than a key press. */
  onHighlight?(value: string | undefined, by: "keyboard" | "pointer" | "none"): void;
  /** Only the scrolling rows near the viewport are in the DOM (TanStack
   * Virtual over the list's own scroller), so a list of thousands (the Projects picker, Leo
   * 2026-11-04: "opening the project picker lags like shit since we have so many") opens in a
   * frame. `estimate` is a row's height in pixels before it is measured. `sizeKey` is a string
   * that differs whenever a row's outer size can differ without its border box changing (a section
   * heading drawn in the row's margin): a row whose `sizeKey` changes remounts and is measured
   * again, and its size for one value is never reused for another. */
  virtualRows?: { estimate: number; sizeKey?(item: string): string };
  /** The line shown when there are no suggestions ("No matches"). It is Base UI's live Empty part
   * (`role="status"`, polite), so a screen reader hears it as the list empties. */
  empty?: ReactNode;
  emptyClassName?: string;
  /** Declarative native rows. When the host is available the web list is not mounted. */
  native?: {
    model: NativePopupDescription;
    anchor?: () => HTMLElement | null;
    onEvent?(event: NativePopupEvent): void;
    onDismiss?(): void;
  };
}

export function Combobox({
  defaultValue = "",
  suggestions,
  pinnedSuggestions,
  pinnedPlacement = "top",
  listEnd,
  onQuery,
  onSubmit,
  onCancel,
  label,
  placeholder,
  readOnly,
  inputClassName,
  inputRow,
  listClassName,
  itemClassName,
  inputRef,
  inline = false,
  keepHeight = false,
  cancelOnBlur = true,
  isItemDisabled,
  autoHighlight = false,
  onCommand,
  rootClassName,
  renderItem,
  itemLabel,
  isItemCurrent,
  completionText,
  completeOnTab = true,
  onHighlight,
  native,
  virtualRows,
  empty,
  emptyClassName,
}: ComboboxProps) {
  const container = usePortalContainer();
  // A popup list with no room above or below its field: past the window's edge (popupHost.ts).
  // The field keeps the focus; the list's highlight is Base UI's data-highlighted.
  const host = usePopupHost();
  const [field, setField] = useState<HTMLInputElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  const [value, setValue] = useState(defaultValue);
  const [nativeSessionOpen, setNativeSessionOpen] = useState(true);
  const nativeModel: NativePopupDescription | undefined = native && {
    ...native.model,
    search: {
      ...(native.model.search ?? {
        id: popupSearchId(native.model),
        placeholder: placeholder ?? label,
      }),
      value,
      submitOnReturn: true,
      autoHighlight:
        autoHighlight === "always" ? ("always" as const) : autoHighlight ? ("first" as const) : ("none" as const),
    },
  };
  const cancel = () => {
    if (native) setNativeSessionOpen(false);
    onCancel();
  };
  const nativePopup = useNativePopup({
    open:
      native !== undefined &&
      nativeSessionOpen &&
      (inline || suggestions.length > 0) &&
      (native.anchor !== undefined || field !== null),
    model: nativeModel ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: native?.anchor ?? (() => field),
    onEvent: (event) => {
      const action = nativeModel && popupAction(nativeModel, event.id);
      // Suggestions carry an explicit domain value. Auxiliary action IDs are protocol
      // identities and may spell the same word without selecting that suggestion.
      const suggestion = action?.value;
      const query = nativeModel?.search;
      if (event.type === "submit") {
        if (!query?.submitOnReturn || query.disabled || event.value === undefined) return;
        if (action && (suggestion === undefined || !suggestions.includes(suggestion))) {
          // Search owns Return in the native host. A selected auxiliary action still
          // activates through the same pick callback as its pointer counterpart.
          native?.onEvent?.({ ...event, type: "pick", value: undefined, reason: undefined });
          if (!action.keepOpen) setNativeSessionOpen(false);
          return;
        }
        native?.onEvent?.(event);
        if (event.id !== undefined && (suggestion === undefined || !enabledSuggestions.includes(suggestion))) return;
        submit(resolveSubmission(event.value, suggestion, event.reason === "keyboard" || event.reason === "pointer"));
        return;
      }
      native?.onEvent?.(event);
      if (event.type === "pick" && action && !action.keepOpen) setNativeSessionOpen(false);
      if (
        (event.type === "search" || event.type === "change") &&
        query &&
        !query.disabled &&
        event.id === query.id &&
        event.value !== undefined
      )
        changeQuery(event.value);
      else if (suggestion !== undefined && suggestions.includes(suggestion) && !isItemDisabled?.(suggestion)) {
        if (event.type === "pick") {
          onSubmit(suggestion);
        } else if (event.type === "highlight") {
          highlightedRef.current = suggestion;
          deliberatelyHighlighted.current = event.reason !== "none";
          onHighlight?.(
            suggestion,
            event.reason === "keyboard" ? "keyboard" : event.reason === "none" ? "none" : "pointer",
          );
        }
      } else if (event.type === "highlight" && event.id === undefined) {
        highlightedRef.current = undefined;
        deliberatelyHighlighted.current = false;
        onHighlight?.(undefined, "none");
      }
    },
    onDismiss: () => {
      native?.onDismiss?.();
      cancel();
    },
  });
  const attachField = useCallback(
    (node: HTMLInputElement | null) => {
      if (typeof inputRef === "function") inputRef(node);
      else if (inputRef) inputRef.current = node;
      if (host) setField(node);
    },
    [host, inputRef],
  );
  useEscapingPopup(inline ? null : host, popup, () => field, {
    side: "bottom",
    align: "start",
    gap: 2,
    kind: "list",
    active: "[data-highlighted]",
    pick: "click",
    shell: "parent",
  });
  // Only Return and Tab read the highlighted row, so it is a ref, not state: a highlight change
  // (every row the pointer crosses) must not re-render the whole list. Base UI marks the row
  // itself (data-highlighted).
  const highlightedRef = useRef<string | undefined>(undefined);
  const completionRef = useRef<{ text: string; key: string } | undefined>(undefined);
  const pressActivatedRef = useRef<string | undefined>(undefined);
  const listRef = useRef<HTMLDivElement>(null);
  const pressingList = useRef(false);
  useEffect(() => {
    // Native scrollbar presses may blur the input with no relatedTarget. Treat that gesture as
    // inside the list, just like an option press; a real outside press or Tab still closes it.
    const press = (event: PointerEvent) => {
      pressingList.current = !!listRef.current?.contains(event.target as Node);
    };
    const end = () => {
      pressingList.current = false;
    };
    document.addEventListener("pointerdown", press, true);
    document.addEventListener("pointerup", end, true);
    document.addEventListener("pointercancel", end, true);
    document.addEventListener("keydown", end, true);
    return () => {
      document.removeEventListener("pointerdown", press, true);
      document.removeEventListener("pointerup", end, true);
      document.removeEventListener("pointercancel", end, true);
      document.removeEventListener("keydown", end, true);
    };
  }, []);
  const keep = inline && keepHeight;
  const [tallest, setTallest] = useState(0);
  useLayoutEffect(() => {
    if (!keep) return;
    const height = listRef.current?.getBoundingClientRect().height ?? 0;
    if (height > tallest + 0.5) setTallest(height);
  }, [keep, suggestions, tallest]);
  // A resized window may cap the list lower (max-height from the room left): measure again.
  useLayoutEffect(() => {
    if (!keep) return;
    const reset = () => setTallest(0);
    window.addEventListener("resize", reset);
    return () => window.removeEventListener("resize", reset);
  }, [keep]);
  const held = keep && tallest > 0;
  const hasPinned = Boolean(pinnedSuggestions?.length);
  const edges = useScrollEdges();
  const pinnedEdges = useScrollEdges();
  const deliberatelyHighlighted = useRef(false);
  const virtualizer = useRef<Virtualizer<HTMLElement, Element> | null>(null);
  // The row the arrows moved to stays mounted in the commit that highlights it, before the scroll
  // that brings it into view lands, so aria-activedescendant never names a missing row.
  const [keyboardIndex, setKeyboardIndex] = useState(-1);
  // Whether the list has opened on its current row (or the person typed first, which moves the list).
  const revealedCurrent = useRef(false);
  const changeQuery = (next: string) => {
    revealedCurrent.current = true;
    if (native) setNativeSessionOpen(true);
    // Base UI resets a plain list's scroller on typing; a virtualized one is ours to reset.
    if (virtualized) virtualizer.current?.scrollToOffset(0);
    if (completionRef.current?.text !== next) completionRef.current = undefined;
    deliberatelyHighlighted.current = false;
    setKeyboardIndex(-1);
    update(next);
  };
  const availableSuggestions = suggestions.filter((item) => !isItemDisabled?.(item));
  // Base UI highlights item zero for an empty query too. Put destinations first in its collection
  // while the pinned actions remain visually fixed above the scrolling results.
  const pinnedSet = new Set(pinnedSuggestions);
  const enabledSuggestions = hasPinned
    ? [
        ...availableSuggestions.filter((item) => !pinnedSet.has(item)),
        ...availableSuggestions.filter((item) => pinnedSet.has(item)),
      ]
    : availableSuggestions;
  // The scrolling rows (every enabled suggestion but the pinned actions), whose collection index is
  // their position here: destinations come first in Base UI's collection.
  const scrollingCount = hasPinned
    ? enabledSuggestions.length - availableSuggestions.filter((item) => pinnedSet.has(item)).length
    : enabledSuggestions.length;
  const disabledSuggestions = suggestions.filter((item) => isItemDisabled?.(item) && !pinnedSet.has(item));
  // Once a list has windowed it stays windowed while mounted: a query that narrows it to a few rows
  // and back must not rebuild the window (and measure its rows again) on each key. A list that opens
  // long windows from its first render; one that grows past the bound switches on as it does.
  const [windowing, setWindowing] = useState(() => scrollingCount > COMBOBOX_VIRTUAL_AFTER);
  if (!windowing && scrollingCount > COMBOBOX_VIRTUAL_AFTER) setWindowing(true);
  const virtualized = virtualRows !== undefined || windowing || scrollingCount > COMBOBOX_VIRTUAL_AFTER;
  const hasScroller = hasPinned || virtualized;
  const attachList = useCallback(
    (node: HTMLDivElement | null) => {
      listRef.current = node;
      edges(hasScroller ? null : node);
    },
    [edges, hasScroller],
  );
  // The list opens scrolled to its current row, not its top (Leo, 2026-11-12, on the theme picker:
  // "shouldn't the opened thing be jumped already to the proper place?"). Once per mount, when the
  // current row first renders (suggestions may arrive late); the highlight stays where it was, so a
  // previewing picker previews nothing until the person moves. A list that always highlights its
  // first row stays at its top: Return must never pick a row scrolled out of sight.
  useLayoutEffect(() => {
    if (revealedCurrent.current || !isItemCurrent || autoHighlight === "always") return;
    const index = enabledSuggestions.findIndex((item) => isItemCurrent(item));
    if (index < 0) return;
    if (virtualized) {
      revealedCurrent.current = true;
      if (index < scrollingCount) virtualizer.current?.scrollToIndex(index, { align: "center" });
      return;
    }
    const list = listRef.current;
    const row = list?.querySelector<HTMLElement>('[aria-current="true"]');
    if (!list || !row) return;
    revealedCurrent.current = true;
    revealRow(row, list);
  });
  const update = (next: string) => {
    setValue(next);
    onQuery(next);
  };
  const submit = (next: string) => {
    if (isItemDisabled?.(next)) return;
    if (native && !popupActionByValue(native.model, next)?.keepOpen) setNativeSessionOpen(false);
    onSubmit(next);
  };
  const resolveSubmission = (typed: string, highlighted: string | undefined, deliberate: boolean) => {
    const completed = completionRef.current;
    const completedKey =
      completed?.text === typed && completed.key && enabledSuggestions.includes(completed.key)
        ? completed.key
        : undefined;
    const matchingCurrent =
      completed?.text === typed ? enabledSuggestions.find((item) => completionText?.(item) === typed) : undefined;
    // An unmatched query must not submit an automatically highlighted pinned action.
    const active = highlighted && enabledSuggestions.includes(highlighted) ? highlighted : undefined;
    const selected =
      typed.trim() && hasPinned && active && pinnedSuggestions?.includes(active) && !deliberate ? undefined : active;
    const firstMatch =
      !active && typed.trim() && hasPinned
        ? enabledSuggestions.find((item) => !pinnedSuggestions?.includes(item))
        : undefined;
    return selected ?? completedKey ?? matchingCurrent ?? firstMatch ?? typed;
  };
  const onKeyDown = (event: BaseUIKeyEvent) => {
    onCommand?.(event);
    if (event.defaultPrevented) return;
    if (
      native &&
      (event.key === "ArrowDown" ||
        event.key === "ArrowUp" ||
        (event.ctrlKey && (event.key === "n" || event.key === "p")))
    )
      setNativeSessionOpen(true);
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const typed = event.currentTarget.value;
    if (event.key === "Enter") {
      event.preventDefault();
      event.preventBaseUIHandler?.();
      submit(resolveSubmission(typed, highlightedRef.current, deliberatelyHighlighted.current));
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      event.preventBaseUIHandler?.();
      cancel();
    } else if (event.key === "Tab" && completeOnTab && !event.shiftKey && enabledSuggestions.length) {
      const highlighted = highlightedRef.current;
      const next = highlighted && enabledSuggestions.includes(highlighted) ? highlighted : enabledSuggestions[0]!;
      const completed = completionText?.(next) ?? next;
      if (typed === completed) return;
      event.preventDefault();
      event.preventBaseUIHandler?.();
      completionRef.current = { text: completed, key: next };
      update(completed);
    }
  };
  const renderItemContent = (item: string) => (renderItem ? renderItem(item) : item);
  // The rows' handlers are stable, so a memoized row does not re-render for a new closure; they
  // read the latest `submit` and `isItemDisabled` when they run.
  const latest = useRef({ submit, isItemDisabled });
  useLayoutEffect(() => {
    latest.current = { submit, isItemDisabled };
  });
  const pressStart = useCallback(() => {
    // A new gesture cannot inherit a press whose click was cancelled outside.
    pressActivatedRef.current = undefined;
  }, []);
  const press = useCallback((item: string, event: React.MouseEvent) => {
    if (event.button !== 0) {
      pressActivatedRef.current = undefined;
      return;
    }
    if (latest.current.isItemDisabled?.(item)) return;
    event.preventDefault();
    pressActivatedRef.current = item;
    latest.current.submit(item);
  }, []);
  const click = useCallback((item: string, event: React.MouseEvent) => {
    // A real mouse click follows the primary press and must not submit twice. Keyboard and
    // synthetic detail=0 clicks remain independent even if a press was cancelled outside.
    const pressed = pressActivatedRef.current;
    pressActivatedRef.current = undefined;
    if (pressed === item && event.detail > 0) return;
    // Base UI cancels pointerdown to retain input focus. Browsers then omit the
    // compatibility mousedown, so a primary click must also activate on its own.
    if (event.button === 0) latest.current.submit(item);
  }, []);
  const renderOption = (item: string, index = enabledSuggestions.indexOf(item), placed?: VirtualPlacement) => (
    <ComboboxOption
      key={placed?.key ?? item}
      item={item}
      index={index}
      measure={placed?.ref}
      start={placed?.start}
      setSize={placed?.count}
      label={itemLabel?.(item)}
      current={isItemCurrent?.(item) ?? false}
      className={itemClassName}
      element={hasScroller ? "div" : "li"}
      renderItem={renderItem}
      onPressStart={pressStart}
      onPress={press}
      onClick={click}
    />
  );
  const renderDisabledOption = (item: string, Tag: "div" | "li") => (
    // Disabled options stay out of Base UI's focus and selection collection.
    <Tag
      key={item}
      // A listbox option is not an HTML select option.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="option"
      aria-disabled="true"
      aria-label={itemLabel?.(item)}
      aria-current={isItemCurrent?.(item) ? true : undefined}
      aria-selected="false"
      data-disabled
      className={cx("ui-combobox-item", itemClassName)}
    >
      {renderItemContent(item)}
    </Tag>
  );
  // Keep disabled rows in display order while indexing only keyboard-selectable rows.
  const renderUnpinnedRows = () => {
    let enabledIndex = 0;
    return suggestions.map((item) =>
      isItemDisabled?.(item) ? renderDisabledOption(item, "li") : renderOption(item, enabledIndex++),
    );
  };
  const pinnedRows = (
    <div ref={pinnedEdges} className="ui-combobox-pinned ui-scroll-edge-fade" data-placement={pinnedPlacement}>
      {pinnedSuggestions?.map((item) =>
        isItemDisabled?.(item)
          ? renderDisabledOption(item, "div")
          : renderOption(item, enabledSuggestions.indexOf(item)),
      )}
    </div>
  );
  const list = (
    <Autocomplete.List
      ref={attachList}
      className={cx(
        "ui-combobox-list",
        !hasScroller && "ui-scroll-edge-fade",
        hasScroller ? "ui-combobox-pinned-list" : listClassName,
      )}
      render={hasScroller ? <div /> : <ul />}
      hidden={suggestions.length === 0 && !held}
      aria-hidden={held && suggestions.length === 0 ? true : undefined}
      style={held ? { minHeight: tallest, boxSizing: "border-box" } : undefined}
    >
      {hasPinned && pinnedPlacement === "top" && pinnedRows}
      {hasScroller ? (
        <ScrollArea fade className={cx("ui-combobox-scroll", listClassName)} viewportClassName="ui-combobox-viewport">
          {virtualized ? (
            <VirtualRows
              items={enabledSuggestions}
              count={scrollingCount}
              estimate={virtualRows?.estimate ?? ESTIMATED_ROW_PX}
              sizeKey={virtualRows?.sizeKey}
              keep={keyboardIndex}
              virtualizerRef={virtualizer}
              render={renderOption}
            />
          ) : (
            <Autocomplete.Collection>
              {(item) => (pinnedSet.has(item) ? null : renderOption(item))}
            </Autocomplete.Collection>
          )}
        </ScrollArea>
      ) : (
        renderUnpinnedRows()
      )}
      {hasPinned && listEnd !== undefined && (
        // Inside the listbox, between its scrolling options and its pinned ones: plain text, no role.
        <div role="presentation" className="ui-combobox-list-end">
          {listEnd}
        </div>
      )}
      {hasPinned && pinnedPlacement === "bottom" && pinnedRows}
      {hasScroller && disabledSuggestions.map((item) => renderDisabledOption(item, "div"))}
    </Autocomplete.List>
  );
  // With no pinned actions there is nothing to keep it over: it follows the list.
  const listed =
    hasPinned || listEnd === undefined ? (
      list
    ) : (
      <>
        {list}
        {listEnd}
      </>
    );
  const nativeOnly = nativePopup.available && native !== undefined;
  const input = (
    <Autocomplete.Input
      ref={attachField}
      className={cx("ui-field", inputClassName)}
      aria-label={label}
      placeholder={placeholder}
      readOnly={readOnly}
      spellCheck={false}
      onPointerDown={() => {
        if (native) setNativeSessionOpen(true);
      }}
      onKeyDown={onKeyDown}
      // A press on a suggestion keeps focus in the field (Base UI items are not focusable).
      onBlur={(event) => {
        if (cancelOnBlur && !pressingList.current && !listRef.current?.contains(event.relatedTarget as Node | null))
          cancel();
      }}
    />
  );
  const root = (
    <Autocomplete.Root
      items={enabledSuggestions as string[]}
      filter={null}
      value={value}
      onValueChange={changeQuery}
      open={(!nativeOnly || nativeSessionOpen) && (inline || enabledSuggestions.length > 0)}
      inline={inline}
      autoHighlight={autoHighlight}
      virtualized={virtualized}
      onItemHighlighted={(item, details) => {
        // A virtualized row the arrows reach may not be mounted yet: bring it into view (a pinned
        // action is never in the scroller).
        if (virtualized && details.reason !== "pointer" && details.index >= 0 && details.index < scrollingCount) {
          const index = details.index;
          setKeyboardIndex(index);
          queueMicrotask(() => virtualizer.current?.scrollToIndex(index, { align: "auto" }));
        }
        highlightedRef.current = item as string | undefined;
        if (details.reason === "keyboard" || details.reason === "pointer") deliberatelyHighlighted.current = true;
        onHighlight?.(item as string | undefined, details.reason);
      }}
    >
      {inputRow ? (
        <div className={inputRow.className}>
          {inputRow.start}
          {input}
        </div>
      ) : (
        input
      )}
      {!nativeOnly &&
        (inline ? (
          listed
        ) : (
          <Autocomplete.Portal container={container}>
            <Autocomplete.Positioner className="ui-positioner" sideOffset={2} align="start">
              <Autocomplete.Popup
                ref={host ? setPopup : undefined}
                className="ui-popup ui-glass ui-combobox-popup"
                // Its whole box is the answer to what is typed (popupSettle.ts).
                data-popup-settle="results"
                data-host-glass="menu"
                data-host-glass-cover=""
              >
                {listed}
              </Autocomplete.Popup>
            </Autocomplete.Positioner>
          </Autocomplete.Portal>
        ))}
      {empty !== undefined && (
        // Mounted for as long as the field is, so the live region exists before its text arrives;
        // Base UI renders the children only while no item is left.
        <Autocomplete.Empty className={cx("ui-combobox-empty", emptyClassName)}>
          {suggestions.length === 0 ? empty : null}
        </Autocomplete.Empty>
      )}
    </Autocomplete.Root>
  );
  return rootClassName ? <div className={rootClassName}>{root}</div> : root;
}

/// Centers `row` in the nearest scroller between it and `list` (the list itself, or a pinned list's
/// ScrollArea viewport) when it is not already wholly in view. Only that scroller moves, never the
/// page behind the popup (`scrollIntoView` would scroll every ancestor). A popup laid out after this
/// commit has no height yet: try again on the next frames.
export function revealRow(row: HTMLElement, list: HTMLElement, framesLeft = 3): void {
  let scroller: HTMLElement | null = row.parentElement;
  while (scroller && scroller !== list && scroller.scrollHeight <= scroller.clientHeight) {
    scroller = scroller.parentElement;
  }
  if (!scroller) return;
  if (scroller.clientHeight === 0) {
    if (framesLeft > 0) requestAnimationFrame(() => revealRow(row, list, framesLeft - 1));
    return;
  }
  const view = scroller.getBoundingClientRect();
  const box = row.getBoundingClientRect();
  if (box.top >= view.top && box.bottom <= view.bottom) return;
  scroller.scrollTop += box.top - view.top - (scroller.clientHeight - box.height) / 2;
}

/// The scrolling rows of a virtualized list: only those near the scroller's viewport mount,
/// each placed at its measured offset inside a spacer the full list's height, so the scroller, its
/// thumb and the popover's size read as with every row mounted. The scroller is the ScrollArea's
/// viewport around it. The first frame lays out a menu's worth of rows before the viewport is
/// measured, so the menu never opens empty.
function VirtualRows({
  items,
  count,
  estimate,
  sizeKey,
  keep,
  virtualizerRef,
  render,
}: {
  items: readonly string[];
  count: number;
  estimate: number;
  sizeKey?(item: string): string;
  /** A row kept mounted wherever the list is scrolled (the keyboard's highlight); -1 for none. */
  keep: number;
  virtualizerRef: RefObject<Virtualizer<HTMLElement, Element> | null>;
  render(item: string, index: number, placed: VirtualPlacement): ReactNode;
}) {
  const spacer = useRef<HTMLDivElement | null>(null);
  // The virtualizer caches a row's size by its item (with `sizeKey`, its item and size key, so a
  // row that gains or loses a heading is never given the size it had in the other state). Keyed by
  // index, a row that moves up when one above it leaves would take that row's size.
  const getItemKey = useCallback(
    (index: number) => virtualRowKey(items[index] ?? String(index), sizeKey),
    [items, sizeKey],
  );
  // Rows not yet mounted are sized as the first one measured (the theme's row height and interface
  // scale), so the list's height, and where its end scrolls to, hold as rows mount.
  const [rowHeight, setRowHeight] = useState<number | undefined>(undefined);
  const measured = useRef(false);
  const virtualizer = useVirtualizer<HTMLElement, Element>({
    count,
    getScrollElement: () => spacer.current?.closest<HTMLElement>(".ui-combobox-viewport") ?? null,
    estimateSize: () => rowHeight ?? estimate,
    overscan: 8,
    initialRect: { width: 320, height: 400 },
    getItemKey,
    // A row's slot is its border box plus its vertical margins: a row is placed at its slot's start
    // and its margin-top pushes it down (a section heading drawn in that margin), so a slot of the
    // border box alone would let it cover the next row. A size the library answers from its cache
    // (no resize entry) was measured here already and holds the margins.
    measureElement: (element, entry, instance) => {
      // A row that mounts again (scrolled back, or the menu reopened) has no resize entry: its slot is the one
      // measured here before, margins and all. The library's own answer is its border box alone, which would
      // let a row with a heading in its margin cover the next row (#46018).
      const cached = entry
        ? undefined
        : instance.itemSizeCache.get(instance.options.getItemKey(instance.indexFromElement(element)));
      return virtualRowSlot(cached, () => {
        const style = element.ownerDocument.defaultView?.getComputedStyle(element);
        return virtualRowSize(
          measureElement(element, entry, instance),
          style?.marginTop ?? "",
          style?.marginBottom ?? "",
        );
      });
    },
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      if (keep >= 0 && keep < count && !indexes.includes(keep)) {
        indexes.push(keep);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  virtualizerRef.current = virtualizer;
  useLayoutEffect(() => {
    if (rowHeight !== undefined) virtualizer.measure();
  }, [rowHeight, virtualizer]);
  // Stable while mounted, so learning the row height does not re-render every row.
  const measure = useCallback(
    (node: Element | null) => {
      if (node && !measured.current) {
        const height = node.getBoundingClientRect().height;
        if (height > 0) {
          measured.current = true;
          setRowHeight(height);
        }
      }
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );
  // A DOM with no layout (jsdom, in tests) has no viewport to measure, nor a resize to wait for:
  // list every row, as an unvirtualized list would; nothing is painted there to cost a frame.
  const rows = noLayout()
    ? Array.from({ length: count }, (_, index) => ({ index, start: index * estimate }))
    : virtualizer.getVirtualItems();
  return (
    <div
      ref={spacer}
      role="presentation"
      style={{ position: "relative", width: "100%", height: virtualizer.getTotalSize() }}
    >
      {rows.map((row) => {
        const item = items[row.index];
        // A row whose size key changes is a new element: its ref measures it again.
        return item === undefined
          ? null
          : render(item, row.index, { ref: measure, start: row.start, count, key: virtualRowKey(item, sizeKey) });
      })}
    </div>
  );
}

/// Where VirtualRows puts a row: its measuring ref, its offset, the list's length and its React key.
type VirtualPlacement = { ref: (node: Element | null) => void; start: number; count: number; key: string };

/// A virtual row's identity, as React's key and the virtualizer's size cache key: the item itself,
/// or with `sizeKey` the item and its size key, so each outer size it can have is its own row.
export function virtualRowKey(item: string, sizeKey?: (item: string) => string): string {
  return sizeKey ? `${item}\u0001${sizeKey(item)}` : item;
}

/// A virtual row's slot when its ref attaches: the size measured here before (margins included) when there is one,
/// else a fresh measure. Never the library's bare border box for a row seen before.
export function virtualRowSlot(cached: number | undefined, measure: () => number): number {
  return cached ?? measure();
}

/// A virtual row's slot height: its border-box height and its computed vertical margins (CSS pixel
/// strings such as "20px"). A value that does not parse counts as 0, so the size is never NaN.
export function virtualRowSize(borderBox: number, marginTop: string, marginBottom: string): number {
  const px = (value: number) => (Number.isFinite(value) ? value : 0);
  return Math.round(px(borderBox) + px(Number.parseFloat(marginTop)) + px(Number.parseFloat(marginBottom)));
}

interface ComboboxOptionProps {
  item: string;
  index: number;
  /** Set for a virtualized row: its measuring ref, offset and the list's length. */
  measure?: (node: Element | null) => void;
  start?: number;
  setSize?: number;
  label?: string;
  current: boolean;
  className?: string;
  element: "div" | "li";
  renderItem?(value: string): ReactNode;
  onPressStart(): void;
  onPress(item: string, event: React.MouseEvent): void;
  onClick(item: string, event: React.MouseEvent): void;
}

/// One suggestion row: memoized, so it renders again only when its own props change (Base UI marks
/// the highlighted row itself, through its store).
const ComboboxOption = memo(function ComboboxOption({
  item,
  index,
  measure,
  start,
  setSize,
  label,
  current,
  className,
  element,
  renderItem,
  onPressStart,
  onPress,
  onClick,
}: ComboboxOptionProps) {
  const placed = start !== undefined;
  return (
    <Autocomplete.Item
      index={index}
      value={item}
      {...(placed
        ? {
            ref: measure,
            "data-index": index,
            "aria-posinset": index + 1,
            "aria-setsize": setSize,
            style: virtualRowStyle(start, undefined),
          }
        : {})}
      aria-label={label}
      aria-current={current ? true : undefined}
      className={cx("ui-combobox-item", className)}
      render={element === "div" ? <div /> : <li />}
      onPointerDownCapture={onPressStart}
      onMouseDown={(event) => onPress(item, event)}
      onClick={(event) => onClick(item, event)}
    >
      {renderItem ? renderItem(item) : item}
    </Autocomplete.Item>
  );
});

/// Read at render, not at import: a test installs its DOM's `navigator` after the modules load.
const noLayout = () => typeof navigator !== "undefined" && navigator.userAgent.includes("jsdom");
