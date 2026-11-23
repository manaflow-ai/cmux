// Menus over Base UI Menu: a menu button, items, check and radio items, groups, separators and
// submenus. Base UI owns roles, focus, arrows (direction-aware), typeahead and Escape per level.
import {
  createContext,
  use,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
  type FocusEvent,
  type KeyboardEvent,
  type MouseEvent,
  type PointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { useOverlayPosition, usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup, type AnchorBox } from "./popupHost";
import { useNativePopup, type NativePopupDescription, type NativePopupEvent } from "./nativePopup";
import { popupAction } from "./popupDescriptors";
import { cx } from "./cx";
import { MenuCheckGlyph } from "./MenuCheckGlyph";
import { useScrollEdges } from "./scrollEdges";
import { UI_ANCHOR_GAP } from "./anchor";
import { popupCollision, type UiPopupFlip } from "./openSide";
import { usePopupPadding } from "./popupInset";
import { isMousePress, trackPressRelease } from "./pressRelease";
import { focusAfterEscape } from "./escapeFocus";
import { focusWithRing } from "./focusWithRing";
import { useNativeFinalFocus } from "./useNativeFinalFocus";
import { useExperimentArm } from "../experiments/useExperimentArm";
import { MENU_V2_INSET, menuStyleV2, type MenuStyleArm } from "./menuStyleV2.experiment";
import { isThenable } from "./menuArrange";
import { menuRowStates, type MenuRowStatesArm } from "./menuRowStates.experiment";

export interface MenuProps {
  open?: boolean;
  /** Optional declarative rows for WebPopupHost. When supplied, no popup rows mount in the page. */
  native?: {
    model: NativePopupDescription;
    onEvent?(event: NativePopupEvent): void;
    onDismiss?(): void;
    /** The host refused to draw the rows; when set, the menu stays open for the owner's fallback. */
    onRefused?(): void;
  };
  onOpenChange?(open: boolean): void;
  onOpenChangeComplete?(open: boolean): void;
  children: ReactNode;
}

const POINTER_SLOP = 4;
type PointerSession = { pointerId: number; x: number; y: number; moved: boolean; handled: boolean };
interface MenuContextValue {
  isOpen: boolean;
  nativeAvailable: boolean;
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
  /** Closes the menu (an async row whose work settled, menu-row-states). */
  close(): void;
}
const MenuContext = createContext<MenuContextValue | null>(null);

/** A menu: a `MenuButton` and a `MenuPopup`. Non-modal, so the page keeps scrolling. */
export function Menu({ open, onOpenChange, onOpenChangeComplete, native, children }: MenuProps) {
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
  const nativePopup = useNativePopup({
    open: isOpen && native !== undefined,
    model: native?.model ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: () => trigger.current,
    onEvent: (event) => {
      const action = event.type === "pick" && native ? popupAction(native.model, event.id) : undefined;
      native?.onEvent?.(event);
      if (action && !action.keepOpen) setMenuOpen(false);
    },
    onDismiss: (reason) => {
      if (reason === "refused" && native?.onRefused) return native.onRefused();
      if (open === undefined) setInternalOpen(false);
      onOpenChange?.(false);
      native?.onDismiss?.();
    },
  });
  const setMenuOpen = (next: boolean) => {
    if (next && !isOpen) {
      opener.current = trigger.current?.ownerDocument.activeElement ?? null;
      keyed.current = false;
      captured.current = true;
    }
    if (open === undefined) setInternalOpen(next);
    onOpenChange?.(next);
  };
  const nativeAvailable = native !== undefined && nativePopup.available;
  const context: MenuContextValue = {
    isOpen,
    nativeAvailable,
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
      // The App draws this menu (a native popup): its panel follows the held press and picks the
      // row the release lands on (NativePopupHost's press-release). The page sees only that
      // release; a page row under the panel must not run, and the menu must not close on it.
      if (nativeAvailable) {
        session.current = null;
        return;
      }
      pointerCleanup.current = trackPressRelease(event, {
        hover: (row) => row.focus({ preventScroll: true }),
        // Base UI items act on the click.
        pick: (row, event) => {
          const View = row.ownerDocument.defaultView!.MouseEvent;
          row.dispatchEvent(
            new View("click", {
              bubbles: true,
              cancelable: true,
              altKey: event.altKey,
              ctrlKey: event.ctrlKey,
              metaKey: event.metaKey,
              shiftKey: event.shiftKey,
              clientX: event.clientX,
              clientY: event.clientY,
              button: event.button,
            }),
          );
        },
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
    close() {
      setMenuOpen(false);
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
  /** The keycaps of the shortcut that opens it, drawn after the tooltip (ui/titleTooltips.ts). */
  "data-tooltip-shortcut"?: string | undefined;
  /** Also holds the button, for a caller that anchors other UI to it. */
  buttonRef?: RefObject<HTMLButtonElement | null>;
  /** A field-like trigger (a select, a host field): its menu opens as wide as it (`matchTrigger`). */
  fieldTrigger?: boolean;
  /** With the `ui-btn` class: a `Button`'s variant and size, so the trigger takes its hover, press
   *  and open fills (controls.css). */
  variant?: "ghost" | "subtle" | "solid";
  size?: "sm" | "md" | "lg";
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
  "data-tooltip-shortcut": tooltipShortcut,
  buttonRef,
  fieldTrigger,
  variant,
  size,
  children,
}: MenuButtonProps) {
  const context = use(MenuContext);
  // menu-row-states "on": the open trigger takes the panel's fill (popupSurface.css).
  const joined = useExperimentArm(menuRowStates) === "on";
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
      data-tooltip-shortcut={tooltipShortcut || undefined}
      data-field-trigger={fieldTrigger ? "" : undefined}
      data-variant={variant}
      data-size={size}
      data-popup-open={context?.isOpen ? "" : undefined}
      data-menu-join={joined ? "" : undefined}
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
  /** False keeps `side` while open (`useOpenSide` chose it); "shift" keeps it and slides the popup
   *  along it to stay in the window (openSide.ts `UiPopupFlip`); default flips when there is no room. */
  flip?: UiPopupFlip;
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
  /**
   * The menu starts at its trigger's leading edge and is at least as wide (Base UI's
   * `--anchor-width`): for a field-like trigger, a select or a host field, whose menu reads as its
   * drop-down (leo-workspace design/menus.md). The trigger says so with `data-field-trigger`.
   */
  matchTrigger?: boolean;
  /** False for a custom layout with its own scrolling columns. */
  scroll?: boolean;
  /** Pinned below the scrolling rows, outside their edge fade. */
  footer?: ReactNode;
  children: ReactNode;
}

/// The surface class of the popup a submenu sits in, so the submenu wears the same surface (a themed
/// menu never gets a bare, see-through submenu).
const PopupSurface = createContext<string | undefined>(undefined);
/// Inside a menu's popup: a submenu's popup leaves its focus return to Base UI (its own item).
const InPopup = createContext(false);
/// The box a menu's popups stay inside (`MenuPopupProps.boundary`), so its submenus keep to it too.
const PopupBoundary = createContext<Element | undefined>(undefined);
/// The experiments' arms a menu's rows draw (menu-style-v2, menu-row-states), read once per menu.
type MenuArmsValue = { look: MenuStyleArm; states: MenuRowStatesArm };
const MenuArms = createContext<MenuArmsValue | null>(null);

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
  matchTrigger = false,
  scroll = true,
  footer,
  children,
}: MenuPopupProps) {
  const container = usePortalContainer();
  const positionMethod = useOverlayPosition();
  const padding = usePopupPadding();
  const host = usePopupHost();
  const menu = use(MenuContext);
  const nested = use(InPopup);
  // The boundary box, found from the menu button as the menu opens; a submenu inherits it.
  const inherited = use(PopupBoundary);
  const [own, setOwn] = useState<Element | undefined>(undefined);
  const triggerRef = menu?.trigger;
  const menuOpen = menu?.isOpen ?? false;
  useNativeFinalFocus(Boolean(menu?.nativeAvailable && menuOpen), finalFocus);
  useLayoutEffect(() => {
    if (menuOpen) setOwn(boundary ? (triggerRef?.current?.closest(boundary) ?? undefined) : undefined);
  }, [boundary, triggerRef, menuOpen]);
  const collisionBoundary = boundary ? own : inherited;
  // The experiments' arms (a Settings flip redraws live); a submenu draws its menu's.
  const parentArms = use(MenuArms);
  const look = useExperimentArm(menuStyleV2);
  const states = useExperimentArm(menuRowStates);
  const arms = useMemo<MenuArmsValue>(() => parentArms ?? { look, states }, [parentArms, look, states]);
  // menu-style-v2: a submenu's panel is flush with its row, its first row level with it.
  const flush = nested && side === "inline-end" && arms.look !== "off";
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // The popup's last node: Base UI asks where focus goes after the close fade, as it unmounts.
  const popupNode = useRef<HTMLElement | null>(null);
  const edges = useScrollEdges();
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
  if (menu?.nativeAvailable) return null;
  return (
    <BaseMenu.Portal container={container}>
      <BaseMenu.Positioner
        className="ui-positioner"
        positionMethod={positionMethod}
        anchor={anchor}
        side={side}
        collisionAvoidance={popupCollision(flip)}
        collisionPadding={padding}
        {...(collisionBoundary ? { collisionBoundary } : {})}
        align={align}
        sideOffset={flush ? MENU_V2_INSET : UI_ANCHOR_GAP}
        {...(flush ? { alignOffset: -MENU_V2_INSET } : {})}
      >
        <BaseMenu.Popup
          // A shifted popup may use the window's height, not only the room on its side (popupSurface.css).
          data-popup-shift={flip === "shift" ? "" : undefined}
          // Only a page with a host measures its menus; the others render as they did.
          ref={attachPopup}
          id={id}
          aria-label={label}
          // The App's menu glass under the page (glass/hostGlass.ts).
          data-host-glass="menu"
          data-host-glass-cover=""
          // The experiments' arms (menuStyleV2, menuRowStates), styled in popupSurface.css; off draws none.
          data-menu-style={arms.look === "off" ? undefined : arms.look}
          data-menu-states={arms.states === "off" ? undefined : arms.states}
          className={cx(
            "ui-popup ui-glass ui-menu",
            scroll && "ui-popup-scroll-shell",
            matchTrigger && "ui-menu-match-trigger",
            className,
          )}
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
              <MenuArms value={arms}>
                <PopupSurface value={className}>
                  {scroll ? (
                    <div ref={edges} className="ui-popup-scroll ui-scroll-edge-fade">
                      {children}
                    </div>
                  ) : (
                    children
                  )}
                  {footer}
                </PopupSurface>
              </MenuArms>
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
  /** Stable action id for automation and gallery fixtures. */
  "data-value"?: string;
  disabled?: boolean;
  /** Why a disabled row is disabled, one amber line under its label ("Needs sign-in"); drawn under
   *  the menu-row-states experiment. */
  reason?: string;
  shortcut?: ReactNode;
  onPointerMove?(event: PointerEvent<HTMLElement>): void;
  onPointerEnter?(event: PointerEvent<HTMLElement>): void;
  onPointerLeave?(event: PointerEvent<HTMLElement>): void;
  onMouseEnter?(event: MouseEvent<HTMLElement>): void;
  onMouseLeave?(event: MouseEvent<HTMLElement>): void;
  /** The row took focus: the arrow keys focus the highlighted row. */
  onFocus?(event: FocusEvent<HTMLElement>): void;
  /** An `async` row returns its work's promise (the type stays `void`, so any handler fits). */
  onSelect?(event: MouseEvent<HTMLElement> | PointerEvent<HTMLElement>): void;
  children: ReactNode;
}

/// A row's label, and under a disabled row its reason (menu-row-states). Off: the label alone.
function RowLabel({ disabled, reason, children }: { disabled?: boolean; reason?: string; children: ReactNode }) {
  const arms = use(MenuArms);
  if (!reason || !disabled || !arms || arms.states === "off") return children;
  return (
    <span className="ui-menu-text">
      {children}
      <span className="ui-menu-reason">{reason}</span>
    </span>
  );
}

export function MenuItem({
  className,
  "data-value": dataValue,
  disabled,
  reason,
  shortcut,
  onPointerMove,
  onPointerEnter,
  onPointerLeave,
  onMouseEnter,
  onMouseLeave,
  onFocus,
  onSelect,
  closeOnClick,
  expanded,
  controls,
  destructive,
  async: isAsync,
  children,
}: MenuItemProps & {
  /** False keeps the menu open after a click (a row that shows or hides rows of its own menu). */
  closeOnClick?: boolean;
  /** A disclosure row: whether the rows it controls show. */
  expanded?: boolean;
  /** A disclosure row: the id of the rows it shows and hides. */
  controls?: string;
  /** Red, as a delete or close. */
  destructive?: boolean;
  /**
   * `onSelect` returns a promise (Open PR, Restart agent): under the menu-row-states experiment the
   * menu stays open at its size, the row spins in its trailing slot, and the menu closes when the
   * promise settles. Elsewhere the menu closes at once, as for any row.
   */
  async?: boolean;
}) {
  const context = use(MenuContext);
  const arms = use(MenuArms);
  const handledClick = useRef(false);
  const waits = Boolean(isAsync && arms && arms.states !== "off");
  const [pending, setPending] = useState(false);
  // The row is still drawn: a settle after the menu closed (Escape, a click away) does nothing.
  const mounted = useRef(true);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const select = (event: MouseEvent<HTMLElement> | PointerEvent<HTMLElement>) => {
    if (!waits) {
      onSelect?.(event);
      return;
    }
    if (pending) return;
    const result: unknown = onSelect?.(event);
    if (!isThenable(result)) {
      context?.close();
      return;
    }
    setPending(true);
    const settle = () => {
      if (!mounted.current) return;
      setPending(false);
      context?.close();
    };
    result.then(settle, settle);
  };
  const keepsOpen = waits ? false : closeOnClick;
  return (
    <BaseMenu.Item
      className={cx("ui-menu-item", destructive && "ui-menu-item-destructive", className)}
      {...(dataValue === undefined ? {} : { "data-value": dataValue })}
      disabled={disabled}
      {...(keepsOpen === undefined ? {} : { closeOnClick: keepsOpen })}
      {...(expanded === undefined ? {} : { "aria-expanded": expanded })}
      {...(controls ? { "aria-controls": controls } : {})}
      {...(keepsOpen === false ? { "data-keeps-open": "" } : {})}
      {...(pending ? { "aria-busy": true, "data-pending": "" } : {})}
      onPointerMove={(event) => {
        context?.movePointer(event);
        onPointerMove?.(event);
      }}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      onMouseEnter={onMouseEnter}
      onMouseLeave={onMouseLeave}
      onFocus={onFocus}
      onPointerUp={(event) => {
        if (disabled) return;
        if (context?.activatePointer(event, () => select(event), keepsOpen === false)) {
          handledClick.current = true;
          event.preventDefault();
        }
        context?.endPointer();
      }}
      onClick={(event) => {
        if (handledClick.current) {
          handledClick.current = false;
          return;
        }
        select(event);
      }}
    >
      <RowLabel disabled={disabled} reason={reason}>
        {children}
      </RowLabel>
      {shortcut ? <span className="ui-menu-shortcut">{shortcut}</span> : null}
      {/* The async row's trailing slot, reserved from the start so its spinner moves nothing. */}
      {waits ? (
        <span className="ui-menu-async" aria-hidden="true">
          {pending ? <span className="ui-menu-spinner" /> : null}
        </span>
      ) : null}
    </BaseMenu.Item>
  );
}

export interface MenuCheckboxItemProps extends Omit<MenuItemProps, "onSelect"> {
  checked: boolean;
  onCheckedChange(checked: boolean): void;
}

export function MenuCheckboxItem({
  className,
  disabled,
  reason,
  checked,
  onCheckedChange,
  children,
}: MenuCheckboxItemProps) {
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
        <BaseMenu.CheckboxItemIndicator>
          <MenuCheckGlyph />
        </BaseMenu.CheckboxItemIndicator>
      </span>
      <RowLabel disabled={disabled} reason={reason}>
        {children}
      </RowLabel>
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
  reason,
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
        <BaseMenu.RadioItemIndicator>
          <MenuCheckGlyph />
        </BaseMenu.RadioItemIndicator>
      </span>
      <RowLabel disabled={disabled} reason={reason}>
        {children}
      </RowLabel>
      {shortcut ? <span className="ui-menu-shortcut">{shortcut}</span> : null}
    </BaseMenu.RadioItem>
  );
}

export function MenuGroup({ label, className, children }: { label: string; className?: string; children: ReactNode }) {
  return (
    <BaseMenu.Group className={cx("ui-menu-group", className)}>
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
  /** Vertical alignment of the nested popup; omitted keeps the room-aware default. */
  align?: "start" | "end";
  children: ReactNode;
}

/** A submenu: its item opens the nested popup at the inline end (right in LTR, left in RTL). Its popup
 * wears the parent popup's surface unless `popupClassName` names another.
 *
 * It grows the way its menu opened: up from the row's bottom in a menu that opened up (a composer's
 * menu at the window's foot), as Claude Code's and macOS's menus do (Leo 2026-10-21: "this effort
 * should open up top instead of bottom"), and down from the row's top in a menu that opened down. A
 * menu that opened sideways (a submenu's submenu) grows toward the room its row has. Base UI's
 * collision avoidance still flips or shifts it when that side has no room. */
export function Submenu({ label, className, popupClassName, disabled, align: requestedAlign, children }: SubmenuProps) {
  const surface = use(PopupSurface);
  const boundary = use(PopupBoundary);
  const trigger = useRef<HTMLDivElement | null>(null);
  const [align, setAlign] = useState<"start" | "end">(requestedAlign ?? "start");
  return (
    <BaseMenu.SubmenuRoot
      onOpenChange={(open) => {
        const row = trigger.current;
        if (open && row) setAlign(requestedAlign ?? (growsUp(row, boundary) ? "end" : "start"));
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

/// Whether a submenu row's submenu grows up: when its menu opened up, never when it opened down
/// (a taller menu can put the row past the window's middle). Otherwise, whether the row has more
/// room above it than below it, inside the menu's box (the window when it has none).
function growsUp(row: Element, boundary: Element | undefined): boolean {
  const opened = row.closest(".ui-popup")?.getAttribute("data-side");
  if (opened === "top") return true;
  if (opened === "bottom") return false;
  const view = row.ownerDocument.defaultView;
  const box = boundary?.getBoundingClientRect() ?? { top: 0, bottom: view?.innerHeight ?? 0 };
  const rect = row.getBoundingClientRect();
  return rect.bottom - box.top > box.bottom - rect.top;
}
