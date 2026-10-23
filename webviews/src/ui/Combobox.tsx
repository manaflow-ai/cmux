// A text field with suggestions over Base UI Autocomplete (a popup listbox under the field). The
// caller computes the suggestions (they may arrive asynchronously) from `onQuery`. Return submits
// the highlighted suggestion or the typed text, Tab completes, Escape cancels; Base UI owns the
// combobox role, aria-activedescendant and the arrows.
import { useCallback, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { cx } from "./cx";

type BaseUIKeyEvent = KeyboardEvent<HTMLInputElement> & { preventBaseUIHandler?: () => void };

export interface ComboboxProps {
  /** The field's text when it opens. */
  defaultValue?: string;
  suggestions: readonly string[];
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
  /** The highlighted suggestion changed; undefined when none is. `by` says whether the arrow keys
   * ("keyboard") or the pointer ("pointer") moved it, so a caller can treat a passing pointer as
   * less deliberate than a key press. */
  onHighlight?(value: string | undefined, by: "keyboard" | "pointer" | "none"): void;
}

export function Combobox({
  defaultValue = "",
  suggestions,
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
  onHighlight,
}: ComboboxProps) {
  const container = usePortalContainer();
  // A popup list with no room above or below its field: past the window's edge (popupHost.ts).
  // The field keeps the focus; the list's highlight is Base UI's data-highlighted.
  const host = usePopupHost();
  const [field, setField] = useState<HTMLInputElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
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
  const listRef = useRef<HTMLDivElement>(null);
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
      const next = highlighted && suggestions.includes(highlighted) ? highlighted : typed;
      if (!isItemDisabled?.(next)) onSubmit(next);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      event.preventBaseUIHandler?.();
      onCancel();
    } else if (event.key === "Tab" && !event.shiftKey && suggestions.length) {
      event.preventDefault();
      event.preventBaseUIHandler?.();
      update(highlightedRef.current ?? suggestions[0]);
    }
  };
  const enabledSuggestions = suggestions.filter((item) => !isItemDisabled?.(item));
  const disabledSuggestions = suggestions.filter((item) => isItemDisabled?.(item));
  const renderItemContent = (item: string) => (renderItem ? renderItem(item) : item);
  const list = (
    <Autocomplete.List
      ref={listRef}
      className={cx("ui-combobox-list", listClassName)}
      render={<ul />}
      hidden={suggestions.length === 0 && !held}
      aria-hidden={held && suggestions.length === 0 ? true : undefined}
      style={held ? { minHeight: tallest, boxSizing: "border-box" } : undefined}
    >
      <Autocomplete.Collection>
        {(item: string) => (
          <Autocomplete.Item
            key={item}
            value={item}
            className={cx("ui-combobox-item", itemClassName)}
            render={<li />}
            onClick={() => onSubmit(item)}
          >
            {renderItemContent(item)}
          </Autocomplete.Item>
        )}
      </Autocomplete.Collection>
      {disabledSuggestions.map((item) => (
        <li
          key={item}
          // The disabled rows stay out of Base UI's collection, but retain listbox semantics.
          // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-to-interactive-role, jsx-a11y/prefer-tag-over-role
          role="option"
          aria-disabled="true"
          aria-selected="false"
          data-disabled
          className={cx("ui-combobox-item", itemClassName)}
        >
          {renderItemContent(item)}
        </li>
      ))}
    </Autocomplete.List>
  );
  const root = (
    <Autocomplete.Root
      items={enabledSuggestions as string[]}
      filter={null}
      value={value}
      onValueChange={(next) => update(next)}
      open={inline || enabledSuggestions.length > 0}
      inline={inline}
      autoHighlight={autoHighlight}
      onItemHighlighted={(item, details) => {
        highlightedRef.current = item as string | undefined;
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
        onBlur={() => {
          if (cancelOnBlur) onCancel();
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
