// A text field with suggestions over Base UI Autocomplete (a popup listbox under the field). The
// caller computes the suggestions (they may arrive asynchronously) from `onQuery`. Return submits
// the highlighted suggestion or the typed text, Tab completes, Escape cancels; Base UI owns the
// combobox role, aria-activedescendant and the arrows.
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { cx } from "./cx";
import { ScrollArea } from "./ScrollArea";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./generated/popupProtocol";

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
  /** Declarative native rows. When the host is available the web list is not mounted. */
  native?: { model: NativePopupDescription; anchor?: () => HTMLElement | null; onEvent?(event: NativePopupEvent): void; onDismiss?(): void };
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
}: ComboboxProps) {
  const container = usePortalContainer();
  // A popup list with no room above or below its field: past the window's edge (popupHost.ts).
  // The field keeps the focus; the list's highlight is Base UI's data-highlighted.
  const host = usePopupHost();
  const [field, setField] = useState<HTMLInputElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  const nativePopup = useNativePopup({
    open: native !== undefined,
    model: native?.model ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: native?.anchor ?? (() => field),
    onEvent: (event) => {
      native?.onEvent?.(event);
      if ((event.type === "search" || event.type === "change") && event.value !== undefined) onQuery(event.value);
      else if (event.type === "pick" && event.value !== undefined) onSubmit(event.value);
      else if (event.type === "highlight") onHighlight?.(event.id, "pointer");
    },
    onDismiss: () => {
      native?.onDismiss?.();
      onCancel();
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
  const [value, setValue] = useState(defaultValue);
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
  const deliberatelyHighlighted = useRef(false);
  const availableSuggestions = suggestions.filter((item) => !isItemDisabled?.(item));
  // Base UI highlights item zero for an empty query too. Put destinations first in its collection
  // while the pinned actions remain visually fixed above the scrolling results.
  const enabledSuggestions = hasPinned
    ? [
        ...availableSuggestions.filter((item) => !pinnedSuggestions?.includes(item)),
        ...availableSuggestions.filter((item) => pinnedSuggestions?.includes(item)),
      ]
    : availableSuggestions;
  const disabledSuggestions = suggestions.filter(
    (item) => isItemDisabled?.(item) && !pinnedSuggestions?.includes(item),
  );
  const update = (next: string) => {
    setValue(next);
    onQuery(next);
  };
  const onKeyDown = (event: BaseUIKeyEvent) => {
    onCommand?.(event);
    if (event.defaultPrevented) return;
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const typed = event.currentTarget.value;
    if (event.key === "Enter") {
      event.preventDefault();
      event.preventBaseUIHandler?.();
      const highlighted = highlightedRef.current;
      const completed = completionRef.current;
      const completedKey =
        completed?.text === typed && completed.key && enabledSuggestions.includes(completed.key)
          ? completed.key
          : undefined;
      const matchingCurrent =
        completed?.text === typed ? enabledSuggestions.find((item) => completionText?.(item) === typed) : undefined;
      // An unmatched query must not submit an automatically highlighted action.
      // Explicit arrow or pointer highlight still makes that pinned action selectable.
      const active = highlighted && enabledSuggestions.includes(highlighted) ? highlighted : undefined;
      const selected =
        typed.trim() && hasPinned && active && pinnedSuggestions?.includes(active) && !deliberatelyHighlighted.current
          ? undefined
          : active;
      const firstMatch =
        !active && typed.trim() && hasPinned
          ? enabledSuggestions.find((item) => !pinnedSuggestions?.includes(item))
          : undefined;
      const next = selected ?? completedKey ?? matchingCurrent ?? firstMatch ?? typed;
      if (!isItemDisabled?.(next)) onSubmit(next);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      event.preventBaseUIHandler?.();
      onCancel();
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
  const renderOption = (item: string, index = enabledSuggestions.indexOf(item)) => (
    <Autocomplete.Item
      key={item}
      index={index}
      value={item}
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
        onSubmit(item);
      }}
      onClick={(event) => {
        // A real mouse click follows the primary press and must not submit twice. Keyboard and
        // synthetic detail=0 clicks remain independent even if a press was cancelled outside.
        const pressed = pressActivatedRef.current;
        pressActivatedRef.current = undefined;
        if (pressed === item && event.detail > 0) return;
        // Base UI cancels pointerdown to retain input focus. Browsers then omit the
        // compatibility mousedown, so a primary click must also activate on its own.
        if (event.button === 0 && !isItemDisabled?.(item)) onSubmit(item);
      }}
    >
      {renderItemContent(item)}
    </Autocomplete.Item>
  );
  const list = (
    <Autocomplete.List
      ref={listRef}
      className={cx("ui-combobox-list", hasPinned ? "ui-combobox-pinned-list" : listClassName)}
      render={hasPinned ? <div /> : <ul />}
      hidden={suggestions.length === 0 && !held}
      aria-hidden={held && suggestions.length === 0 ? true : undefined}
      style={held ? { minHeight: tallest, boxSizing: "border-box" } : undefined}
    >
      {hasPinned && (
        <div className="ui-combobox-pinned">
          {pinnedSuggestions!.map((item) => renderOption(item, enabledSuggestions.indexOf(item)))}
        </div>
      )}
      {hasPinned ? (
        <ScrollArea className={cx("ui-combobox-scroll", listClassName)} viewportClassName="ui-combobox-viewport">
          <Autocomplete.Collection>
            {(item) => (pinnedSuggestions!.includes(item) ? null : renderOption(item))}
          </Autocomplete.Collection>
        </ScrollArea>
      ) : (
        <Autocomplete.Collection>{renderOption}</Autocomplete.Collection>
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
  if (nativePopup.available && native !== undefined) return null;
  const root = (
    <Autocomplete.Root
      items={enabledSuggestions as string[]}
      filter={null}
      value={value}
      onValueChange={(next) => {
        if (completionRef.current?.text !== next) completionRef.current = undefined;
        deliberatelyHighlighted.current = false;
        update(next);
      }}
      open={inline || enabledSuggestions.length > 0}
      inline={inline}
      autoHighlight={autoHighlight}
      onItemHighlighted={(item, details) => {
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
        onKeyDown={onKeyDown}
        // A press on a suggestion keeps focus in the field (Base UI items are not focusable).
        onBlur={(event) => {
          if (cancelOnBlur && !pressingList.current && !listRef.current?.contains(event.relatedTarget as Node | null))
            onCancel();
        }}
      />
      {inline ? (
        list
      ) : (
        <Autocomplete.Portal container={container}>
          <Autocomplete.Positioner className="ui-positioner" sideOffset={2} align="start">
            <Autocomplete.Popup ref={host ? setPopup : undefined} className="ui-popup ui-glass ui-combobox-popup">
              {list}
            </Autocomplete.Popup>
          </Autocomplete.Positioner>
        </Autocomplete.Portal>
      )}
    </Autocomplete.Root>
  );
  return rootClassName ? <div className={rootClassName}>{root}</div> : root;
}
