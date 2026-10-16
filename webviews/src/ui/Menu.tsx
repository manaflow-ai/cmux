// Menus over Base UI Menu: a menu button, items, check and radio items, groups, separators and
// submenus. Base UI owns roles, focus, arrows (direction-aware), typeahead and Escape per level.
import {
  createContext,
  use,
  useRef,
  useState,
  type ComponentProps,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { useOverlayPosition, usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup, type AnchorBox } from "./popupHost";
import { cx } from "./cx";
import { UI_ANCHOR_GAP } from "./anchor";
import { isMousePress, trackPressRelease } from "./pressRelease";
import { focusAfterEscape } from "./escapeFocus";

export interface MenuProps {
  open?: boolean;
  onOpenChange?(open: boolean): void;
  onOpenChangeComplete?(open: boolean): void;
  children: ReactNode;
}

const POINTER_SLOP = 4;
type PointerSession = { pointerId: number; x: number; y: number; moved: boolean; handled: boolean };
interface MenuContextValue {
  isOpen: boolean;
  /** The menu button, where Escape hands the keyboard back. */
  trigger: RefObject<HTMLButtonElement | null>;
  beginPointer(event: PointerEvent<HTMLElement>): void;
  movePointer(event: PointerEvent<HTMLElement>): void;
  activatePointer(event: PointerEvent<HTMLElement>, activate: () => void): boolean;
  endPointer(): void;
}
const MenuContext = createContext<MenuContextValue | null>(null);

/** A menu: a `MenuButton` and a `MenuPopup`. Non-modal, so the page keeps scrolling. */
export function Menu({ open, onOpenChange, onOpenChangeComplete, children }: MenuProps) {
  const [internalOpen, setInternalOpen] = useState(open ?? false);
  const session = useRef<PointerSession | null>(null);
  const pointerCleanup = useRef<(() => void) | null>(null);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const isOpen = open ?? internalOpen;
  const setMenuOpen = (next: boolean) => {
    if (open === undefined) setInternalOpen(next);
    onOpenChange?.(next);
  };
  const context: MenuContextValue = {
    isOpen,
    trigger,
    beginPointer(event) {
      if (!isMousePress(event)) return;
      const wasOpen = isOpen;
      pointerCleanup.current?.();
      pointerCleanup.current = null;
      session.current = null;
      // A mouse press on an open trigger is a toggle. Base UI's click handler would
      // otherwise see the outside press close the menu and reopen it on the same click.
      if (wasOpen) {
        setMenuOpen(false);
        return;
      }
      session.current = {
        pointerId: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        moved: false,
        handled: false,
      };
      setMenuOpen(true);
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
      <BaseMenu.Root modal={false} open={isOpen} onOpenChange={setMenuOpen} onOpenChangeComplete={onOpenChangeComplete}>
        {children}
      </BaseMenu.Root>
    </MenuContext>
  );
}

export interface MenuButtonProps {
  className?: string;
  /** The accessible name when the button shows only an icon. */
  label?: string;
  /** The hover tooltip (the page's title tooltips show it). */
  title?: string;
  disabled?: boolean;
  "aria-haspopup"?: "menu" | "listbox" | "dialog";
  "aria-labelledby"?: string;
  /** The name automation finds the menu by (`button[data-menu]`), whatever the UI language. */
  "data-menu"?: string;
  children: ReactNode;
}

export function MenuButton({
  className,
  label,
  title,
  disabled,
  "aria-haspopup": ariaHasPopup,
  "aria-labelledby": ariaLabelledBy,
  "data-menu": dataMenu,
  children,
}: MenuButtonProps) {
  const context = use(MenuContext);
  return (
    <BaseMenu.Trigger
      ref={context?.trigger}
      className={cx("ui-button", className)}
      aria-label={label}
      title={title}
      aria-labelledby={ariaLabelledBy}
      aria-haspopup={ariaHasPopup}
      data-menu={dataMenu}
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
      onMouseDown={(event) => {
        // WebKit dispatches a native mousedown after pointerdown. While an open trigger is
        // closing the menu on press, cancel that follow-up so Base UI cannot reopen it on click.
        if (context?.isOpen && event.button === 0) event.preventDefault();
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
  id?: string;
  label?: string;
  className?: string;
  /** Side of the trigger; submenus open at the inline end. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  /** False keeps `side` while open (`useOpenSide` chose it); default flips when there is no room. */
  flip?: boolean;
  align?: "start" | "center" | "end";
  /** What the menu is placed against (default: the menu button). */
  anchor?: ComponentProps<typeof BaseMenu.Positioner>["anchor"];
  /**
   * Where focus goes when the menu closes (default: its trigger). A page whose keys live in one
   * field (a picker's search) returns focus there.
   */
  finalFocus?: boolean | RefObject<HTMLElement | null>;
  /** Keys the menu takes beyond Base UI's own (a mode menu's number keys). */
  onKeyDown?: (event: KeyboardEvent<HTMLDivElement>) => void;
  children: ReactNode;
}

/// The surface class of the popup a submenu sits in, so the submenu wears the same surface (a themed
/// menu never gets a bare, see-through submenu).
const PopupSurface = createContext<string | undefined>(undefined);
/// Inside a menu's popup: a submenu's popup leaves its focus return to Base UI (its own item).
const InPopup = createContext(false);

export function MenuPopup({
  id,
  label,
  className,
  side = "bottom",
  flip = true,
  align = "start",
  anchor,
  finalFocus,
  onKeyDown,
  children,
}: MenuPopupProps) {
  const container = usePortalContainer();
  const positionMethod = useOverlayPosition();
  const host = usePopupHost();
  const menu = use(MenuContext);
  const nested = use(InPopup);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // No room above or below in the page: past the window's edge (popupHost.ts). Side menus stay.
  useEscapingPopup(side === "top" || side === "bottom" ? host : null, popup, () => anchorElement(anchor, popup), {
    side: side === "top" ? "top" : "bottom",
    align: align === "end" ? "end" : "start",
    gap: UI_ANCHOR_GAP,
  });
  return (
    <BaseMenu.Portal container={container}>
      <BaseMenu.Positioner
        className="ui-positioner"
        positionMethod={positionMethod}
        anchor={anchor}
        side={side}
        collisionAvoidance={flip ? undefined : { side: "none" }}
        align={align}
        sideOffset={UI_ANCHOR_GAP}
      >
        <BaseMenu.Popup
          // Only a page with a host measures its menus; the others render as they did.
          ref={host ? setPopup : undefined}
          id={id}
          aria-label={label}
          className={cx("ui-popup ui-menu", className)}
          finalFocus={finalFocus}
          onKeyDown={(event) => {
            // Escape puts the keyboard back on the menu button (escapeFocus.ts). Its own Escape
            // only, not a submenu's (React carries that one up through the portal).
            if (
              event.key === "Escape" &&
              !nested &&
              finalFocus === undefined &&
              event.currentTarget.contains(event.target as Node)
            )
              focusAfterEscape(menu?.trigger.current);
            onKeyDown?.(event);
          }}
        >
          <InPopup value>
            <PopupSurface value={className}>{children}</PopupSurface>
          </InPopup>
        </BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  );
}

/** What a menu opened from: its `anchor` (an element or a virtual anchor), else its open trigger. */
function anchorElement(anchor: MenuPopupProps["anchor"], popup: HTMLElement | null): AnchorBox | null {
  const resolved = typeof anchor === "function" ? anchor() : anchor && "current" in anchor ? anchor.current : anchor;
  if (resolved && "getBoundingClientRect" in resolved) return resolved;
  if (resolved) return null;
  const triggers = popup?.ownerDocument.querySelectorAll("[aria-haspopup][data-popup-open]") ?? [];
  return triggers.length ? triggers[triggers.length - 1] : null;
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
  closeOnClick,
  children,
}: {
  value: string;
  /** Close the menu when picked (Base UI keeps a radio menu open by default). */
  closeOnClick?: boolean;
} & Omit<MenuItemProps, "onSelect">) {
  const context = use(MenuContext);
  return (
    <BaseMenu.RadioItem
      className={cx("ui-menu-item", className)}
      value={value}
      disabled={disabled}
      closeOnClick={closeOnClick}
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

/** A submenu: its item opens the nested popup at the inline end (right in LTR, left in RTL). Its popup
 * wears the parent popup's surface unless `popupClassName` names another. */
export function Submenu({ label, className, popupClassName, disabled, children }: SubmenuProps) {
  const surface = use(PopupSurface);
  return (
    <BaseMenu.SubmenuRoot>
      <BaseMenu.SubmenuTrigger className={cx("ui-menu-item ui-submenu-trigger", className)} disabled={disabled}>
        {label}
        <span className="ui-submenu-chevron" aria-hidden="true" />
      </BaseMenu.SubmenuTrigger>
      <MenuPopup side="inline-end" align="start" className={popupClassName ?? surface}>
        {children}
      </MenuPopup>
    </BaseMenu.SubmenuRoot>
  );
}
