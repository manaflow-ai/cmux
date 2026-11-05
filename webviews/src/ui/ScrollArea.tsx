// A scroll container with a thin overlay scrollbar over Base UI ScrollArea (Lawrence 2026-10-09: "i dont like
// the scrollbar can we use thinner one from baseui that looks very clean?"). The viewport scrolls natively
// (wheel, trackpad, keyboard, scrollIntoView) and hides the system scrollbar; a 6px rounded thumb with no track
// fades in while the pointer is over the area or it scrolls, and is never drawn when nothing overflows. Colors
// follow the surrounding text (`--ui-scroll-thumb` overrides), so it fits the agent pane and the pages alike.
// Tailwind classes only, so the pane bundle and the pages compile the same rules.
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
    </BaseScrollArea.Root>
  );
}
