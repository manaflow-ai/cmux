// A point-anchored context menu for page surfaces. In the app it is the app's
// standard macOS menu (ui/nativeMenu.ts). Without a host, or when the host
// refuses, Base UI owns the menu semantics, keyboard navigation, dismissal and
// focus restoration; this adapter only supplies the pointer location and
// page-specific actions.
import { useEffect, useMemo, useRef, useState } from "react";
import { hasNativeMenuPick, nativeMenu, pickedId, type NativeMenuRow } from "../../ui/nativeMenu";
import { Menu as BaseMenu } from "@base-ui/react/menu";
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
  const container = usePortalContainer();
  const opener = useRef<HTMLElement | null>(returnFocus ?? null);
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
      () => setDrawn(true),
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
