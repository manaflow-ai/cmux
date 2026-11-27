// A scroll container with a thin overlay scrollbar over Base UI ScrollArea (Lawrence 2026-10-09: "i dont like
// the scrollbar can we use thinner one from baseui that looks very clean?"). The viewport scrolls natively
// (wheel, trackpad, keyboard, scrollIntoView) and hides the system scrollbar; a 6px rounded thumb with no track
// fades in while the pointer is over the area or it scrolls, and is never drawn when nothing overflows. Colors
// follow the surrounding text (`--ui-scroll-thumb` overrides), so it fits the agent pane and the pages alike.
// Tailwind classes only, so the pane bundle and the pages compile the same rules.
//
// Keyboard focus: Base UI makes the viewport a Tab stop while it overflows (tabIndex 0), and the arrows,
// Page Up and Down, Home and End then scroll it. The shared page ring (desktop.css) is an outline outside the
// viewport's box, which the root's `overflow: hidden` clips away entirely, so a focused scroller showed nothing.
// The viewport draws the same ring inset instead: the shared width and colour, inside its own edge, gated to
// keyboard-earned focus like every `:focus-visible` (focusModality.ts). A viewport that carries a role or
// `data-focus-ring` (a list that shows its own active row) keeps that role's rule, as desktop.css does.
// When both bars show, Base UI's Corner fills the square where they meet, so neither thumb runs under the other.
import type { HTMLAttributes, ReactNode } from "react";
import { ScrollArea as BaseScrollArea } from "@base-ui/react/scroll-area";
import { cx } from "./cx";
import { useScrollEdges } from "./scrollEdges";

export interface ScrollAreaProps {
  /** Classes on the outer box (size, border, background). */
  className?: string;
  /** Classes on the scrolling viewport (padding, flex layout of the content). */
  viewportClassName?: string;
  /** Extra props for the viewport (role, aria-label, id), so a list keeps its own semantics there. */
  viewportProps?: HTMLAttributes<HTMLDivElement>;
  /** Also draw a horizontal scrollbar (wide content such as code). */
  horizontal?: boolean;
  /** Fade overflowing list rows at their vertical edges. */
  fade?: boolean;
  children: ReactNode;
}

const scrollbar =
  "flex touch-none select-none p-px opacity-0 transition-opacity duration-(--cmux-motion-micro) motion-reduce:transition-none " +
  "data-hovering:opacity-100 data-scrolling:opacity-100 data-scrolling:duration-0";
const thumb =
  "rounded-full bg-(--ui-scroll-thumb,color-mix(in_srgb,currentColor_32%,transparent)) " +
  "hover:bg-(--ui-scroll-thumb-hover,color-mix(in_srgb,currentColor_48%,transparent)) " +
  // Base UI updates the thumb size through --scroll-area-thumb-{height,width}. Size changes
  // apply immediately so the scrollbar never animates layout; only its colour uses the motion scale.
  "transition-[background-color] duration-(--cmux-motion-standard) ease-(--cmux-ease-out) " +
  "data-scrolling:transition-none motion-reduce:transition-none";
/** The inset keyboard ring (see the header). Important, in the utilities layer, so it beats the unlayered page
 * ring's outward offset under Increase Contrast, which the root would clip. */
export const SCROLL_AREA_FOCUS_RING =
  "[&:focus-visible:not([role],[data-focus-ring])]:outline-solid! " +
  "[&:focus-visible:not([role],[data-focus-ring])]:outline-[length:var(--cmux-focus-ring-width,1.5px)]! " +
  "[&:focus-visible:not([role],[data-focus-ring])]:outline-[color:var(--cmux-focus-ring-color,currentColor)]! " +
  "[&:focus-visible:not([role],[data-focus-ring])]:outline-offset-[calc(-1*var(--cmux-focus-ring-width,1.5px))]! " +
  "[&:focus-visible:not([role],[data-focus-ring])]:rounded-[inherit]";

export function ScrollArea({
  className,
  viewportClassName,
  viewportProps,
  horizontal = false,
  fade = false,
  children,
}: ScrollAreaProps) {
  const edges = useScrollEdges();
  return (
    <BaseScrollArea.Root className={cx("relative min-h-0 min-w-0 overflow-hidden", className)}>
      <BaseScrollArea.Viewport
        {...viewportProps}
        ref={fade ? edges : undefined}
        className={cx(
          "h-full max-h-[inherit] w-full overscroll-contain outline-none",
          SCROLL_AREA_FOCUS_RING,
          fade && "ui-scroll-edge-fade",
          viewportClassName,
        )}
      >
        {/* Content is what Base UI watches for size changes: without it the thumb keeps its first size when
            the list grows or shrinks in place. Its default min-width (fit-content) would stop long rows from
            truncating, so only a horizontal area keeps it. */}
        <BaseScrollArea.Content style={horizontal ? undefined : { minWidth: 0 }}>{children}</BaseScrollArea.Content>
      </BaseScrollArea.Viewport>
      <BaseScrollArea.Scrollbar
        orientation="vertical"
        className={cx("cmux-scrollbar", scrollbar, "w-1.5 justify-center")}
      >
        <BaseScrollArea.Thumb className={cx("cmux-scrollbar-thumb", thumb, "w-full")} />
      </BaseScrollArea.Scrollbar>
      {horizontal && (
        <BaseScrollArea.Scrollbar
          orientation="horizontal"
          className={cx("cmux-scrollbar", scrollbar, "h-1.5 flex-col justify-center")}
        >
          <BaseScrollArea.Thumb className={cx("cmux-scrollbar-thumb", thumb, "h-full")} />
        </BaseScrollArea.Scrollbar>
      )}
      {/* Rendered only while both bars show (Base UI hides it otherwise). */}
      {horizontal && <BaseScrollArea.Corner className="cmux-scrollbar-corner bg-transparent" />}
    </BaseScrollArea.Root>
  );
}
