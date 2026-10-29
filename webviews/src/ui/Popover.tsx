// A popover over Base UI Popover, anchored to an element or a point (the editor caret). Non-modal:
// the page stays usable; Escape and a press outside close it, and focus returns where it was.
import type { ReactNode } from "react";
import { Popover as BasePopover } from "@base-ui/react/popover";
import { useOverlayPosition, usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./generated/popupProtocol";
import { UI_ANCHOR_GAP } from "./anchor";

/** A point or box on the page to place a popover at (a caret's coordinates, for example). */
export interface UiAnchorRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** A box read each time the popover is placed, so it follows layout changes (a Floating UI virtual element). */
export interface UiVirtualAnchor {
  getBoundingClientRect(): DOMRect;
  contextElement?: Element;
}

export type UiAnchor = Element | UiAnchorRect | UiVirtualAnchor | null;

/** The Floating UI virtual element of a rect anchor. */
export function virtualAnchor(anchor: UiAnchor) {
  if (!anchor || anchor instanceof Element || "getBoundingClientRect" in anchor) return anchor;
  const rect = anchor;
  return {
    getBoundingClientRect: () => {
      const width = rect.right - rect.left;
      const height = rect.bottom - rect.top;
      return {
        x: rect.left,
        y: rect.top,
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
        width,
        height,
        toJSON: () => rect,
      };
    },
  };
}

export interface PopoverProps {
  open: boolean;
  /** `escape`: closed by Escape, which a dialog may read as "revert". */
  onOpenChange(open: boolean, details?: { escape: boolean }): void;
  /** Where it opens; it opens below. */
  anchor: UiAnchor;
  /** The accessible name of the popover (role dialog). */
  label: string;
  className?: string;
  /** Which side of the anchor receives the popover. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  /** False keeps `side` while open (`useOpenSide` chose it); default flips when there is no room. */
  flip?: boolean;
  /** Focus a field inside on open (default: the first focusable). */
  initialFocus?: React.RefObject<HTMLElement | null> | boolean;
  /** Where focus goes on close (default: back to where it was). */
  finalFocus?: React.RefObject<HTMLElement | null> | boolean;
  /** Declarative native content. When the host is available, children are not mounted as rows. */
  native?: { model: NativePopupDescription; anchor: () => HTMLElement | null; onEvent?(event: NativePopupEvent): void; onDismiss?(): void };
  children: ReactNode;
}

export function Popover({
  open,
  onOpenChange,
  anchor,
  label,
  className,
  side = "bottom",
  flip = true,
  initialFocus,
  finalFocus,
  native,
  children,
}: PopoverProps) {
  const container = usePortalContainer();
  const positionMethod = useOverlayPosition();
  const nativePopup = useNativePopup({
    open: open === true && native !== undefined,
    model: native?.model ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: native?.anchor ?? (() => null),
    onEvent: (event) => native?.onEvent?.(event),
    onDismiss: () => {
      native?.onDismiss?.();
      onOpenChange?.(false);
    },
  });
  if (nativePopup.available && native !== undefined) return null;
  return (
    <BasePopover.Root
      open={open}
      onOpenChange={(next, details) => onOpenChange(next, { escape: details.reason === "escape-key" })}
      modal={false}
    >
      <BasePopover.Portal container={container}>
        <BasePopover.Positioner
          className="ui-positioner"
          positionMethod={positionMethod}
          anchor={virtualAnchor(anchor)}
          side={side}
          collisionAvoidance={flip ? undefined : { side: "none" }}
          align="start"
          sideOffset={UI_ANCHOR_GAP}
        >
          <BasePopover.Popup
            className={cx("ui-popup ui-glass ui-popover", className)}
            aria-label={label}
            initialFocus={initialFocus}
            finalFocus={finalFocus}
          >
            {children}
          </BasePopover.Popup>
        </BasePopover.Positioner>
      </BasePopover.Portal>
    </BasePopover.Root>
  );
}
