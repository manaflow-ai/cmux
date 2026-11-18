// A list of `Row`s with an optional section title and an empty state. An empty list with no
// `empty` content renders nothing, so it reserves no gap (the sidebar spec: empty sections take no space).
import { Children, useId, type ReactNode } from "react";
import { cx } from "../ui/cx";

export interface ListProps {
  /** The section title above the rows; it also names the list for assistive tech. */
  title?: ReactNode;
  /** The accessible name when there is no visible title. */
  label?: string;
  /** Shown in place of the rows when there are none. */
  empty?: ReactNode;
  className?: string;
  children?: ReactNode;
}

export function List({ title, label, empty, className, children }: ListProps) {
  const titleId = useId();
  const hasRows = Children.toArray(children).length > 0;
  if (!hasRows && empty === undefined) return null;
  return (
    <section className={cx("kit-list", className)}>
      {title !== undefined && (
        <h3 className="kit-list-title" id={titleId}>
          {title}
        </h3>
      )}
      {hasRows ? (
        <ul
          className="kit-list-rows"
          aria-labelledby={title !== undefined ? titleId : undefined}
          aria-label={title === undefined ? label : undefined}
        >
          {children}
        </ul>
      ) : (
        <p className="kit-list-empty">{empty}</p>
      )}
    </section>
  );
}
