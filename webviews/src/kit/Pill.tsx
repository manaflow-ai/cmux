// A capsule label: a count, a tag, a short state. Tones are the theme's roles; a neutral pill is
// the hover wash, so it reads on glass and over a picture.
import type { ReactNode } from "react";
import { cx } from "../ui/cx";

export type PillTone = "neutral" | "accent" | "success" | "attention" | "danger";
/** sm 20, md 24 (design/system.md pills). */
export type PillSize = "sm" | "md";

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
