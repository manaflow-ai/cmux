// Tooltips over Base UI Tooltip. A tooltip only repeats a control's accessible name (rule 4): the
// control carries `aria-label`, the tooltip is the sighted hint. It opens on hover and on keyboard
// focus, and Escape closes it. It looks like the native tooltip and the title tooltip
// (pages/shared/desktop.css): the solid popup surface, primary ink, an optional shortcut hint.
import { useState, type ReactElement, type ReactNode } from "react";
import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { virtualAnchor, type UiAnchor } from "./Popover";
import { cx } from "./cx";

/** A page's tooltips show at once, with no hover delay (POLISH), and close at once. */
export function TooltipProvider({ children }: { children: ReactNode }) {
  return (
    <BaseTooltip.Provider delay={0} closeDelay={0}>
      {children}
    </BaseTooltip.Provider>
  );
}

export interface TooltipProps {
  label: ReactNode;
  /** The control it describes (its `render` target). */
  children: ReactElement;
  side?: "top" | "bottom";
  /** A keyboard shortcut shown after the label in the secondary ink (`⌘T`), as on native tooltips. */
  shortcut?: string;
}

export function Tooltip({ label, children, side = "bottom", shortcut }: TooltipProps) {
  const container = usePortalContainer();
  const host = usePopupHost();
  const [trigger, setTrigger] = useState<HTMLElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // No room in the page (a tiny pane): past the window's edge, as a Mac tooltip (popupHost.ts).
  useEscapingPopup(host, popup, () => trigger, { side, align: "start", gap: 6, kind: "tooltip" });
  return (
    <BaseTooltip.Root>
      <BaseTooltip.Trigger ref={host ? setTrigger : undefined} render={children} />
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner className="ui-positioner" side={side} sideOffset={6}>
          <BaseTooltip.Popup ref={host ? setPopup : undefined} className="ui-tooltip">
            {shortcut && <span className="ui-tooltip-hint">{shortcut}</span>}
            {label}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}

export interface AnchoredCardProps {
  /** Shown when set; the element (or rect) it sits under. */
  anchor: UiAnchor;
  className?: string;
  /** `data-state` on the card, for styling. */
  state?: string;
  children: ReactNode;
}

/**
 * A hover card for content the page does not render with React (a link inside the editor): a
 * tooltip anchored to that element, opened and closed by the caller. It never takes focus.
 */
export function AnchoredCard({ anchor, className, state, children }: AnchoredCardProps) {
  const container = usePortalContainer();
  return (
    <BaseTooltip.Root open={anchor !== null}>
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner
          className="ui-positioner"
          anchor={virtualAnchor(anchor)}
          side="bottom"
          align="start"
          sideOffset={6}
        >
          <BaseTooltip.Popup className={cx("ui-tooltip ui-card", className)} data-state={state} role="tooltip">
            {children}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}
