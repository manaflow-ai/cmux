// A point-anchored context menu for page surfaces. Base UI owns the menu
// semantics, keyboard navigation, dismissal and focus restoration; this adapter
// only supplies the pointer location and page-specific actions.
import { useMemo, useRef } from "react";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { usePortalContainer } from "../../ui/UiProvider";

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
          <BaseMenu.Popup className="page-menu" finalFocus={() => opener.current}>
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
