// A cascade: a menu that opens BESIDE the row of its parent popover, which stays open and clickable
// (Leo, 2026-11-23, of a drill-in that replaced the parent menu: "i cant click back"; he approved
// the cascade: "just like how cloud goes to another chevron"). A row with a chevron owns one.
//
//   <Popover ...>                      // the parent: its list, its search
//     {rows}
//     <CascadeMenu
//       open={cascade === "cloud"}
//       anchor={cloudRowElement}       // the parent's row; the cascade lines up with its top
//       label="Cloud"
//       focusIn={openedByKey}          // true when ArrowRight (or Return) opened it: focus moves in
//       onClose={(refocus) => { setCascade(undefined); if (refocus) parentInput.focus(); }}
//       onPointerEnter={keepOpen}      // optional: the pointer reached the cascade (cancel a close timer)
//     >
//       <CascadeOptions options={[{ id: "auto", label: "Auto", detail: "Default", checked: true, onSelect }]}
//         onClose={...} />             // or any content: a search field and rows (Combobox), say
//     </CascadeMenu>
//   </Popover>
//
// Keys, one level at a time: ← and Escape close the cascade and give focus back to the parent
// (`onClose(true)`); → on a parent row opens it (the parent's own handler, `focusIn`). A press
// outside both closes the parent, which takes the cascade with it: the cascade never closes on a
// press (the parent's rows are its own neighbours, so clicking one is no outside press). Render it
// as a React child of the parent Popover so Base UI treats the two as one tree.
import { useEffect, useRef, type KeyboardEvent, type ReactNode } from "react";
import { Popover, type UiAnchor } from "./Popover";
import { cx } from "./cx";

export interface CascadeMenuProps {
  open: boolean;
  /** The parent's row the cascade opens beside. */
  anchor: UiAnchor;
  /** The cascade's accessible name. */
  label: string;
  /** True when the keyboard opened it: focus moves to its first field or row. A hover leaves focus
   *  in the parent, so typing still searches there. */
  focusIn?: boolean;
  /** The cascade asks to close: `refocus` is true when a key did (give the parent's field focus). */
  onClose(refocus: boolean): void;
  /** The pointer is over the cascade (a parent's close-on-leave timer cancels on it). */
  onPointerEnter?(): void;
  onPointerLeave?(): void;
  className?: string;
  children: ReactNode;
}

export function CascadeMenu({
  open,
  anchor,
  label,
  focusIn = false,
  onClose,
  onPointerEnter,
  onPointerLeave,
  className,
  children,
}: CascadeMenuProps) {
  return (
    <Popover
      open={open}
      onOpenChange={(next, details) => {
        // The parent owns presses outside; Escape and ← are the cascade's own.
        if (!next && !details?.outsidePress) onClose(details?.escape === true);
      }}
      anchor={open ? anchor : null}
      label={label}
      className={cx("ui-cascade", className)}
      side="inline-end"
      align="start"
      flip
      initialFocus={focusIn}
      finalFocus={false}
    >
      <div
        className="ui-cascade-body"
        onPointerEnter={onPointerEnter}
        onPointerLeave={onPointerLeave}
        onKeyDown={(event) => {
          // A search field keeps ← for its caret until it is empty.
          if (event.key !== "ArrowLeft" || event.defaultPrevented) return;
          // By tag, not instanceof: the element may come from another window's realm (a test DOM, a frame).
          const target = event.target as HTMLInputElement;
          if (target.tagName === "INPUT" && target.value !== "") return;
          event.preventDefault();
          event.stopPropagation();
          onClose(true);
        }}
      >
        {children}
      </div>
    </Popover>
  );
}

/** One row of a cascade's short list. */
export interface CascadeOption {
  id: string;
  label: string;
  /** A second line (how it runs, "Default"). */
  detail?: string;
  /** The current pick: drawn with a check. */
  checked?: boolean;
  icon?: ReactNode;
  disabled?: boolean;
  onSelect(): void;
}

/**
 * A cascade's short list (Cloud's: Auto, each cloud we serve, Hybrid start): rows with a check on
 * the current one, ↑ ↓ to move, Return to pick, Escape or ← to go back. A long list is a Combobox
 * with a search field instead (the Agent machines cascade).
 */
export function CascadeOptions({
  options,
  focusIn = false,
  onClose,
  label,
}: {
  options: readonly CascadeOption[];
  focusIn?: boolean;
  onClose(refocus: boolean): void;
  label: string;
}) {
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!focusIn) return;
    const rows = list.current?.querySelectorAll<HTMLElement>("[role=menuitemradio]:not([aria-disabled=true])");
    const first = list.current?.querySelector<HTMLElement>("[aria-checked=true]") ?? rows?.[0];
    first?.focus();
  }, [focusIn]);
  const move = (event: KeyboardEvent<HTMLDivElement>) => {
    const rows = [
      ...(list.current?.querySelectorAll<HTMLElement>("[role=menuitemradio]:not([aria-disabled=true])") ?? []),
    ];
    const at = rows.indexOf(document.activeElement as HTMLElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = event.key === "ArrowDown" ? at + 1 : at - 1;
      rows[(next + rows.length) % rows.length]?.focus();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose(true);
    }
  };
  return (
    <div ref={list} className="ui-cascade-options" role="menu" aria-label={label} onKeyDown={move}>
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          role="menuitemradio"
          aria-checked={option.checked === true}
          aria-disabled={option.disabled ? true : undefined}
          className="acpmux-menu-item acpmux-location-row ui-cascade-option"
          data-current={option.checked ? "" : undefined}
          data-ready={option.disabled ? "false" : undefined}
          onClick={() => {
            if (!option.disabled) option.onSelect();
          }}
        >
          {option.icon}
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{option.label}</span>
            {option.detail && <span className="acpmux-menu-description">{option.detail}</span>}
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {option.checked && "✓"}
          </span>
        </button>
      ))}
    </div>
  );
}
