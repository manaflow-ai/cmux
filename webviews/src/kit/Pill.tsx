// A capsule label: a count, a tag, a short state. Tones are the theme's roles; a neutral pill is
// the hover wash, so it reads on glass and over a picture.
import type { ReactNode } from "react";
import { cx } from "../ui/cx";

export type PillTone = "neutral" | "accent" | "success" | "attention" | "danger";
/** xs 16, sm 20, md 24 (design/system.md pills). xs is the customize scene's badge: the grid's
 * icon box tall, the detail type step, and a neutral fill of its own text color; its corner is a
 * capsule unless the host sets `--kit-pill-radius`. */
export type PillSize = "xs" | "sm" | "md";

export interface PillProps {
  tone?: PillTone;
  size?: PillSize;
  /** A leading `Icon` or `StatusGlyph`. */
  icon?: ReactNode;
  className?: string;
  children?: ReactNode;
}

export function Pill({ tone = "neutral", size = "md", icon, className, children }: PillProps) {
  return (
    <span className={cx("kit-pill", className)} data-tone={tone} data-size={size}>
      {icon}
      {children}
    </span>
  );
}
