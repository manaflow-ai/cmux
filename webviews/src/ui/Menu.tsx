// Menus over Base UI Menu: a menu button, items, check and radio items, groups, separators and
// submenus. Base UI owns roles, focus, arrows (direction-aware), typeahead and Escape per level.
import {
  createContext,
  use,
  useRef,
  useState,
  type ComponentProps,
  type PointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import { UI_ANCHOR_GAP } from "./anchor";
import { isMousePress, trackPressRelease } from "./pressRelease";

export interface MenuProps {
  open?: boolean;
  onOpenChange?(open: boolean): void;
  children: ReactNode;
}

const POINTER_SLOP = 4;
type PointerSession = { pointerId: number; x: number; y: number; moved: boolean; handled: boolean };
interface MenuContextValue {
  beginPointer(event: PointerEvent<HTMLElement>): void;
  movePointer(event: PointerEvent<HTMLElement>): void;
  activatePointer(event: PointerEvent<HTMLElement>, activate: () => void): boolean;
  endPointer(): void;
}
const MenuContext = createContext<MenuContextValue | null>(null);

/** A menu: a `MenuButton` and a `MenuPopup`. Non-modal, so the page keeps scrolling. */
export function Menu({ open, onOpenChange, children }: MenuProps) {
  const [internalOpen, setInternalOpen] = useState(open ?? false);
  const session = useRef<PointerSession | null>(null);
  const pointerCleanup = useRef<(() => void) | null>(null);
  const isOpen = open ?? internalOpen;
  const setMenuOpen = (next: boolean) => {
    if (open === undefined) setInternalOpen(next);
    onOpenChange?.(next);
  };
  const context: MenuContextValue = {
    beginPointer(event) {
      if (!isMousePress(event)) return;
      session.current = {
        pointerId: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        moved: false,
        handled: false,
      };
      setMenuOpen(true);
      pointerCleanup.current?.();
      pointerCleanup.current = trackPressRelease(event, {
        hover: (row) => row.focus({ preventScroll: true }),
        // Base UI items act on the click.
        pick: (row) => row.click(),
        picked: () => setMenuOpen(false),
        close: () => setMenuOpen(false),
        end: () => {
          pointerCleanup.current = null;
          session.current = null;
        },
      });
    },
    movePointer(event) {
      const current = session.current;
      if (!current || current.pointerId !== event.pointerId) return;
      if (!current.moved)
        current.moved = Math.hypot(event.clientX - current.x, event.clientY - current.y) >= POINTER_SLOP;
    },
    activatePointer(event, activate) {
      const current = session.current;
      if (!current || current.pointerId !== event.pointerId || !current.moved) return false;
      if (current.handled) return true;
      current.handled = true;
      activate();
      setMenuOpen(false);
      return true;
    },
    endPointer() {
      // Pointerup is handled by the press session's document listener (pressRelease.ts) so the row
      // remains selectable while the original trigger still owns pointer capture.
    },
  };
  return (
    <MenuContext value={context}>
      <BaseMenu.Root modal={false} open={isOpen} onOpenChange={setMenuOpen}>
        {children}
      </BaseMenu.Root>
    </MenuContext>
  );
}

export interface MenuButtonProps {
  className?: string;
  /** The accessible name when the button shows only an icon. */
  label?: string;
  disabled?: boolean;
  "aria-haspopup"?: "menu" | "listbox" | "dialog";
  "aria-labelledby"?: string;
  children: ReactNode;
}

export function MenuButton({
  className,
  label,
  disabled,
  "aria-haspopup": ariaHasPopup,
  "aria-labelledby": ariaLabelledBy,
  children,
}: MenuButtonProps) {
  const context = use(MenuContext);
  return (
    <BaseMenu.Trigger
      className={cx("ui-button", className)}
      aria-label={label}
      aria-labelledby={ariaLabelledBy}
      aria-haspopup={ariaHasPopup}
      disabled={disabled}
      onKeyUp={(event) => {
        if (event.key !== " ") return;
        const active =
          event.currentTarget.ownerDocument.querySelector<HTMLElement>('[role^="menuitem"][data-highlighted]') ??
          event.currentTarget.ownerDocument.activeElement?.closest<HTMLElement>('[role^="menuitem"]');
        if (!active) return;
        event.preventDefault();
        event.stopPropagation();
        active.click();
      }}
      onPointerDown={(event) => {
        context?.beginPointer(event);
        if (event.pointerType === "mouse" && event.button === 0) event.preventDefault();
      }}
      onClick={(event) => {
        // A mouse click has already opened on press; keep it open after release. Keyboard clicks
        // retain Base UI's native toggle behavior.
        if (event.detail > 0) event.preventDefault();
      }}
    >
      {children}
    </BaseMenu.Trigger>
  );
}

export interface MenuPopupProps {
  className?: string;
  /** Side of the trigger; submenus open at the inline end. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  align?: "start" | "center" | "end";
  /** What the menu is placed against (default: the menu button). */
  anchor?: ComponentProps<typeof BaseMenu.Positioner>["anchor"];
  /**
   * Where focus goes when the menu closes (default: its trigger). A page whose keys live in one
   * field (a picker's search) returns focus there.
   */
  finalFocus?: RefObject<HTMLElement | null>;
  children: ReactNode;
}

export function MenuPopup({
  className,
  side = "bottom",
  align = "start",
  anchor,
  finalFocus,
  children,
}: MenuPopupProps) {
  const container = usePortalContainer();
  return (
    <BaseMenu.Portal container={container}>
      <BaseMenu.Positioner
        className="ui-positioner"
        anchor={anchor}
        side={side}
        align={align}
        sideOffset={UI_ANCHOR_GAP}
      >
        <BaseMenu.Popup className={cx("ui-popup ui-menu", className)} finalFocus={finalFocus}>
          {children}
        </BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  );
}

export interface MenuItemProps {
  className?: string;
  disabled?: boolean;
  shortcut?: ReactNode;
  onSelect?(): void;
  children: ReactNode;
}

export function MenuItem({ className, disabled, shortcut, onSelect, children }: MenuItemProps) {
  const context = use(MenuContext);
  const handledClick = useRef(false);
  return (
    <BaseMenu.Item
      className={cx("ui-menu-item", className)}
      disabled={disabled}
      onPointerMove={(event) => context?.movePointer(event)}
      onPointerUp={(event) => {
        if (disabled) return;
        if (context?.activatePointer(event, () => onSelect?.())) {
          handledClick.current = true;
          event.preventDefault();
        }
        context?.endPointer();
      }}
      onClick={() => {
        if (handledClick.current) {
          handledClick.current = false;
          return;
        }
        onSelect?.();
      }}
    >
      {children}
      {shortcut ? <span className="ui-menu-shortcut">{shortcut}</span> : null}
    </BaseMenu.Item>
  );
}

export interface MenuCheckboxItemProps extends Omit<MenuItemProps, "onSelect"> {
  checked: boolean;
  onCheckedChange(checked: boolean): void;
}

export function MenuCheckboxItem({ className, disabled, checked, onCheckedChange, children }: MenuCheckboxItemProps) {
  const context = use(MenuContext);
  const handledClick = useRef(false);
  return (
    <BaseMenu.CheckboxItem
      className={cx("ui-menu-item", className)}
      disabled={disabled}
      checked={checked}
      onCheckedChange={(next) => {
        if (handledClick.current) {
          handledClick.current = false;
          return;
        }
        onCheckedChange(next);
      }}
      onPointerMove={(event) => context?.movePointer(event)}
      onPointerUp={(event) => {
        if (disabled) return;
        if (context?.activatePointer(event, () => onCheckedChange(!checked))) {
          handledClick.current = true;
          event.preventDefault();
        }
        context?.endPointer();
      }}
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
  shortcut,
  children,
}: { value: string } & Omit<MenuItemProps, "onSelect">) {
  const context = use(MenuContext);
  return (
    <BaseMenu.RadioItem
      className={cx("ui-menu-item", className)}
      value={value}
      disabled={disabled}
      onPointerMove={(event) => context?.movePointer(event)}
      onPointerUp={(event) => {
        if (disabled) return;
        if (context?.activatePointer(event, () => event.currentTarget.click())) event.preventDefault();
        context?.endPointer();
      }}
    >
      <span className="ui-menu-check" aria-hidden="true">
        <BaseMenu.RadioItemIndicator>✓</BaseMenu.RadioItemIndicator>
      </span>
      {children}
      {shortcut ? <span className="ui-menu-shortcut">{shortcut}</span> : null}
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
