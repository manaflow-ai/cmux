// Top-layer overlays (menus and tooltips). The pane's controls live inside scrollers
// (the diff list, Pierre's shadow roots) that clip anything drawn next to them, so every
// overlay is the shell's anchored Popover (src/shell/Popover.tsx): a popover in the browser
// top layer placed with CSS anchor positioning against the control that owns it. No
// layout is measured in JS: the browser resolves anchor() at layout time, including the
// pane's sub-pixel translate and live scrolling.
import type { ReactNode } from "react";
import { Popover } from "../../shell/Popover";

export { anchorProps } from "../../shell/anchors";

/**
 * Anchor names for one pane instance. CSS anchor names are document-global, so each pane
 * prefixes them with its React id. Controls spread `anchorProps(name)`, overlays name it.
 */
export interface PaneAnchors {
  scope: string;
  tool(id: string): string;
  file(index: number, button: string): string;
}

export function paneAnchors(reactId: string): PaneAnchors {
  const p = `--cx${reactId.replace(/[^a-zA-Z0-9_-]/g, "")}`;
  return {
    scope: `${p}-scope`,
    tool: (id) => `${p}-tool-${id}`,
    file: (index, button) => `${p}-f${index}-${button}`,
  };
}

/**
 * A top-layer box positioned against `anchor`. Placement (which anchor() edges, offsets)
 * belongs to `className` in changes.css. The element stays a DOM child of the pane, so it
 * inherits the pane's fonts and custom properties. `onDismiss` makes it an auto popover
 * (light dismiss); without it, a manual one whose visibility is purely the props.
 */
export function TopLayer({
  anchor,
  className,
  role,
  onDismiss,
  children,
}: {
  anchor: string;
  className: string;
  role?: string;
  onDismiss?: () => void;
  children: ReactNode;
}) {
  return (
    <Popover anchor={anchor} className={`chg-top ${className}`} role={role} onDismiss={onDismiss}>
      {children}
    </Popover>
  );
}
