// Tooltips over Base UI Tooltip. A tooltip only repeats a control's accessible name (rule 4): the
// control carries `aria-label`, the tooltip is the sighted hint. It opens on hover and on keyboard
// focus, and Escape closes it. It looks like the native tooltip and the title tooltip
// (pages/shared/desktop.css): the liquid glass (`.ui-glass`, ui/glass/glass.css; Leo 2026-10-21:
// "WHERE IS THE GLASS EVERYWHERE, all these hover tooltips and hover previews"), regular text in the
// primary ink, an optional shortcut on a keycap. Every tooltip and hover card here is glass, never the solid popup surface
// (webviews/scripts/check-glass-never-opaque.ts fails one that is not).
import {
  useCallback,
  useLayoutEffect,
  useState,
  type KeyboardEvent,
  type PointerEventHandler,
  type ReactElement,
  type ReactNode,
  type Ref,
} from "react";
import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { usePopupHost, usePortalContainer } from "./UiProvider";
import { useEscapingPopup } from "./popupHost";
import { virtualAnchor, type UiAnchor } from "./Popover";
import { cx } from "./cx";
import { KeyHint } from "./KeyHint";
import { attachSeeThroughBlur, type CoveredCandidates, type SeeThroughOptions } from "./glass/seeThroughBlur";
import { hoverCardGlass, hoverCardUnder } from "./glass/hoverCardGlass";
import { HOVER_INTENT } from "./hoverIntent";
import { UI_TOOLTIP_EDGE, UI_TOOLTIP_GAP, UI_TOOLTIP_MAX_WIDTH, tooltipGap, tooltipScale } from "./tooltipTokens";
import { usePopupPadding } from "./popupInset";
import { fitTooltipWidth } from "./tooltipFit";
import { announceHoverSurface } from "./hoverSurface";
import { oneHoverSurface } from "./hoverLook";

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

/**
 * Every tooltip and hover card here (a Tooltip, a `ui-card` Tooltip, an AnchoredCard above or below
 * its anchor) flips between above and below only, then shifts along its row, never down onto it. A
 * card taller than the room on both sides stays on the roomier one and scrolls (desktop.css
 * --available-height). Base UI's default falls back to the anchor's side when neither fits
 * (`fallbackAxisSide: "end"`), which drew a tall facts card on the row it describes (Leo,
 * 2026-11-22: "and more bullshit somehow happened here"; test/hover-card-cover.test.ts).
 */
const CARD_COLLISION = { side: "flip", align: "shift", fallbackAxisSide: "none" } as const;

export interface TooltipProps {
  label: ReactNode;
  /** A hover card's supporting text, on a dimmer second line; a plain tooltip is one line and shows none. */
  detail?: ReactNode;
  /** The control it describes (its `render` target). */
  children: ReactElement;
  /** Tooltips sit below their control, flipping above at the edge, as the native tooltip does. */
  side?: "top" | "bottom";
  /** A keyboard shortcut shown after the label on a keycap (`⌘T`), as on native tooltips. */
  shortcut?: string;
  /** Extra classes on the popup (a hover card's own look, as `ui-card`). */
  className?: string;
  /**
   * A selector inside the control that the popup sits at, when the control is wider than what it
   * names (a transcript-wide row whose hover belongs at its words, as `data-tooltip-anchor` does for
   * a title tooltip). The whole control still opens it.
   */
  anchor?: string;
  /** Shows nothing while set, keeping the control mounted (a row whose text is not cut). */
  disabled?: boolean;
}

export function Tooltip({
  label,
  detail,
  children,
  side = "bottom",
  shortcut,
  className,
  anchor,
  disabled,
}: TooltipProps) {
  const container = usePortalContainer();
  const host = usePopupHost();
  // Below what covers the page's top (the tab row, an open find bar: ui/popupInset.ts), flipping or
  // shifting there instead of drawing over it.
  const padding = usePopupPadding();
  const [trigger, setTrigger] = useState<HTMLElement | null>(null);
  const [popup, setPopup] = useState<HTMLElement | null>(null);
  // No room in the page (a tiny pane): past the window's edge, as a Mac tooltip (popupHost.ts). A
  // hover card (`ui-card`) wraps its lines, so its width never sends it there.
  const wraps = /(^|\s)ui-card(\s|$)/.test(className ?? "");
  const placed = () => (anchor && trigger?.querySelector<HTMLElement>(anchor)) || trigger;
  useEscapingPopup(host, popup, placed, {
    side,
    align: "start",
    gap: UI_TOOLTIP_GAP * (popup ? tooltipScale(popup.ownerDocument) : 1),
    kind: "tooltip",
    wraps,
  });
  // As narrow as its lines (ui/tooltipFit.ts), once as it opens and when its text changes, before
  // paint: it shows at its final size. A hover card keeps its own width.
  useLayoutEffect(() => {
    if (!popup || wraps) return;
    const doc = popup.ownerDocument;
    const scale = tooltipScale(doc);
    const view = doc.documentElement.clientWidth;
    fitTooltipWidth(popup, Math.min(UI_TOOLTIP_MAX_WIDTH * scale, Math.max(0, view - 2 * UI_TOOLTIP_EDGE * scale)));
  }, [popup, wraps, label, detail, shortcut]);
  // A hover card is the one hover card material (glass/hoverCardGlass.ts), as AnchoredCard's link
  // cards are: the App's popover glass under the page, and what it covers blurred in place, so
  // Chromium's see-through page draws no underlay under it. Before, a Tooltip card kept that
  // underlay and read solid (Leo, 2026-11-14: "this has no transparency at all + is not
  // scrollable"). The popup mounts only while it shows.
  // Under the One hover look (experiments.hoverLook = one, ui/hoverLook.css) a label blurs what it
  // covers too, as a card does, and says it opened so a title tooltip beside it goes
  // (ui/hoverSurface.ts). Off, a label is as before.
  useLayoutEffect(() => {
    if (!popup) return;
    const one = oneHoverSurface(popup.ownerDocument);
    if (one) announceHoverSurface(popup);
    if (!wraps && !one) return;
    return attachSeeThroughBlur(popup, hoverCardUnder, hoverCardGlass);
  }, [popup, wraps]);
  // A card taller than the window scrolls (desktop.css .ui-tooltip.ui-card); from the keyboard, its
  // trigger focused, Page Down and Page Up scroll it, and the transcript under it stays.
  const scrollCard = (event: KeyboardEvent<HTMLElement>) => {
    if (!wraps || !popup || (event.key !== "PageDown" && event.key !== "PageUp")) return;
    if (popup.scrollHeight <= popup.clientHeight) return;
    event.preventDefault();
    const page = Math.max(1, popup.clientHeight - UI_TOOLTIP_EDGE * 2 * tooltipScale(popup.ownerDocument));
    popup.scrollBy({ top: event.key === "PageDown" ? page : -page });
  };
  return (
    <BaseTooltip.Root disabled={disabled}>
      <BaseTooltip.Trigger
        ref={host || anchor ? setTrigger : undefined}
        render={children}
        {...(wraps && { onKeyDown: scrollCard })}
      />
      {/* Disabled while it shows (the control changed under the pointer), it goes at once. */}
      {!disabled && (
        <BaseTooltip.Portal container={container}>
          <BaseTooltip.Positioner
            className="ui-positioner"
            side={side}
            sideOffset={tooltipGap}
            collisionPadding={padding}
            // Above or below its row only, a tooltip as a card (CARD_COLLISION): never beside it.
            collisionAvoidance={CARD_COLLISION}
            {...(anchor && { anchor: () => placed() })}
          >
            <BaseTooltip.Popup
              ref={setPopup}
              className={cx("ui-tooltip ui-glass", className)}
              // A tooltip says what it is, as AnchoredCard's and a title tooltip's do (titleTooltips.ts):
              // Base UI's popup carries no role, so a play or an assistive tool looking for the
              // label within its panel (kit.gallery.tsx `[data-scheme] [role="tooltip"]`) found none.
              role="tooltip"
              data-surface-role={wraps ? "hoverCard" : "tooltip"}
              // On the App's glass under the page (glass/hostGlass.ts): a card at the popover level, a
              // label at the chip level, the native tooltip's glass, blurring what it covers in place.
              {...(wraps
                ? { "data-host-glass": "popover", "data-tooltip-card": "" }
                : { "data-host-glass": "chip", "data-host-glass-cover": "" })}
            >
              {shortcut && <KeyHint keys={shortcut} className="ui-tooltip-hint" />}
              {typeof label === "string" || typeof label === "number" ? (
                <span className="ui-tooltip-text">{label}</span>
              ) : (
                label
              )}
              {/* A tooltip is one line (titleTooltips.ts firstLine); only a hover card has a detail line. */}
              {detail != null && wraps && <span className="ui-tooltip-detail">{detail}</span>}
            </BaseTooltip.Popup>
          </BaseTooltip.Positioner>
        </BaseTooltip.Portal>
      )}
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
  /** What the card covers on its page, blurred in place while it shows (glass/seeThroughBlur.ts):
   * Chromium's backdrop leaves the text under a card reading through its tint. A module constant. */
  under?: CoveredCandidates;
  /** The in-place blur's options (a module constant): its owner word and what keeps the underlay. */
  underOptions?: SeeThroughOptions;
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
  under,
  underOptions,
  children,
}: AnchoredCardProps) {
  const container = usePortalContainer();
  const padding = usePopupPadding();
  // The popup mounts after this component commits (the portal places it first), so the blur keys
  // on the popup node itself, not a ref read in this component's own commit.
  const [popup, setPopupNode] = useState<HTMLDivElement | null>(null);
  const setPopup = useCallback(
    (node: HTMLDivElement | null) => {
      setPopupNode(node);
      if (typeof popupRef === "function") popupRef(node);
      else if (popupRef) popupRef.current = node;
    },
    [popupRef],
  );
  const shown = open ?? anchor !== null;
  useLayoutEffect(() => {
    if (!popup || !shown) return;
    // Under the One hover look every card blurs what it covers (the chat and Session Info by
    // default, glass/hoverCardGlass.ts) and says it opened (ui/hoverSurface.ts); off, only a card
    // given `under` blurs, as before.
    const one = oneHoverSurface(popup.ownerDocument);
    if (one) announceHoverSurface(popup);
    const covered = under ?? (one ? hoverCardUnder : undefined);
    if (!covered) return;
    return attachSeeThroughBlur(popup, covered, under ? underOptions : hoverCardGlass);
  }, [popup, under, underOptions, shown]);
  return (
    <BaseTooltip.Root open={open ?? anchor !== null}>
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner
          className="ui-positioner"
          anchor={virtualAnchor(anchor)}
          side={side}
          align="start"
          sideOffset={tooltipGap}
          collisionPadding={padding}
          // A card above or below its anchor stays off the anchor's row (CARD_COLLISION); one placed
          // beside it on purpose keeps Base UI's flips.
          {...((side === "top" || side === "bottom") && { collisionAvoidance: CARD_COLLISION })}
        >
          <BaseTooltip.Popup
            ref={setPopup}
            id={id}
            className={cx("ui-tooltip ui-card ui-glass", className)}
            data-surface-role="hoverCard"
            // The App's popover glass under the page (glass/hostGlass.ts); a card given `under` blurs
            // what it covers itself.
            data-host-glass="popover"
            data-host-glass-cover={under ? undefined : ""}
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
