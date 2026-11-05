// A text field with suggestions over Base UI Autocomplete (a popup listbox under the field). The
// caller computes the suggestions (they may arrive asynchronously) from `onQuery`. Return submits
// the highlighted suggestion or the typed text, Tab completes, Escape cancels; Base UI owns the
// combobox role, aria-activedescendant and the arrows.
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { useVirtualizer, type Virtualizer } from "@tanstack/react-virtual";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";
import { ScrollArea } from "./ScrollArea";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./popupProtocol";
import { popupAction, popupActionByValue, popupSearchId } from "./popupDescriptors";

type BaseUIKeyEvent = KeyboardEvent<HTMLInputElement> & { preventBaseUIHandler?: () => void };

export interface ComboboxProps {
  /** The field's text when it opens. */
  defaultValue?: string;
  suggestions: readonly string[];
  /** Leading actions remain below the field while the remaining suggestions scroll. */
  pinnedSuggestions?: readonly string[];
  /** The text changed (typing, completion): compute new suggestions. */
  onQuery(value: string): void;
  /** Return: the highlighted suggestion, else the text. */
  onSubmit(value: string): void;
  /** Escape, or focus leaving the field. */
  onCancel(): void;
  label: string;
  placeholder?: string;
  inputClassName?: string;
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
  itemLabel?(value: string): string;
  /** The committed choice, distinct from the transient keyboard highlight. */
  isItemCurrent?(value: string): boolean;
  /** Readable Tab completion for suggestions identified by an opaque key. */
  completionText?(value: string): string;
  /** The highlighted suggestion changed; undefined when none is. `by` says whether the arrow keys
   * ("keyboard") or the pointer ("pointer") moved it, so a caller can treat a passing pointer as
   * less deliberate than a key press. */
  onHighlight?(value: string | undefined, by: "keyboard" | "pointer" | "none"): void;
  /** With `pinnedSuggestions`: only the scrolling rows near the viewport are in the DOM (TanStack
   * Virtual over the list's own scroller), so a list of thousands (the Projects picker, Leo
   * 2026-11-04: "opening the project picker lags like shit since we have so many") opens in a
   * frame. `estimate` is a row's height in pixels before it is measured. */
  virtualRows?: { estimate: number };
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
  onQuery,
  onSubmit,
  onCancel,
  label,
  placeholder,
  inputClassName,
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
  onHighlight,
  native,
  virtualRows,
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
  const attachList = useCallback(
    (node: HTMLDivElement | null) => {
      listRef.current = node;
      edges(hasPinned ? null : node);
    },
    [edges, hasPinned],
  );
  const deliberatelyHighlighted = useRef(false);
  const virtualized = hasPinned && virtualRows !== undefined;
  const virtualizer = useRef<Virtualizer<HTMLElement, Element> | null>(null);
  const changeQuery = (next: string) => {
    if (native) setNativeSessionOpen(true);
    // Base UI resets a plain list's scroller on typing; a virtualized one is ours to reset.
    if (virtualized) virtualizer.current?.scrollToOffset(0);
    if (completionRef.current?.text !== next) completionRef.current = undefined;
    deliberatelyHighlighted.current = false;
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
    : 0;
  const disabledSuggestions = suggestions.filter((item) => isItemDisabled?.(item) && !pinnedSet.has(item));
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
    } else if (event.key === "Tab" && !event.shiftKey && enabledSuggestions.length) {
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
  const renderOption = (
    item: string,
    index = enabledSuggestions.indexOf(item),
    placed?: { ref: (node: Element | null) => void; start: number; count: number },
  ) => (
    <Autocomplete.Item
      key={item}
      index={index}
      value={item}
      {...(placed
        ? {
            ref: placed.ref,
            "data-index": index,
            "aria-posinset": index + 1,
            "aria-setsize": placed.count,
            style: {
              position: "absolute",
              top: 0,
              left: 0,
              width: "100%",
              transform: `translateY(${placed.start}px)`,
            } satisfies CSSProperties,
          }
        : {})}
      aria-label={itemLabel?.(item)}
      aria-current={isItemCurrent?.(item) ? true : undefined}
      className={cx("ui-combobox-item", itemClassName)}
      render={hasPinned ? <div /> : <li />}
      onPointerDownCapture={() => {
        // A new gesture cannot inherit a press whose click was cancelled outside.
        pressActivatedRef.current = undefined;
      }}
      onMouseDown={(event) => {
        if (event.button !== 0) {
          pressActivatedRef.current = undefined;
          return;
        }
        if (isItemDisabled?.(item)) return;
        event.preventDefault();
        pressActivatedRef.current = item;
        submit(item);
      }}
      onClick={(event) => {
        // A real mouse click follows the primary press and must not submit twice. Keyboard and
        // synthetic detail=0 clicks remain independent even if a press was cancelled outside.
        const pressed = pressActivatedRef.current;
        pressActivatedRef.current = undefined;
        if (pressed === item && event.detail > 0) return;
        // Base UI cancels pointerdown to retain input focus. Browsers then omit the
        // compatibility mousedown, so a primary click must also activate on its own.
        if (event.button === 0) submit(item);
      }}
    >
      {renderItemContent(item)}
    </Autocomplete.Item>
  );
  const list = (
    <Autocomplete.List
      ref={attachList}
      className={cx(
        "ui-combobox-list",
        !hasPinned && "ui-scroll-edge-fade",
        hasPinned ? "ui-combobox-pinned-list" : listClassName,
      )}
      render={hasPinned ? <div /> : <ul />}
      hidden={suggestions.length === 0 && !held}
      aria-hidden={held && suggestions.length === 0 ? true : undefined}
      style={held ? { minHeight: tallest, boxSizing: "border-box" } : undefined}
    >
      {hasPinned && (
        <div ref={pinnedEdges} className="ui-combobox-pinned ui-scroll-edge-fade">
          {pinnedSuggestions!.map((item) => renderOption(item, enabledSuggestions.indexOf(item)))}
        </div>
      )}
      {hasPinned ? (
        <ScrollArea fade className={cx("ui-combobox-scroll", listClassName)} viewportClassName="ui-combobox-viewport">
          {virtualized && virtualRows ? (
            <VirtualRows
              items={enabledSuggestions}
              count={scrollingCount}
              estimate={virtualRows.estimate}
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
        <Autocomplete.Collection>{(item: string, index: number) => renderOption(item, index)}</Autocomplete.Collection>
      )}
      {disabledSuggestions.map((item) => (
        <li
          key={item}
          // The disabled rows stay out of Base UI's collection, but retain listbox semantics.
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-to-interactive-role, jsx-a11y/prefer-tag-over-role
          role="option"
          aria-disabled="true"
          aria-label={itemLabel?.(item)}
          aria-current={isItemCurrent?.(item) ? true : undefined}
          aria-selected="false"
          data-disabled
          className={cx("ui-combobox-item", itemClassName)}
        >
          {renderItemContent(item)}
        </li>
      ))}
    </Autocomplete.List>
  );
  const nativeOnly = nativePopup.available && native !== undefined;
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
          queueMicrotask(() => virtualizer.current?.scrollToIndex(index, { align: "auto" }));
        }
        highlightedRef.current = item as string | undefined;
        if (details.reason === "keyboard" || details.reason === "pointer") deliberatelyHighlighted.current = true;
        onHighlight?.(item as string | undefined, details.reason);
      }}
    >
      <Autocomplete.Input
        ref={attachField}
        className={cx("ui-field", inputClassName)}
        aria-label={label}
        placeholder={placeholder}
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
      {!nativeOnly &&
        (inline ? (
          list
        ) : (
          <Autocomplete.Portal container={container}>
            <Autocomplete.Positioner className="ui-positioner" sideOffset={2} align="start">
              <Autocomplete.Popup ref={host ? setPopup : undefined} className="ui-popup ui-glass ui-combobox-popup">
                {list}
              </Autocomplete.Popup>
            </Autocomplete.Positioner>
          </Autocomplete.Portal>
        ))}
    </Autocomplete.Root>
  );
  return rootClassName ? <div className={rootClassName}>{root}</div> : root;
}

/// The scrolling rows of a virtualized pinned list: only those near the scroller's viewport mount,
/// each placed at its measured offset inside a spacer the full list's height, so the scroller, its
/// thumb and the popover's size read as with every row mounted. The scroller is the ScrollArea's
/// viewport around it. The first frame lays out a menu's worth of rows before the viewport is
/// measured, so the menu never opens empty.
function VirtualRows({
  items,
  count,
  estimate,
  virtualizerRef,
  render,
}: {
  items: readonly string[];
  count: number;
  estimate: number;
  virtualizerRef: RefObject<Virtualizer<HTMLElement, Element> | null>;
  render(
    item: string,
    index: number,
    placed: { ref: (node: Element | null) => void; start: number; count: number },
  ): ReactNode;
}) {
  const spacer = useRef<HTMLDivElement | null>(null);
  // Rows not yet mounted are sized as the first one measured (the theme's row height and interface
  // scale), so the list's height, and where its end scrolls to, hold as rows mount.
  const [rowHeight, setRowHeight] = useState<number | undefined>(undefined);
  const virtualizer = useVirtualizer<HTMLElement, Element>({
    count,
    getScrollElement: () => spacer.current?.closest<HTMLElement>(".ui-combobox-viewport") ?? null,
    estimateSize: () => rowHeight ?? estimate,
    overscan: 8,
    initialRect: { width: 320, height: 400 },
  });
  virtualizerRef.current = virtualizer;
  useLayoutEffect(() => {
    if (rowHeight !== undefined) virtualizer.measure();
  }, [rowHeight, virtualizer]);
  const measure = useCallback(
    (node: Element | null) => {
      if (node && rowHeight === undefined) {
        const height = node.getBoundingClientRect().height;
        if (height > 0) setRowHeight(height);
      }
      virtualizer.measureElement(node);
    },
    [rowHeight, virtualizer],
  );
  // A DOM with no layout (jsdom, in tests) measures every box as zero: list every row, as an
  // unvirtualized list would; nothing is painted there to cost a frame.
  const rows =
    NO_LAYOUT && virtualizer.scrollRect?.height === 0
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
        return item === undefined ? null : render(item, row.index, { ref: measure, start: row.start, count });
      })}
    </div>
  );
}

const NO_LAYOUT = typeof navigator !== "undefined" && navigator.userAgent.includes("jsdom");
