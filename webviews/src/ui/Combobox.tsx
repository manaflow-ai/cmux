// A text field with suggestions over Base UI Autocomplete (a popup listbox under the field). The
// caller computes the suggestions (they may arrive asynchronously) from `onQuery`. Return submits
// the highlighted suggestion or the typed text, Tab completes, Escape cancels; Base UI owns the
// combobox role, aria-activedescendant and the arrows.
import { useState, type KeyboardEvent, type ReactNode } from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { usePortalContainer } from "./UiProvider";
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
  /** Keep a multi-control panel open when focus moves to its buttons. */
  cancelOnBlur?: boolean;
  /** Disabled rows remain visible but cannot be highlighted or submitted. */
  isItemDisabled?(value: string): boolean;
  autoHighlight?: boolean;
  /** Handle a shortcut while the Base UI input owns focus. */
  onCommand?(event: KeyboardEvent<HTMLInputElement>): void;
  /** Class for the Base UI root when the field and list are laid out together. */
  rootClassName?: string;
  /** A row's content (a name over a path); default: the suggestion text. The row still submits
   * and completes its suggestion string. */
  renderItem?(value: string): ReactNode;
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
  cancelOnBlur = true,
  isItemDisabled,
  autoHighlight = false,
  onCommand,
  rootClassName,
  renderItem,
}: ComboboxProps) {
  const container = usePortalContainer();
  const [value, setValue] = useState(defaultValue);
  const [highlighted, setHighlighted] = useState<string | undefined>(undefined);
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
      update(highlighted ?? suggestions[0]);
    }
  };
  const list = (
    <Autocomplete.List
      className={cx("ui-combobox-list", listClassName)}
      render={<ul />}
      hidden={suggestions.length === 0}
    >
      {(item: string) => (
        <Autocomplete.Item
          key={item}
          value={item}
          disabled={isItemDisabled?.(item)}
          className={cx("ui-combobox-item", itemClassName)}
          render={<li />}
          onClick={() => {
            if (!isItemDisabled?.(item)) onSubmit(item);
          }}
        >
          {renderItem ? renderItem(item) : item}
        </Autocomplete.Item>
      )}
    </Autocomplete.List>
  );
  const root = (
    <Autocomplete.Root
      items={suggestions as string[]}
      filter={null}
      value={value}
      onValueChange={(next) => update(next)}
      open={inline || suggestions.length > 0}
      inline={inline}
      autoHighlight={autoHighlight}
      onItemHighlighted={(item) => setHighlighted(item as string | undefined)}
    >
      <Autocomplete.Input
        ref={inputRef}
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
            <Autocomplete.Popup className="ui-popup ui-combobox-popup">{list}</Autocomplete.Popup>
          </Autocomplete.Positioner>
        </Autocomplete.Portal>
      )}
    </Autocomplete.Root>
  );
  return rootClassName ? <div className={rootClassName}>{root}</div> : root;
}
