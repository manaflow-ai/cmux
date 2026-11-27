// A popover over Base UI Popover, anchored to an element or a point (the editor caret). Non-modal:
// the page stays usable; Escape and a press outside close it, and focus returns where it was.
import { PopupResizeGrips, type PopupResizeOptions } from "./PopupResize";
import type { ReactNode } from "react";
import { Popover as BasePopover } from "@base-ui/react/popover";
import { useOverlayPosition, usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./popupProtocol";
import { popupAction } from "./popupDescriptors";
import { UI_ANCHOR_GAP } from "./anchor";
import { useNativeFinalFocus } from "./useNativeFinalFocus";
import { popupCollision, type UiPopupFlip } from "./openSide";
import { usePopupPadding } from "./popupInset";
import { useScrollEdges } from "./scrollEdges";
import { usePopupSettle } from "./popupSettle";

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
  onOpenChange(open: boolean, details?: { escape: boolean; outsidePress?: boolean }): void;
  /** Where it opens; it opens below. */
  anchor: UiAnchor;
  /** The accessible name of the popover (role dialog). */
  label: string;
  /** The popup's id, which its trigger names in `aria-controls` (`usePopoverTrigger`). */
  id?: string;
  className?: string;
  style?: React.CSSProperties;
  /** False keeps a surface on the page's own glass. */
  hostGlass?: boolean;
  "data-page-glass"?: string;
  /** Fade a capped popup body when more content lies beyond its scroll edges. */
  fade?: boolean;
  /** The popup rule this popover follows instead of the shared one (ui/popupSettle.ts): "results" for
   * content that is the live subject (it streams in after open), "own" for a popup that sizes itself. */
  popupSettle?: "results" | "own";
  /** Which side of the anchor receives the popover. */
  side?: "top" | "bottom" | "inline-end" | "inline-start";
  /** False keeps `side` while open (`useOpenSide` chose it); "shift" keeps it and slides the popup
   *  along it to stay in the window (openSide.ts `UiPopupFlip`); default flips when there is no room. */
  flip?: UiPopupFlip;
  /** Which edge of the anchor the popover lines up with (default: its start). */
  align?: "start" | "center" | "end";
  /** Focus a field inside on open (default: the first focusable). */
  initialFocus?: React.RefObject<HTMLElement | null> | boolean;
  /** Where focus goes on close (default: back to where it was). The callback is for web popovers. */
  finalFocus?: React.ComponentProps<typeof BasePopover.Popup>["finalFocus"];
  /** Declarative native content. When the host is available, children are not mounted as rows. */
  native?: {
    model: NativePopupDescription;
    anchor: () => HTMLElement | null;
    onEvent?(event: NativePopupEvent): void;
    onDismiss?(): void;
  };
  /** Resizable from its edges away from the anchor, its size kept under `resize.id` (PopupResize.tsx).
   *  Top and bottom popovers only. */
  resize?: PopupResizeOptions;
  children: ReactNode;
}

export function Popover({
  open,
  onOpenChange,
  anchor,
  label,
  id,
  className,
  style,
  hostGlass = true,
  "data-page-glass": pageGlass,
  fade = false,
  popupSettle,
  side = "bottom",
  flip = true,
  align = "start",
  initialFocus,
  finalFocus,
  native,
  resize,
  children,
}: PopoverProps) {
  const popupClassName = cx("ui-popup ui-glass ui-popover", className);
  const edges = useScrollEdges();
  const container = usePortalContainer();
  const positionMethod = useOverlayPosition();
  const padding = usePopupPadding();
  // Opens at its final size and keeps it while data arrives (popupSettle.ts).
  const settle = usePopupSettle<HTMLDivElement>();
  const nativePopup = useNativePopup({
    open: open === true && native !== undefined,
    model: native?.model ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: native?.anchor ?? (() => null),
    onEvent: (event) => {
      const action = event.type === "pick" && native ? popupAction(native.model, event.id) : undefined;
      native?.onEvent?.(event);
      if (action && !action.keepOpen) {
        onOpenChange(false, { escape: false });
      }
    },
    onDismiss: (reason) => {
      native?.onDismiss?.();
      onOpenChange(false, { escape: reason === "escape" });
    },
  });
  useNativeFinalFocus(
    nativePopup.available && native !== undefined && open,
    typeof finalFocus === "function" ? undefined : finalFocus,
  );
  if (nativePopup.available && native !== undefined) return null;
  return (
    <BasePopover.Root
      open={open}
      onOpenChange={(next, details) =>
        onOpenChange(next, {
          escape: details.reason === "escape-key",
          outsidePress: details.reason === "outside-press",
        })
      }
      modal={false}
    >
      <BasePopover.Portal container={container}>
        <BasePopover.Positioner
          className="ui-positioner"
          positionMethod={positionMethod}
          anchor={virtualAnchor(anchor)}
          side={side}
          collisionAvoidance={popupCollision(flip)}
          collisionPadding={padding}
          align={align}
          sideOffset={UI_ANCHOR_GAP}
        >
          <BasePopover.Popup
            ref={settle}
            // A shifted popup may use the window's height, not only the room on its side (popupSurface.css).
            data-popup-shift={flip === "shift" ? "" : undefined}
            data-popup-settle={popupSettle}
            className={cx(popupClassName, fade && "ui-popup-scroll-shell")}
            style={style}
            // The App's popover glass under the page (glass/hostGlass.ts).
            data-host-glass={hostGlass ? "popover" : undefined}
            data-page-glass={hostGlass ? undefined : pageGlass}
            data-surface-role="popover"
            data-host-glass-cover={hostGlass ? "" : undefined}
            id={id}
            aria-label={label}
            initialFocus={initialFocus}
            finalFocus={finalFocus}
          >
            {resize && (side === "top" || side === "bottom") && (
              <PopupResizeGrips resize={resize} side={side} align={align === "end" ? "end" : "start"} />
            )}
            {fade ? (
              <div ref={edges} className="ui-popup-scroll ui-scroll-edge-fade">
                {children}
              </div>
            ) : (
              children
            )}
          </BasePopover.Popup>
        </BasePopover.Positioner>
      </BasePopover.Portal>
    </BasePopover.Root>
  );
}
