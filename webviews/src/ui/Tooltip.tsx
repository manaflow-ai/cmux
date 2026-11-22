// Tooltips over Base UI Tooltip. A tooltip only repeats a control's accessible name (rule 4): the
// control carries `aria-label`, the tooltip is the sighted hint. It opens on hover and on keyboard
// focus, and Escape closes it.
import type { ReactElement, ReactNode } from "react";
import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { usePortalContainer } from "./UiProvider";
import { virtualAnchor, type UiAnchor } from "./Popover";
import { cx } from "./cx";

/** One delay group for a page's tooltips: moving between controls shows the next one at once. */
export function TooltipProvider({ children }: { children: ReactNode }) {
  return (
    <BaseTooltip.Provider delay={500} closeDelay={0}>
      {children}
    </BaseTooltip.Provider>
  );
}

export interface TooltipProps {
  label: ReactNode;
  /** The control it describes (its `render` target). */
  children: ReactElement;
  side?: "top" | "bottom";
}

export function Tooltip({ label, children, side = "bottom" }: TooltipProps) {
  const container = usePortalContainer();
  return (
    <BaseTooltip.Root>
      <BaseTooltip.Trigger render={children} />
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner className="ui-positioner" side={side} sideOffset={6}>
          <BaseTooltip.Popup className="ui-tooltip">{label}</BaseTooltip.Popup>
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
