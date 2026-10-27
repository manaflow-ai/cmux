// Menus over Base UI Menu: a menu button, items, check and radio items, groups, separators and
// submenus. Base UI owns roles, focus, arrows (direction-aware), typeahead and Escape per level.
import {
  createContext,
  use,
  useCallback,
  useLayoutEffect,
  useRef,
  useState,
  type ComponentProps,
  type KeyboardEvent,
  type MouseEvent,
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
import { focusWithRing } from "./focusWithRing";

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
  /** What had focus when the menu opened, where a pointer close puts it back. */
  opener: RefObject<Element | null>;
  /** The last input in the open menu was a key (Base UI's close type names how it opened). */
  keyed: RefObject<boolean>;
  beginPointer(event: PointerEvent<HTMLElement>): void;
  /** Whether a mouse press already opened or closed the menu on its pointerdown (once per press). */
  takePress(): boolean;
  movePointer(event: PointerEvent<HTMLElement>): void;
  /** `keepOpen`: the row shows or hides rows of its own menu (`MenuItem` `closeOnClick={false}`). */
  activatePointer(event: PointerEvent<HTMLElement>, activate: () => void, keepOpen?: boolean): boolean;
  endPointer(): void;
}
const MenuContext = createContext<MenuContextValue | null>(null);

/** A menu: a `MenuButton` and a `MenuPopup`. Non-modal, so the page keeps scrolling. */
export function Menu({ open, onOpenChange, onOpenChangeComplete, children }: MenuProps) {
  const [internalOpen, setInternalOpen] = useState(open ?? false);
  const session = useRef<PointerSession | null>(null);
  const pointerCleanup = useRef<(() => void) | null>(null);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const opener = useRef<Element | null>(null);
  const keyed = useRef(false);
  const captured = useRef(false);
  // Set by a mouse press that opened or closed the menu on its pointerdown; the press's mousedown
  // takes it (MenuButton).
  const pressed = useRef(false);
  const isOpen = open ?? internalOpen;
  const setMenuOpen = (next: boolean) => {
    if (next && !isOpen) {
      opener.current = trigger.current?.ownerDocument.activeElement ?? null;
      keyed.current = false;
      captured.current = true;
    }
    if (open === undefined) setInternalOpen(next);
    onOpenChange?.(next);
  };
  const context: MenuContextValue = {
    isOpen,
    trigger,
    opener,
    keyed,
    beginPointer(event) {
      pressed.current = false;
      if (!isMousePress(event)) return;
      pressed.current = true;
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
        // A row that keeps its menu open (`MenuItem` `closeOnClick={false}`) keeps it open here too.
        picked: (row) => {
          if (!row.hasAttribute("data-keeps-open")) setMenuOpen(false);
        },
        close: () => setMenuOpen(false),
        end: () => {
          pointerCleanup.current = null;
          session.current = null;
        },
      });
    },
    takePress() {
      const taken = pressed.current;
      pressed.current = false;
      return taken;
    },
    movePointer(event) {
      const current = session.current;
      if (!current || current.pointerId !== event.pointerId) return;
      if (!current.moved)
        current.moved = Math.hypot(event.clientX - current.x, event.clientY - current.y) >= POINTER_SLOP;
    },
    activatePointer(event, activate, keepOpen) {
      const current = session.current;
      if (!current || current.pointerId !== event.pointerId || !current.moved) return false;
      if (current.handled) return true;
      current.handled = true;
      activate();
      if (!keepOpen) setMenuOpen(false);
      return true;
    },
    endPointer() {
      // Pointerup is handled by the press session's document listener (pressRelease.ts) so the row
      // remains selectable while the original trigger still owns pointer capture.
    },
  };
  // A menu opened through `open` (automation, a parent's state) skips setMenuOpen: record what has
  // focus now, unless the popup already took it, so a close never returns to a past session's opener.
  useLayoutEffect(() => {
    if (!isOpen) {
      captured.current = false;
      return;
    }
    if (captured.current) return;
    captured.current = true;
    keyed.current = false;
    const active = trigger.current?.ownerDocument.activeElement ?? null;
    opener.current = active?.closest(".ui-popup") ? null : active;
  }, [isOpen]);
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
  /** Also holds the button, for a caller that anchors other UI to it. */
  buttonRef?: RefObject<HTMLButtonElement | null>;
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
  buttonRef,
  children,
}: MenuButtonProps) {
  const context = use(MenuContext);
  return (
    <BaseMenu.Trigger
      ref={(node: HTMLButtonElement | null) => {
        if (context) context.trigger.current = node;
        if (buttonRef) buttonRef.current = node;
      }}
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
      onMouseDown={(event: MouseEvent<HTMLButtonElement> & { preventBaseUIHandler?: () => void }) => {
        // WebKit dispatches a native mousedown after pointerdown. The press already opened or
        // closed the menu, so Base UI's own mousedown toggle must not act on it again: once React
        // has drawn the opened menu before this mousedown (a busy page, Leo's long chat on nightly
        // 3a63d6d), that toggle read it as open and closed it a frame later, and the click did
        // nothing. On a close, it would reopen it.
        if (event.button !== 0) return;
        if (context?.takePress()) {
          event.preventDefault();
          event.preventBaseUIHandler?.();
        } else if (context?.isOpen) event.preventDefault();
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
  /**
   * A selector for the box the menu (and its submenus) stays inside, found from the menu button
   * (the agent pane's chat column). Base UI sizes `--available-width` and `--available-height` to
   * it; without one, or when the button has no such ancestor, the box is the window.
   */
  boundary?: string;
  /**
   * False keeps the menu in the page when it has no room (default: it goes past the window's edge,
   * popupHost.ts). For a menu the native panel cannot draw: a rail beside its rows, a scroll area of
   * its own. It then fits by its own max height.
   */
  escapes?: boolean;
  children: ReactNode;
}

/// The surface class of the popup a submenu sits in, so the submenu wears the same surface (a themed
/// menu never gets a bare, see-through submenu).
const PopupSurface = createContext<string | undefined>(undefined);
/// Inside a menu's popup: a submenu's popup leaves its focus return to Base UI (its own item).
const InPopup = createContext(false);
/// The box a menu's popups stay inside (`MenuPopupProps.boundary`), so its submenus keep to it too.
const PopupBoundary = createContext<Element | undefined>(undefined);

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
  boundary,
  escapes = true,
  children,
}: MenuPopupProps) {
  const container = usePortalContainer();
  const positionMethod = useOverlayPosition();
  const host = usePopupHost();
  const menu = use(MenuContext);
  const nested = use(InPopup);
  // The boundary box, found from the menu button as the menu opens; a submenu inherits it.
  const inherited = use(PopupBoundary);
  const [own, setOwn] = useState<Element | undefined>(undefined);
  const triggerRef = menu?.trigger;
  const menuOpen = menu?.isOpen ?? false;
  useLayoutEffect(() => {
    if (menuOpen) setOwn(boundary ? (triggerRef?.current?.closest(boundary) ?? undefined) : undefined);
  }, [boundary, triggerRef, menuOpen]);
  const collisionBoundary = boundary ? own : inherited;
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // The popup's last node: Base UI asks where focus goes after the close fade, as it unmounts.
  const popupNode = useRef<HTMLElement | null>(null);
  const attachPopup = useCallback(
    (node: HTMLElement | null) => {
      if (node) popupNode.current = node;
      if (host) setPopup(node);
    },
    [host],
  );
  // No room above or below in the page: past the window's edge (popupHost.ts). Side menus stay.
  useEscapingPopup(
    escapes && (side === "top" || side === "bottom") ? host : null,
    popup,
    () => anchorElement(anchor, popup),
    {
      side: side === "top" ? "top" : "bottom",
      align: align === "end" ? "end" : "start",
      gap: UI_ANCHOR_GAP,
    },
  );
  return (
    <BaseMenu.Portal container={container}>
      <BaseMenu.Positioner
        className="ui-positioner"
        positionMethod={positionMethod}
        anchor={anchor}
        side={side}
        collisionAvoidance={flip ? undefined : { side: "none" }}
        {...(collisionBoundary ? { collisionBoundary } : {})}
        align={align}
        sideOffset={UI_ANCHOR_GAP}
      >
        <BaseMenu.Popup
          // Only a page with a host measures its menus; the others render as they did.
          ref={attachPopup}
          id={id}
          aria-label={label}
          className={cx("ui-popup ui-glass ui-menu", className)}
          finalFocus={
            finalFocus ?? (nested ? undefined : (closeType) => focusAfterClose(closeType, menu, popupNode.current))
          }
          onPointerDown={() => {
            if (menu) menu.keyed.current = false;
          }}
          onKeyDown={(event) => {
            if (menu) menu.keyed.current = true;
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
            <PopupBoundary value={collisionBoundary}>
              <PopupSurface value={className}>{children}</PopupSurface>
            </PopupBoundary>
          </InPopup>
        </BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  );
}

/// Where focus goes when a top-level menu closes. A keyboard close puts it on the trigger, with its
/// ring. A pointer close (a pick or a press outside) puts focus back where it was when the menu
/// opened (the prompt), else on the trigger, never with a focus ring: a ring left on a chip after a
/// click away read as a stuck focus state (Leo 2026-10-18). Focus the close left elsewhere on purpose
/// (another chip's menu opened by the same press, a field clicked into) stays there.
function focusAfterClose(
  closeType: string,
  menu: MenuContextValue | null,
  popup: HTMLElement | null,
): boolean | HTMLElement | null {
  if (!menu) return true;
  const active = menu.trigger.current?.ownerDocument.activeElement;
  if (active && active !== active.ownerDocument.body && !popup?.contains(active)) return false;
  if (closeType === "keyboard" || menu.keyed.current) return menu.trigger.current ?? true;
  const opener = menu.opener.current;
  const target =
    opener instanceof HTMLElement &&
    opener.isConnected &&
    opener !== opener.ownerDocument.body &&
    !opener.closest("[inert]")
      ? opener
      : menu.trigger.current;
  if (target?.isConnected) focusWithRing(target, { preventScroll: true, focusVisible: false });
  return false;
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

export function MenuItem({
  className,
  disabled,
  shortcut,
  onSelect,
  closeOnClick,
  expanded,
  controls,
  children,
}: MenuItemProps & {
  /** False keeps the menu open after a click (a row that shows or hides rows of its own menu). */
  closeOnClick?: boolean;
  /** A disclosure row: whether the rows it controls show. */
  expanded?: boolean;
  /** A disclosure row: the id of the rows it shows and hides. */
  controls?: string;
}) {
  const context = use(MenuContext);
  const handledClick = useRef(false);
  return (
    <BaseMenu.Item
      className={cx("ui-menu-item", className)}
      disabled={disabled}
      {...(closeOnClick === undefined ? {} : { closeOnClick })}
      {...(expanded === undefined ? {} : { "aria-expanded": expanded })}
      {...(controls ? { "aria-controls": controls } : {})}
      {...(closeOnClick === false ? { "data-keeps-open": "" } : {})}
      onPointerMove={(event) => context?.movePointer(event)}
      onPointerUp={(event) => {
        if (disabled) return;
        if (context?.activatePointer(event, () => onSelect?.(), closeOnClick === false)) {
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
  label,
  title,
  children,
}: {
  value: string;
  /** Close the menu when picked (Base UI keeps a radio menu open by default). */
  closeOnClick?: boolean;
  /** The row's accessible name, for a row that draws only an icon. */
  label?: string;
  /** The row's tooltip. */
  title?: string;
} & Omit<MenuItemProps, "onSelect">) {
  const context = use(MenuContext);
  return (
    <BaseMenu.RadioItem
      className={cx("ui-menu-item", className)}
      value={value}
      aria-label={label}
      title={title}
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

/** Keys a menu search field passes on to its menu: the arrows into the rows, Tab, Escape. */
const MENU_SEARCH_PASSES = new Set(["ArrowDown", "ArrowUp", "Tab", "Escape"]);

export interface MenuSearchFieldProps {
  value: string;
  onChange(value: string): void;
  /** The field's accessible name and placeholder. */
  label: string;
}

/** A search field at the top of a long menu: what it types narrows the rows below. The menu's
 * typeahead and Home/End never see its keys; the arrows move into the rows, Escape closes. */
export function MenuSearchField({ value, onChange, label }: MenuSearchFieldProps) {
  return (
    <input
      className="ui-field ui-menu-search"
      type="search"
      value={value}
      aria-label={label}
      placeholder={label}
      spellCheck={false}
      autoComplete="off"
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={(event) => {
        if (!MENU_SEARCH_PASSES.has(event.key)) event.stopPropagation();
      }}
    />
  );
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
 * wears the parent popup's surface unless `popupClassName` names another.
 *
 * It grows toward the room its row has: down from the row's top, or, for a row nearer the bottom of
 * the menu's box (a composer's menu opened up from the window's foot), up from the row's bottom, as
 * Claude Code's and macOS's menus do (Leo 2026-10-21: "this effort should open up top instead of
 * bottom"). Base UI's collision avoidance still flips or shifts it when that side has no room. */
export function Submenu({ label, className, popupClassName, disabled, children }: SubmenuProps) {
  const surface = use(PopupSurface);
  const boundary = use(PopupBoundary);
  const trigger = useRef<HTMLDivElement | null>(null);
  const [align, setAlign] = useState<"start" | "end">("start");
  return (
    <BaseMenu.SubmenuRoot
      onOpenChange={(open) => {
        const row = trigger.current;
        if (open && row) setAlign(growsUp(row, boundary) ? "end" : "start");
      }}
    >
      <BaseMenu.SubmenuTrigger
        ref={trigger}
        className={cx("ui-menu-item ui-submenu-trigger", className)}
        disabled={disabled}
      >
        {label}
        <span className="ui-submenu-chevron" aria-hidden="true" />
      </BaseMenu.SubmenuTrigger>
      <MenuPopup side="inline-end" align={align} className={popupClassName ?? surface}>
        {children}
      </MenuPopup>
    </BaseMenu.SubmenuRoot>
  );
}

/// Whether a submenu row has more room above it than below it, inside the menu's box (the window
/// when it has none).
function growsUp(row: Element, boundary: Element | undefined): boolean {
  const view = row.ownerDocument.defaultView;
  const box = boundary?.getBoundingClientRect() ?? { top: 0, bottom: view?.innerHeight ?? 0 };
  const rect = row.getBoundingClientRect();
  return rect.bottom - box.top > box.bottom - rect.top;
}
