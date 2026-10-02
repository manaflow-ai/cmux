// Anchored popovers: the one primitive behind every menu, picker, hover card and tooltip
// that opens from a control. The box is a popover in the browser top layer (nothing clips
// it: not the sidebar's scroller, not the transcript, not Pierre's shadow roots) and is
// placed with CSS anchor positioning against the control that owns it: the control carries
// `anchor-name` (anchorProps), the popover `position-anchor`, and its class places it with
// anchor() offsets plus `position-try-fallbacks`, so it flips or pins inside the viewport
// at the edges (popover.css). No layout is measured in JS.
import type { CSSProperties, ReactNode, ToggleEvent } from "react";
import "./popover.css";

export type PopoverProps = {
  /** Anchor name of the owning control (`--…`). */
  anchor: string;
  /** Placement (anchor() insets, fallbacks) and look. */
  className: string;
  role?: string;
  /**
   * Makes it an auto popover: the browser light-dismisses it (outside click, Escape) and
   * reports that here. The anchor element is the popover's `source`, so clicking the
   * trigger again toggles instead of dismiss-then-reopen. Without it the popover is manual:
   * its visibility is purely whether it is rendered.
   */
  onDismiss?: () => void;
  style?: CSSProperties;
  children: ReactNode;
};

/** Callback ref: promote the element to the top layer as soon as it is attached. */
const show = (anchor: string) => (el: HTMLElement | null) => {
  if (!el?.isConnected || el.matches(":popover-open")) return;
  const source = el.ownerDocument.querySelector(`[data-anchor="${CSS.escape(anchor)}"]`);
  (el.showPopover as (o?: { source?: Element }) => void)(source ? { source } : undefined);
};

/** A top-layer box placed against `anchor`. It stays a DOM child of where it renders. */
export function Popover({ anchor, className, role, onDismiss, style, children }: PopoverProps) {
  return (
    <div
      popover={onDismiss ? "auto" : "manual"}
      ref={show(anchor)}
      role={role}
      className={`cx-popover ${className}`}
      // Always fixed: classes shared with in-flow boxes (`.cx-menu` is absolute) must not
      // change the containing block to anything but the viewport.
      style={{ ...style, position: "fixed", positionAnchor: anchor } as CSSProperties}
      onToggle={
        onDismiss && ((e: ToggleEvent<HTMLDivElement>) => e.newState === "closed" && onDismiss())
      }
    >
      {children}
    </div>
  );
}
