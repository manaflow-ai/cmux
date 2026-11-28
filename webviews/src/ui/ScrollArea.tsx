// A scroll container with a thin overlay scrollbar over Base UI ScrollArea (Lawrence 2026-10-09: "i dont like
// the scrollbar can we use thinner one from baseui that looks very clean?"). The viewport scrolls natively
// (wheel, trackpad, keyboard, scrollIntoView) and hides the system scrollbar; a 6px rounded thumb with no track
// fades in while the pointer is over the area or it scrolls, and is never drawn when nothing overflows. Colors
// follow the surrounding text (`--ui-scroll-thumb` overrides), so it fits the agent pane and the pages alike.
// Tailwind classes only, so the pane bundle and the pages compile the same rules.
import type { HTMLAttributes, ReactNode } from "react";
import { ScrollArea as BaseScrollArea } from "@base-ui/react/scroll-area";
import { cx } from "./cx";

export interface ScrollAreaProps {
  /** Classes on the outer box (size, border, background). */
  className?: string;
  /** Classes on the scrolling viewport (padding, flex layout of the content). */
  viewportClassName?: string;
  /** Extra props for the viewport (role, aria-label, id), so a list keeps its own semantics there. */
  viewportProps?: HTMLAttributes<HTMLDivElement>;
  /** Also draw a horizontal scrollbar (wide content such as code). */
  horizontal?: boolean;
  children: ReactNode;
}

const scrollbar =
  "flex touch-none select-none p-px opacity-0 transition-opacity duration-150 motion-reduce:transition-none " +
  "data-hovering:opacity-100 data-scrolling:opacity-100 data-scrolling:duration-0";
const thumb =
  "rounded-full bg-(--ui-scroll-thumb,color-mix(in_srgb,currentColor_32%,transparent)) " +
  "hover:bg-(--ui-scroll-thumb-hover,color-mix(in_srgb,currentColor_48%,transparent))";

export function ScrollArea({
  className,
  viewportClassName,
  viewportProps,
  horizontal = false,
  children,
}: ScrollAreaProps) {
  return (
    <BaseScrollArea.Root className={cx("relative min-h-0 min-w-0 overflow-hidden", className)}>
      <BaseScrollArea.Viewport
        {...viewportProps}
        className={cx("h-full max-h-[inherit] w-full overscroll-contain outline-none", viewportClassName)}
      >
        {children}
      </BaseScrollArea.Viewport>
      <BaseScrollArea.Scrollbar orientation="vertical" className={cx(scrollbar, "w-1.5 justify-center")}>
        <BaseScrollArea.Thumb className={cx(thumb, "w-full")} />
      </BaseScrollArea.Scrollbar>
      {horizontal && (
        <BaseScrollArea.Scrollbar orientation="horizontal" className={cx(scrollbar, "h-1.5 flex-col justify-center")}>
          <BaseScrollArea.Thumb className={cx(thumb, "h-full")} />
        </BaseScrollArea.Scrollbar>
      )}
    </BaseScrollArea.Root>
  );
}
