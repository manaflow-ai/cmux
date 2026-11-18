// A loading placeholder in shadcn's shape (one element, sized by its caller), drawn with our tokens and
// our motion, never a plain pulse: it breathes with `cmux-breathe` (desktop.css) on the shared clock
// (ui/spinnerClock.ts), so every placeholder on screen breathes as one with agent work's dot, and it holds
// still under the system's Reduce Motion, the app's motion setting (`data-cmux-motion` off or reduced)
// and Settings > Static status indicators.
//
// A skeleton is decoration: it is `aria-hidden`, and the region it stands in for says it is loading
// (`aria-busy` and a label on the host, as the Apps grid does).
import type { HTMLAttributes } from "react";
import { cx } from "./cx";
import "./skeleton.css";

/** block: a filled box (an icon, a card's footer). line: one line of text's height. circle: an avatar. */
export type SkeletonShape = "block" | "line" | "circle";

export interface SkeletonProps extends Omit<HTMLAttributes<HTMLSpanElement>, "children"> {
  shape?: SkeletonShape;
}

export function Skeleton({ shape = "block", className, ...rest }: SkeletonProps) {
  return <span aria-hidden="true" {...rest} className={cx("ui-skeleton", className)} data-shape={shape} />;
}
