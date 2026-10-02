// Popover menus and tooltips, rendered into the top layer (TopLayer.tsx). Menus are auto
// popovers (light dismiss closes them through `onClose`); tooltips are manual.
import type { ReactNode } from "react";
import * as I from "../icons";
import type { MenuIcon, MenuRow } from "../types";
import { TopLayer } from "./TopLayer";

const ROW_ICONS: Record<MenuIcon, ReactNode> = {
  refresh: <I.Refresh />,
  wrap: <I.Wrap />,
  split: <I.SplitView />,
  collapse: <I.CollapseAll />,
  file: <I.FileOutline />,
  image: <I.ImageOutline />,
  "plus-minus": <I.PlusMinusBox />,
  cube: <I.Cube />,
  clipboard: <I.Clipboard />,
  eye: <I.EyeOutline />,
};

/** Which menu, for placement: under the scope button, the toolbar ⋯ or a file header ⋯. */
export type MenuPlacement = "scope" | "options" | "file";

export function Menu({
  rows,
  anchor,
  placement,
  onClose,
}: {
  rows: readonly MenuRow[];
  anchor: string;
  placement: MenuPlacement;
  onClose: () => void;
}) {
  return (
    <TopLayer
      anchor={anchor}
      className={`chg-menu chg-${placement}-menu`}
      role="menu"
      onDismiss={onClose}
    >
      {rows.map((r, i) =>
        r === "-" ? (
          <div key={i} className="chg-menu-sep" role="separator" />
        ) : (
          <div
            key={i}
            className="chg-menu-item"
            role="menuitem"
            aria-disabled={r.disabled || undefined}
            onClick={
              r.disabled
                ? undefined
                : () => {
                    r.run?.();
                    onClose();
                  }
            }
          >
            {r.icon && <span className="chg-menu-icon">{ROW_ICONS[r.icon]}</span>}
            <span>{r.label}</span>
            {r.submenu && (
              <I.ChevronRight className="chg-menu-trail" width={16} height={16} strokeWidth={1.1} />
            )}
            {r.checked && (
              <I.Check className="chg-menu-trail chg-menu-check" width={16} height={16} />
            )}
          </div>
        ),
      )}
    </TopLayer>
  );
}

/** Tooltip bubble: above a file header button, below a toolbar button. */
export function Tooltip({
  text,
  anchor,
  side,
}: {
  text: string;
  anchor: string;
  side: "above" | "below";
}) {
  return (
    <TopLayer anchor={anchor} className={`chg-tooltip chg-tooltip-${side}`} role="tooltip">
      {text}
    </TopLayer>
  );
}
