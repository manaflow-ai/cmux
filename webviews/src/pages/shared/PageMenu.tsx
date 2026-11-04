// A point-anchored context menu for page surfaces. In the app it is the app's
// standard macOS menu (ui/nativeMenu.ts). Without a host, or when the host
// refuses, Base UI owns the menu semantics, keyboard navigation, dismissal and
// focus restoration; this adapter only supplies the pointer location and
// page-specific actions.
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { hasNativeMenuPick, nativeMenu, pickedId, type NativeMenuRow } from "../../ui/nativeMenu";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../ui/Menu";
import type { NativePopupDescription, NativePopupEvent } from "../../ui/nativePopup";
import { popupAction } from "../../ui/popupDescriptors";
import { usePopupHost, usePortalContainer } from "../../ui/UiProvider";
import { useEscapingPopup } from "../../ui/popupHost";

export interface PageMenuItem {
  id: string;
  label: string;
  destructive?: boolean;
  separatorBefore?: boolean;
  disabled?: boolean;
  run: () => void;
}

export interface PageMenuProps {
  x: number;
  y: number;
  items: PageMenuItem[];
  onClose: () => void;
  /** The row or button that opened the menu, restored on Escape or dismissal. */
  returnFocus?: HTMLElement | null;
}

export function PageMenu({ x, y, items, onClose, returnFocus }: PageMenuProps) {
  useEffect(() => {
    returnFocus?.setAttribute("data-popup-open", "");
    return () => returnFocus?.removeAttribute("data-popup-open");
  }, [returnFocus]);
  const popupHost = usePopupHost();
  if (popupHost?.native) {
    return <NativePageMenu x={x} y={y} items={items} onClose={onClose} returnFocus={returnFocus} />;
  }
  return <LegacyPageMenu x={x} y={y} items={items} onClose={onClose} returnFocus={returnFocus} />;
}

/** The app path uses the same declarative native popup as every shared menu. */
function NativePageMenu({ x, y, items, onClose, returnFocus }: PageMenuProps) {
  const finalFocus = useRef<HTMLElement | null>(returnFocus ?? null);
  const model = useMemo<NativePopupDescription>(
    () => ({
      side: "bottom",
      align: "start",
      width: 220,
      rows: items.flatMap((item) => [
        ...(item.separatorBefore ? [{ id: `separator:${item.id}`, kind: "separator" as const, label: "" }] : []),
        {
          id: item.id,
          kind: "action" as const,
          label: item.label,
          disabled: item.disabled,
        },
      ]),
    }),
    [items],
  );
  const native = useMemo(
    () => ({
      model,
      onEvent: (event: NativePopupEvent) => {
        if (event.type !== "pick" || !event.id) return;
        const action = popupAction(model, event.id);
        const item = items.find((candidate) => candidate.id === event.id);
        if (!action || !item || item.disabled) return;
        onClose();
        item.run();
      },
      onDismiss: onClose,
    }),
    [items, model, onClose],
  );
  const anchorStyle = { left: x, top: y };
  return (
    <Menu
      open
      native={native}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <span className="page-menu-native-anchor" style={anchorStyle} aria-hidden="true">
        <MenuButton label="">
          <span aria-hidden="true" />
        </MenuButton>
      </span>
      <MenuPopup finalFocus={finalFocus}>
        {items.map((item) => (
          <span key={item.id}>
            {item.separatorBefore ? <MenuSeparator /> : null}
            <MenuItem
              className={item.destructive ? "ui-menu-item-destructive" : undefined}
              disabled={item.disabled}
              onSelect={item.run}
            >
              {item.label}
            </MenuItem>
          </span>
        ))}
      </MenuPopup>
    </Menu>
  );
}

/** Browser and legacy hosts retain the existing actionable fallback. */
function LegacyPageMenu({ x, y, items, onClose, returnFocus }: PageMenuProps) {
  const container = usePortalContainer();
  const opener = useRef<HTMLElement | null>(returnFocus ?? null);
  // A native menu can answer after its page/row has closed. Retired menus own no actions.
  const mounted = useRef(false);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const anchor = useMemo(
    () => ({
      getBoundingClientRect: () => ({
        x,
        y,
        left: x,
        top: y,
        right: x,
        bottom: y,
        width: 0,
        height: 0,
        toJSON: () => ({}),
      }),
    }),
    [x, y],
  );
  // No room above or below the pointer in the page: past the window's edge (popupHost.ts).
  const host = usePopupHost();
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  useEscapingPopup(host, popup, () => anchor, { side: "bottom", align: "start", gap: 0 });
  // The app's native menu, asked once per opening; a refusal (an older app) draws the page's.
  const [drawn, setDrawn] = useState(() => nativeMenu() === null);
  const asked = useRef(false);
  useEffect(() => {
    const native = nativeMenu();
    if (!native || asked.current) return;
    asked.current = true;
    const rows = items.flatMap((item): NativeMenuRow[] => [
      ...(item.separatorBefore ? [{ id: `separator:${item.id}`, label: "", separator: true }] : []),
      { id: item.id, label: item.label, ...(item.disabled ? { disabled: true } : {}) },
    ]);
    native({ items: rows, point: { x, y } }).then(
      (reply) => {
        if (!mounted.current) return;
        // Older hosts can answer an unknown operation with a successful empty acknowledgement.
        // That means the menu never opened; let Base UI draw an actionable one instead.
        if (!hasNativeMenuPick(reply)) {
          setDrawn(true);
          return;
        }
        const chosen = items.find((item) => item.id === pickedId(reply) && !item.disabled);
        onClose();
        if (chosen) chosen.run();
        else if (opener.current?.isConnected) opener.current.focus({ preventScroll: true });
      },
      () => {
        if (mounted.current) setDrawn(true);
      },
    );
  }, [items, x, y, onClose]);
  if (!drawn) return null;

  return (
    <BaseMenu.Root
      open
      modal
      loopFocus
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <BaseMenu.Portal container={container}>
        <BaseMenu.Positioner
          className="page-menu-positioner"
          anchor={anchor}
          positionMethod="fixed"
          side="bottom"
          align="start"
          sideOffset={0}
        >
          <BaseMenu.Popup
            ref={host ? setPopup : undefined}
            className="page-menu ui-popup ui-glass"
            finalFocus={() => opener.current}
          >
            {items.map((item) => (
              <PageMenuRow key={item.id} item={item} onClose={onClose} />
            ))}
          </BaseMenu.Popup>
        </BaseMenu.Positioner>
      </BaseMenu.Portal>
    </BaseMenu.Root>
  );
}

function PageMenuRow({ item, onClose }: { item: PageMenuItem; onClose: () => void }) {
  const run = () => {
    if (item.disabled) return;
    onClose();
    item.run();
  };

  return (
    <div role="none">
      {item.separatorBefore ? <hr className="page-menu-separator" /> : null}
      <BaseMenu.Item
        className={(state) =>
          `page-menu-item${state.highlighted ? " active" : ""}${item.destructive ? " destructive" : ""}`
        }
        disabled={item.disabled}
        onClick={run}
      >
        {item.label}
      </BaseMenu.Item>
    </div>
  );
}
