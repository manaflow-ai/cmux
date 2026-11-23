// One list row, inside a `List`: an optional leading mark (icon, status, avatar), a title, an optional second line
// and a trailing column (a pill, a count, a hover action). With `onSelect` the whole row is the one
// open target (the sidebar spec: no separate Open button); without it the row is static text.
// Hover and selection fill the row from the theme's roles; nothing in the row changes weight.
import type { ReactNode } from "react";
import { cx } from "../ui/cx";

export type RowDensity = "compact" | "comfortable";

export interface RowProps {
  title: ReactNode;
  /** A second line in the secondary color. Leave it out when it would only repeat the title. */
  subtitle?: ReactNode;
  /** The leading column: an `Icon`, a `StatusGlyph`, a spinner or an `Avatar`. */
  leading?: ReactNode;
  /** The trailing column: a `Pill`, a count or a small `Button`. */
  trailing?: ReactNode;
  /** The row the person is on (`aria-current`): the selection fill. */
  selected?: boolean;
  /** compact 28, comfortable 32 (design/system.md rows). */
  density?: RowDensity;
  /** What assistive tech reads for the whole row when the visible text leaves out its state. */
  label?: string;
  onSelect?(): void;
  className?: string;
}

export function Row({
  title,
  subtitle,
  leading,
  trailing,
  selected = false,
  density = "compact",
  label,
  onSelect,
  className,
}: RowProps) {
  const body = (
    <>
      {leading !== undefined && <span className="kit-row-lead">{leading}</span>}
      <span className="kit-row-text">
        <span className="kit-row-title">{title}</span>
        {subtitle !== undefined && <span className="kit-row-subtitle">{subtitle}</span>}
      </span>
      {trailing !== undefined && <span className="kit-row-trail">{trailing}</span>}
    </>
  );
  const shared = {
    className: cx("kit-row", className),
    "data-density": density,
    "data-selected": selected ? "" : undefined,
    "aria-current": selected ? ("true" as const) : undefined,
  };
  // A button takes its name from aria-label; a plain element can't be named, so a static row reads
  // the label as hidden text and hides the visible text it replaces.
  return (
    <li className="kit-row-item">
      {onSelect ? (
        <button type="button" {...shared} aria-label={label} onClick={onSelect}>
          {body}
        </button>
      ) : (
        <div {...shared}>
          {label !== undefined && <span className="ui-sr-only">{label}</span>}
          {label !== undefined ? (
            <span className="kit-row-body" aria-hidden="true">
              {body}
            </span>
          ) : (
            body
          )}
        </div>
      )}
    </li>
  );
}
