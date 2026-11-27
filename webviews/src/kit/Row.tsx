// One list row, inside a `List`: an optional leading mark (icon, status, avatar), a title, an optional second line
// and a trailing column (a pill or a count). With `onSelect` the whole row is the one
// open target (the sidebar spec: no separate Open button); without it the row is static text.
// Hover and selection fill the row from the theme's roles; nothing in the row changes weight.
// A host that draws its own rows (a customize scene's) can hold the row element (`ref`), hand it any
// other attribute or handler (drag and reorder), set the second line in the detail size, and give the
// selection its own fill with `--kit-row-selected-fill` on the row. Left out, the row is as before.
import { forwardRef, type HTMLAttributes, type ReactNode, type Ref } from "react";
import { cx } from "../ui/cx";
import { revealControls } from "../ui/revealCover";

export type RowDensity = "compact" | "comfortable";
/** The second line's type step: `caption` (the default) or `detail`. */
export type RowSubtitleSize = "caption" | "detail";

/** Every other attribute and handler goes onto the row element (the button, or the static div). */
type RowElementProps = Omit<HTMLAttributes<HTMLElement>, "title" | "onSelect" | "className" | "children">;

export interface RowProps extends RowElementProps {
  title: ReactNode;
  /** A second line in the secondary color. Leave it out when it would only repeat the title. */
  subtitle?: ReactNode;
  /** The second line's type step; `detail` is the customize scene's. Default `caption`. */
  subtitleSize?: RowSubtitleSize;
  /** The leading column: an `Icon`, a `StatusGlyph`, a spinner or an `Avatar`. */
  leading?: ReactNode;
  /** Always visible. Use a Pill or count here, and put interactive controls in hoverActions. */
  trailing?: ReactNode;
  /** Secondary controls over the end of the text on hover or focus. Always visible on touch. */
  hoverActions?: ReactNode;
  /** The row the person is on (`aria-current`): the selection fill. */
  selected?: boolean;
  /** compact 28, comfortable 32 (design/system.md rows). */
  density?: RowDensity;
  /** What assistive tech reads for the whole row when the visible text leaves out its state. */
  label?: string;
  onSelect?(): void;
  className?: string;
}

export const Row = forwardRef<HTMLElement, RowProps>(function Row(
  {
    title,
    subtitle,
    subtitleSize,
    leading,
    trailing,
    hoverActions,
    selected = false,
    density = "compact",
    label,
    onSelect,
    className,
    ...rest
  },
  ref,
) {
  const hasActions = hoverActions != null && typeof hoverActions !== "boolean";
  const body = (
    <>
      {leading !== undefined && <span className="kit-row-lead">{leading}</span>}
      <span className={cx("kit-row-text", hasActions && "ui-reveal-text")}>
        <span className="kit-row-title">{title}</span>
        {subtitle !== undefined && <span className="kit-row-subtitle">{subtitle}</span>}
      </span>
      {trailing !== undefined && <span className="kit-row-trail">{trailing}</span>}
    </>
  );
  const shared = {
    ...rest,
    className: cx("kit-row", className),
    "data-density": density,
    "data-subtitle-size": subtitleSize === "detail" ? subtitleSize : undefined,
    "data-selected": selected ? "" : undefined,
    "aria-current": selected ? ("true" as const) : undefined,
  };
  // A button takes its name from aria-label; a plain element can't be named, so a static row reads
  // the label as hidden text and hides the visible text it replaces.
  return (
    <li className={cx("kit-row-item", hasActions && "ui-reveal-host")}>
      {onSelect ? (
        <button
          type="button"
          ref={ref as Ref<HTMLButtonElement>}
          {...shared}
          aria-label={label ?? rest["aria-label"]}
          onClick={onSelect}
        >
          {body}
        </button>
      ) : (
        <div ref={ref as Ref<HTMLDivElement>} {...shared}>
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
      {hasActions && (
        <span className="kit-row-actions ui-reveal" ref={revealControls}>
          {hoverActions}
        </span>
      )}
    </li>
  );
});
