// A region on glass: the kit's way for a page to put a block of its own on cmux's material, at one of
// the levels the App draws (CmuxNextDesign GlassLevel): `chrome` (docked, like the sidebar's cards),
// `popover`, `menu` or `chip`. It is the page's glass (ui/glass/glass.css: the plain blur, or the lens
// when it is on, and the opaque surface under Reduce Transparency), tuned to the App's material at the
// same level; a customize scene node's `.glass(level)` is the native twin. Glass is paint only: the
// region's box is the same with it or without it, so a look that adds glass moves nothing.
import type { CSSProperties, ReactNode } from "react";
import { cx } from "../ui/cx";

export type GlassLevel = "chrome" | "popover" | "menu" | "chip";

export interface GlassProps {
  level?: GlassLevel;
  /** Corner radius in CSS px; the kit's card radius by default. */
  radius?: number;
  className?: string;
  style?: CSSProperties;
  children?: ReactNode;
}

export function Glass({ level = "popover", radius, className, style, children }: GlassProps) {
  return (
    <div
      className={cx("kit-glass ui-glass", className)}
      data-glass-level={level}
      style={radius === undefined ? style : { ...style, borderRadius: radius }}
    >
      {children}
    </div>
  );
}
