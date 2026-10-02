import React, { useEffect, useId, useRef } from "react";
import { ChevronIcon, PICKER_LABELS } from "./ComposerPickers";
import type { ModelPickerVariant } from "./modelPickerVariant";

/// The model chip and the popover above it, shared by the picker variants. Focus stays on the
/// chip while the popover is open, so typing, arrows, digits and Return reach `onKeyDown`;
/// a press elsewhere, the window losing focus, or focus leaving the chip closes it.
export function ModelPickerShell({
  variant,
  chip,
  open,
  onOpenChange,
  onKeyDown,
  onPointerMove,
  activeId,
  trigger,
  menu,
  children,
}: {
  variant: Exclude<ModelPickerVariant, "current">;
  chip: string;
  open: boolean;
  onOpenChange(open: boolean): void;
  onKeyDown(event: React.KeyboardEvent): void;
  onPointerMove?(event: React.PointerEvent): void;
  /// The highlighted row's id, for screen readers following the keys.
  activeId?: string;
  trigger: React.RefObject<HTMLButtonElement | null>;
  menu?: React.RefObject<HTMLDivElement | null>;
  children: React.ReactNode;
}) {
  const root = useRef<HTMLSpanElement>(null);
  const menuId = useId();
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) onOpenChange(false);
    };
    const blur = () => onOpenChange(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [open, onOpenChange]);
  return (
    <span
      ref={root}
      className="acpmux-picker acpmux-model"
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) onOpenChange(false);
      }}
    >
      <button
        ref={trigger}
        type="button"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="combobox"
        className="acpmux-picker-button"
        aria-label={PICKER_LABELS.model}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-activedescendant={open ? activeId : undefined}
        onKeyDown={(event) => {
          if (open) onKeyDown(event);
          else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
            event.preventDefault();
            onOpenChange(true);
          }
        }}
        onClick={() => {
          onOpenChange(!open);
          // WebKit doesn't focus a clicked button; the keys must reach the menu, not the prompt.
          trigger.current?.focus();
        }}
      >
        <span className="acpmux-model-name">{chip}</span>
        <ChevronIcon />
      </button>
      {open && (
        <div
          ref={menu}
          id={menuId}
          className={`acpmux-menu acpmux-menu-end acpmux-mp acpmux-mp-${variant}`}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="menu"
          aria-label={PICKER_LABELS.model}
          onPointerMove={onPointerMove}
        >
          {children}
        </div>
      )}
    </span>
  );
}
