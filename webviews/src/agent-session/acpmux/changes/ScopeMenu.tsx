// The changes view's scope pill and menu: Last turn, then the working tree
// (Uncommitted, Unstaged, Staged), then history (Committed, Branch), the chosen one checked.
// It is a menu button: it opens (from a press or an arrow key) on the chosen scope, arrows move through the scopes, Enter or
// Space picks one, and Escape, Tab or a press elsewhere closes it.
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Check, ChevronDown } from "../changeIcons";
import { SCOPE_LABEL, SCOPE_ORDER, type ChangeScope } from "./model";

export function ScopeMenu({
  scope,
  onScope,
  children,
}: {
  scope: ChangeScope;
  onScope: (scope: ChangeScope) => void;
  /// Shown in the pill after the scope's name: its totals.
  children?: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const close = (refocus: boolean) => {
    setOpen(false);
    if (refocus) button.current?.focus();
  };
  useLayoutEffect(() => {
    if (open) menu.current?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => {
      const target = event.target as Node;
      if (!menu.current?.contains(target) && !button.current?.contains(target)) setOpen(false);
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
  }, [open]);
  const onKeyDown = (event: React.KeyboardEvent) => {
    const all = [...(menu.current?.querySelectorAll<HTMLElement>('[role="menuitemradio"]') ?? [])];
    const at = all.indexOf(document.activeElement as HTMLElement);
    const focus = (index: number) => all[(index + all.length) % all.length]?.focus();
    if (event.key === "Escape") {
      // The changes view closes on Escape too; this one is the menu's.
      event.preventDefault();
      event.stopPropagation();
      close(true);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      focus(at + (event.key === "ArrowDown" ? 1 : -1));
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      focus(event.key === "Home" ? 0 : all.length - 1);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      all[at]?.click();
    } else if (event.key === "Tab") close(false);
  };
  return (
    <span className="acpmux-scope-menu">
      <button
        ref={button}
        type="button"
        className="acpmux-diff-scope"
        aria-label={`Changes: ${SCOPE_LABEL[scope]}`}
        aria-haspopup="menu"
        aria-expanded={open}
        // WebKit does not focus a clicked button, so closing from it puts focus there.
        onClick={() => (open ? close(true) : setOpen(true))}
        onKeyDown={(event) => {
          if (open || (event.key !== "ArrowDown" && event.key !== "ArrowUp")) return;
          event.preventDefault();
          setOpen(true);
        }}
      >
        <strong>{SCOPE_LABEL[scope]}</strong>
        <ChevronDown className="acpmux-scope-chevron" />
        {children}
      </button>
      {open && (
        <div
          ref={menu}
          role="menu"
          tabIndex={-1}
          className="acpmux-file-menu-list acpmux-scope-list"
          aria-label="Changes to show"
          onKeyDown={onKeyDown}
        >
          {SCOPE_ORDER.map((entry, index) =>
            entry === null ? (
              <hr key={`separator-${index}`} className="acpmux-scope-separator" />
            ) : (
              <button
                key={entry}
                type="button"
                role="menuitemradio"
                aria-checked={entry === scope}
                tabIndex={-1}
                className="acpmux-file-menu-item"
                onClick={() => {
                  close(true);
                  onScope(entry);
                }}
              >
                <span className="acpmux-scope-label">{SCOPE_LABEL[entry]}</span>
                {entry === scope && <Check />}
              </button>
            ),
          )}
        </div>
      )}
    </span>
  );
}
