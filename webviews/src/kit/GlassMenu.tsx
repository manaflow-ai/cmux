// A menu from data: a button and a popup of items, drawn on the one floating material (the menu
// glass level) by ui/Menu, with its press-drag-release, keyboard and focus return. Use it for a
// row's overflow, a section's actions or a picker that is a short flat list; reach for ui/Menu
// directly only for submenus, check items or radio groups.
import type { ReactNode } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../ui/Menu";
import { Icon } from "../agent-session/acpmux/icons/Icon";
import { cx } from "../ui/cx";

export type GlassMenuItem =
  | {
      id: string;
      label: ReactNode;
      /** A cmux icon name (`Icon`). */
      icon?: string;
      shortcut?: ReactNode;
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
  /** Classes for the trigger (it is a `ui-button`). */
  className?: string;
}

export function GlassMenu({ label, trigger, items, side = "bottom", align = "start", className }: GlassMenuProps) {
  return (
    <Menu>
      <MenuButton label={label} className={cx("ui-btn", className)}>
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
              className={cx("kit-menu-item", item.danger && "kit-menu-item-danger")}
              onSelect={() => item.onSelect()}
            >
              {item.icon !== undefined && <Icon name={item.icon} size={14} />}
              {item.label}
            </MenuItem>
          ),
        )}
      </MenuPopup>
    </Menu>
  );
}
