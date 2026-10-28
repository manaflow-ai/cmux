// Tooltips over Base UI Tooltip. A tooltip only repeats a control's accessible name (rule 4): the
// control carries `aria-label`, the tooltip is the sighted hint. It opens on hover and on keyboard
// focus, and Escape closes it. It looks like the native tooltip and the title tooltip
// (pages/shared/desktop.css): the liquid glass (`.ui-glass`, ui/glass/glass.css; Leo 2026-10-21:
// "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and hover previews"), primary ink, an
// optional shortcut hint. Every tooltip and hover card here is glass, never the solid popup surface
// (webviews/scripts/check-glass-never-opaque.ts fails one that is not).
import { useState, type PointerEventHandler, type ReactElement, type ReactNode, type Ref } from "react";
import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { virtualAnchor, type UiAnchor } from "./Popover";
import { cx } from "./cx";
import { HOVER_INTENT } from "./hoverIntent";

/**
 * A page's tooltips wait the hover delay before the first shows, then show at once while the group
 * is warm (`timeout`), as AppKit's do (ui/hoverIntent.ts), and close at once.
 */
export function TooltipProvider({ children }: { children: ReactNode }) {
  return (
    <BaseTooltip.Provider delay={HOVER_INTENT.tooltipDelay} closeDelay={0} timeout={HOVER_INTENT.tooltipWarm}>
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
  /** Extra classes on the popup (a hover card's own look, as `ui-card`). */
  className?: string;
}

export function Tooltip({ label, children, side = "bottom", shortcut, className }: TooltipProps) {
  const container = usePortalContainer();
  const host = usePopupHost();
  const [trigger, setTrigger] = useState<HTMLElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // No room in the page (a tiny pane): past the window's edge, as a Mac tooltip (popupHost.ts). A
  // hover card (`ui-card`) wraps its lines, so its width never sends it there.
  const wraps = /(^|\s)ui-card(\s|$)/.test(className ?? "");
  useEscapingPopup(host, popup, () => trigger, { side, align: "start", gap: 6, kind: "tooltip", wraps });
  return (
    <BaseTooltip.Root>
      <BaseTooltip.Trigger ref={host ? setTrigger : undefined} render={children} />
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner className="ui-positioner" side={side} sideOffset={6}>
          <BaseTooltip.Popup ref={host ? setPopup : undefined} className={cx("ui-tooltip ui-glass", className)}>
            {shortcut && <span className="ui-tooltip-hint">{shortcut}</span>}
            {label}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}

export interface AnchoredCardProps {
  /** Stable id for a control's `aria-describedby` relationship. */
  id?: string;
  /** Shown when set; the element (or rect) it sits under. */
  anchor: UiAnchor;
  /** Whether it shows (default: while `anchor` is set); false keeps it placed while it fades out. */
  open?: boolean;
  className?: string;
  /** Which side of the anchor receives the card. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  /** `data-state` on the card, for styling. */
  state?: string;
  /** Shows at once, with no fade in (a warm tooltip group's hint). */
  instant?: boolean;
  /** Interactive cards use dialog semantics instead of tooltip semantics. */
  interactive?: boolean;
  /** Accessible name for an interactive card. */
  ariaLabel?: string;
  onPointerEnter?: PointerEventHandler<HTMLDivElement>;
  onPointerLeave?: PointerEventHandler<HTMLDivElement>;
  /** The card's own element (its padding included), for a caller's inside/outside checks. */
  popupRef?: Ref<HTMLDivElement>;
  /** Identifies this portal to a shared hover bridge. */
  hoverBridgeId?: number;
  children: ReactNode;
}

/** Data marker shared with useHoverCard while the portal card is in the DOM. */
export function hoverBridgeMarker(id: number | undefined): { "data-cmux-hover-bridge"?: number } {
  return id === undefined ? {} : { "data-cmux-hover-bridge": id };
}

/**
 * A hover card for content the page does not render with React (a link inside the editor): a
 * tooltip anchored to that element, opened and closed by the caller. It is glass (`.ui-glass`) like
 * every hover card; a caller's class may tune the glass, never paint it solid. Non-interactive cards never
 * take focus; interactive cards may contain focusable controls.
 */
export function AnchoredCard({
  id,
  anchor,
  open,
  className,
  side = "bottom",
  state,
  instant,
  interactive = false,
  ariaLabel,
  onPointerEnter,
  onPointerLeave,
  popupRef,
  hoverBridgeId,
  children,
}: AnchoredCardProps) {
  const container = usePortalContainer();
  return (
    <BaseTooltip.Root open={open ?? anchor !== null}>
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner
          className="ui-positioner"
          anchor={virtualAnchor(anchor)}
          side={side}
          align="start"
          sideOffset={6}
        >
          <BaseTooltip.Popup
            ref={popupRef}
            id={id}
            className={cx("ui-tooltip ui-card ui-glass", className)}
            data-state={state}
            data-instant={instant ? "" : undefined}
            role={interactive ? "dialog" : "tooltip"}
            aria-label={interactive ? ariaLabel : undefined}
            {...hoverBridgeMarker(hoverBridgeId)}
            onPointerEnter={onPointerEnter}
            onPointerLeave={onPointerLeave}
          >
            {children}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}
