// A popover over Base UI Popover, anchored to an element or a point (the editor caret). Non-modal:
// the page stays usable; Escape and a press outside close it, and focus returns where it was.
import type { ReactNode } from "react";
import { Popover as BasePopover } from "@base-ui/react/popover";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";

/** A point or box on the page to place a popover at (a caret's coordinates, for example). */
export interface UiAnchorRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export type UiAnchor = Element | UiAnchorRect | null;

/** The Floating UI virtual element of a rect anchor. */
export function virtualAnchor(anchor: UiAnchor) {
  if (!anchor || anchor instanceof Element) return anchor;
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
  onOpenChange(open: boolean): void;
  /** Where it opens; it opens below. */
  anchor: UiAnchor;
  /** The accessible name of the popover (role dialog). */
  label: string;
  className?: string;
  /** Focus a field inside on open (default: the first focusable). */
  initialFocus?: React.RefObject<HTMLElement | null> | boolean;
  /** Where focus goes on close (default: back to where it was). */
  finalFocus?: React.RefObject<HTMLElement | null> | boolean;
  children: ReactNode;
}

export function Popover({
  open,
  onOpenChange,
  anchor,
  label,
  className,
  initialFocus,
  finalFocus,
  children,
}: PopoverProps) {
  const container = usePortalContainer();
  return (
    <BasePopover.Root open={open} onOpenChange={(next) => onOpenChange(next)} modal={false}>
      <BasePopover.Portal container={container}>
        <BasePopover.Positioner
          className="ui-positioner"
          anchor={virtualAnchor(anchor)}
          side="bottom"
          align="start"
          sideOffset={6}
        >
          <BasePopover.Popup
            className={cx("ui-popup ui-popover", className)}
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
