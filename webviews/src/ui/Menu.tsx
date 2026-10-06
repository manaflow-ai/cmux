// Menus over Base UI Menu: a menu button, items, check and radio items, groups, separators and
// submenus. Base UI owns roles, focus, arrows (direction-aware), typeahead and Escape per level.
import type { ReactNode } from "react";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import { UI_ANCHOR_GAP } from "./anchor";

export interface MenuProps {
  open?: boolean;
  onOpenChange?(open: boolean): void;
  children: ReactNode;
}

/** A menu: a `MenuButton` and a `MenuPopup`. Non-modal, so the page keeps scrolling. */
export function Menu({ open, onOpenChange, children }: MenuProps) {
  return (
    <BaseMenu.Root modal={false} open={open} onOpenChange={onOpenChange ? (next) => onOpenChange(next) : undefined}>
      {children}
    </BaseMenu.Root>
  );
}

export interface MenuButtonProps {
  className?: string;
  /** The accessible name when the button shows only an icon. */
  label?: string;
  disabled?: boolean;
  children: ReactNode;
}

export function MenuButton({ className, label, disabled, children }: MenuButtonProps) {
  return (
    <BaseMenu.Trigger className={cx("ui-button", className)} aria-label={label} disabled={disabled}>
      {children}
    </BaseMenu.Trigger>
  );
}

export interface MenuPopupProps {
  className?: string;
  /** Side of the trigger; submenus open at the inline end. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  align?: "start" | "center" | "end";
  children: ReactNode;
}

export function MenuPopup({ className, side = "bottom", align = "start", children }: MenuPopupProps) {
  const container = usePortalContainer();
  return (
    <BaseMenu.Portal container={container}>
      <BaseMenu.Positioner className="ui-positioner" side={side} align={align} sideOffset={UI_ANCHOR_GAP}>
        <BaseMenu.Popup className={cx("ui-popup ui-menu", className)}>{children}</BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  );
}

export interface MenuItemProps {
  className?: string;
  disabled?: boolean;
  onSelect?(): void;
  children: ReactNode;
}

export function MenuItem({ className, disabled, onSelect, children }: MenuItemProps) {
  return (
    <BaseMenu.Item className={cx("ui-menu-item", className)} disabled={disabled} onClick={() => onSelect?.()}>
      {children}
    </BaseMenu.Item>
  );
}

export interface MenuCheckboxItemProps extends Omit<MenuItemProps, "onSelect"> {
  checked: boolean;
  onCheckedChange(checked: boolean): void;
}

export function MenuCheckboxItem({ className, disabled, checked, onCheckedChange, children }: MenuCheckboxItemProps) {
  return (
    <BaseMenu.CheckboxItem
      className={cx("ui-menu-item", className)}
      disabled={disabled}
      checked={checked}
      onCheckedChange={(next) => onCheckedChange(next)}
    >
      <span className="ui-menu-check" aria-hidden="true">
        <BaseMenu.CheckboxItemIndicator>✓</BaseMenu.CheckboxItemIndicator>
      </span>
      {children}
    </BaseMenu.CheckboxItem>
  );
}

export interface MenuRadioGroupProps {
  value: string;
  onValueChange(value: string): void;
  children: ReactNode;
}

export function MenuRadioGroup({ value, onValueChange, children }: MenuRadioGroupProps) {
  return (
    <BaseMenu.RadioGroup value={value} onValueChange={(next) => onValueChange(String(next))}>
      {children}
    </BaseMenu.RadioGroup>
  );
}

export function MenuRadioItem({
  value,
  className,
  disabled,
  children,
}: { value: string } & Omit<MenuItemProps, "onSelect">) {
  return (
    <BaseMenu.RadioItem className={cx("ui-menu-item", className)} value={value} disabled={disabled}>
      <span className="ui-menu-check" aria-hidden="true">
        <BaseMenu.RadioItemIndicator>✓</BaseMenu.RadioItemIndicator>
      </span>
      {children}
    </BaseMenu.RadioItem>
  );
}

export function MenuGroup({ label, children }: { label: string; children: ReactNode }) {
  return (
    <BaseMenu.Group className="ui-menu-group">
      <BaseMenu.GroupLabel className="ui-menu-group-label">{label}</BaseMenu.GroupLabel>
      {children}
    </BaseMenu.Group>
  );
}

export function MenuSeparator() {
  return <BaseMenu.Separator className="ui-separator" />;
}

export interface SubmenuProps {
  label: ReactNode;
  className?: string;
  /** Extra classes on the nested popup, so it matches its parent menu's surface. */
  popupClassName?: string;
  disabled?: boolean;
  children: ReactNode;
}

/** A submenu: its item opens the nested popup at the inline end (right in LTR, left in RTL). */
export function Submenu({ label, className, popupClassName, disabled, children }: SubmenuProps) {
  return (
    <BaseMenu.SubmenuRoot>
      <BaseMenu.SubmenuTrigger className={cx("ui-menu-item ui-submenu-trigger", className)} disabled={disabled}>
        {label}
        <span className="ui-submenu-chevron" aria-hidden="true" />
      </BaseMenu.SubmenuTrigger>
      <MenuPopup side="inline-end" align="start" className={popupClassName}>
        {children}
      </MenuPopup>
    </BaseMenu.SubmenuRoot>
  );
}
