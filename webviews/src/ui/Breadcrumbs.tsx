// A breadcrumb of folders: a `nav` of buttons, the last one `aria-current="location"`. The buttons
// are not Tab stops (the field next to it navigates by keyboard: Cmd-Up, Left, Backspace); a
// screen reader reaches them in the `nav` landmark, and a mouse press does not take focus.
import type { ReactNode } from "react";
import { cx } from "./cx";

export interface Crumb {
  label: string;
  path: string;
}

export interface BreadcrumbsProps {
  label: string;
  crumbs: readonly Crumb[];
  onNavigate(crumb: Crumb, index: number): void;
  /** Between two crumbs (index of the crumb after it); none by default. */
  separator?(index: number): ReactNode;
  className?: string;
  crumbClassName?: string;
}

export function Breadcrumbs({ label, crumbs, onNavigate, separator, className, crumbClassName }: BreadcrumbsProps) {
  return (
    <nav className={cx("ui-crumbs", className)} aria-label={label}>
      {crumbs.map((crumb, index) => (
        <span key={crumb.path} className="ui-crumb-wrap">
          {index > 0 ? separator?.(index) : null}
          <button
            type="button"
            className={cx("ui-crumb", crumbClassName)}
            tabIndex={-1}
            aria-current={index === crumbs.length - 1 ? "location" : undefined}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => onNavigate(crumb, index)}
          >
            {crumb.label}
          </button>
        </span>
      ))}
    </nav>
  );
}
