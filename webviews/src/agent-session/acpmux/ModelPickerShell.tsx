import React, { useEffect, useId, useRef } from "react";
import { ChevronIcon, PICKER_LABELS } from "./ComposerPickers";
import type { PickerLayout } from "./modelPickerLayout";
import { registerPicker } from "./pickerOpeners";
import { useT } from "./i18n";
import { useUiAnchor } from "../../ui/anchor";
import { usePopoverTrigger } from "../../ui/popoverTrigger";

/// The model chip, which names the effort after the model with one chevron, and the popover
/// above it, which holds both. Focus stays on the chip while the popover is open,
/// so typing, arrows, digits and Return reach `onKeyDown`; a press elsewhere, the window losing
/// focus, or focus leaving the chip closes it. The open menu's body names its highlighted row
/// on the chip (aria-activedescendant) itself.
export function ModelPickerShell({
  layout,
  chip,
  detail,
  offersEffort = false,
  open,
  onOpenChange,
  onKeyDown,
  onPointerMove,
  trigger,
  menu,
  children,
}: {
  /// Unset for the first frame of an opening, while ModelPicker measures the cascade's room.
  layout?: PickerLayout;
  chip: string;
  detail?: string;
  /// The menu holds the effort too, so automation's "Effort" opens it.
  offersEffort?: boolean;
  open: boolean;
  onOpenChange(open: boolean): void;
  onKeyDown(event: React.KeyboardEvent): void;
  onPointerMove?(event: React.PointerEvent): void;
  trigger: React.RefObject<HTMLButtonElement | null>;
  menu: React.RefObject<HTMLDivElement | null>;
  children: React.ReactNode;
}) {
  const t = useT();
  const modelLabel = t(PICKER_LABELS.model);
  const effortLabel = t(PICKER_LABELS.effort);
  const root = useRef<HTMLSpanElement>(null);
  const menuId = useId();
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
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
  // Opens the menu (never toggles it shut) and keeps the keys on the chip, as a click does.
  const show = () => {
    if (!open) onOpenChange(true);
    // WebKit doesn't focus a clicked button; the keys must reach the menu, not the prompt.
    trigger.current?.focus();
  };
  const showRef = useRef(show);
  showRef.current = show;
  // Automation opens the menu by its label through the click path, which takes focus off the
  // prompt first: that closes the slash menu and restores the draft.
  useEffect(() => {
    const open = () => {
      const focused = document.activeElement;
      // Focus already on the chip stays there: blurring it would close the open menu.
      if (focused instanceof HTMLElement && !root.current?.contains(focused)) focused.blur();
      showRef.current();
    };
    const unregister = registerPicker(modelLabel, open);
    const unregisterEffort = offersEffort ? registerPicker(effortLabel, open) : undefined;
    return () => {
      unregister();
      unregisterEffort?.();
    };
  }, [modelLabel, effortLabel, offersEffort]);
  const press = usePopoverTrigger(open, onOpenChange, show);
  return (
    <span
      ref={root}
      className="acpmux-picker acpmux-model"
      style={{ position: "relative" }}
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
        data-menu={modelLabel}
        aria-label={modelLabel}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onKeyDown={(event) => {
          if (open) onKeyDown(event);
          else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
            event.preventDefault();
            onOpenChange(true);
          }
        }}
        {...press}
      >
        <span className="acpmux-model-name">{chip}</span>
        {detail && <span className="acpmux-model-effort">{detail}</span>}
        <ChevronIcon />
      </button>
      {open && (
        <div
          ref={menu}
          id={menuId}
          className={`acpmux-menu acpmux-menu-end acpmux-mp acpmux-mp-${layout ?? "cascade"}`}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="menu"
          aria-label={modelLabel}
          style={menuStyle}
          onPointerMove={onPointerMove}
        >
          {children}
        </div>
      )}
    </span>
  );
}
