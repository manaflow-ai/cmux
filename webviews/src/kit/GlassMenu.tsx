// A menu from data: a button and a popup of items, drawn on the one floating material (the menu
// glass level) by ui/Menu, with its press-drag-release, keyboard and focus return. Use it for a
// row's overflow, a section's actions or a picker that is a short flat list; reach for ui/Menu
// directly only for submenus, check items or radio groups.
import type { ReactNode } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../ui/Menu";
import type { ButtonSize, ButtonVariant } from "../ui/Button";
import { Icon } from "../agent-session/acpmux/icons/Icon";
import { cx } from "../ui/cx";

export type GlassMenuItem =
  | {
      id: string;
      label: ReactNode;
      /** A cmux icon name (`Icon`). */
      icon?: string;
      shortcut?: string;
      /** A destructive action: the danger role for its text. */
      danger?: boolean;
      disabled?: boolean;
      onSelect(): void;
    }
  | { id: string; separator: true };

export interface GlassMenuProps {
  /** The button's and the menu's accessible name. */
  label: string;
  /** What the button shows; an icon-only trigger still gets `label`. */
  trigger: ReactNode;
  items: readonly GlassMenuItem[];
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  align?: "start" | "center" | "end";
  /** The trigger's look, as a `Button`'s (default ghost, md). */
  variant?: ButtonVariant;
  size?: ButtonSize;
  disabled?: boolean;
  /** Classes for the trigger (it is a `ui-button`). */
  className?: string;
}

export function GlassMenu({
  label,
  trigger,
  items,
  side = "bottom",
  align = "start",
  variant = "ghost",
  size = "md",
  disabled,
  className,
}: GlassMenuProps) {
  return (
    <Menu>
      <MenuButton label={label} className={cx("ui-btn", className)} variant={variant} size={size} disabled={disabled}>
        {trigger}
      </MenuButton>
      <MenuPopup label={label} side={side} align={align}>
        {items.map((item) =>
          "separator" in item ? (
            <MenuSeparator key={item.id} />
          ) : (
            <MenuItem
              key={item.id}
              data-value={item.id}
              disabled={item.disabled}
              shortcut={item.shortcut}
              className={item.danger ? "ui-menu-item-destructive" : undefined}
              onSelect={() => item.onSelect()}
            >
              {item.icon !== undefined && (
                <span className="ui-menu-icon" aria-hidden="true">
                  <Icon name={item.icon} size={14} />
                </span>
              )}
              {item.label}
            </MenuItem>
          ),
        )}
      </MenuPopup>
    </Menu>
  );
}
