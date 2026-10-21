import React, { useState } from "react";
import { useT } from "../i18n";

/// Rows a section shows before "View all".
const FOLDED = 5;

/// One titled list in the summary popover. A long list shows its first rows and a "View all"
/// that opens the rest in place. A `fixed` section stays while empty, with "None", so the
/// popover keeps its sections in place while a turn adds to them. `lead` is the list's first row,
/// unfolded (a section with one stays without "None"); `footer` draws under the list, empty or not.
export function SummarySection<T>({
  title,
  items,
  row,
  fixed = false,
  lead,
  footer,
  action,
}: {
  title: string;
  items: readonly T[];
  row: (item: T) => React.ReactNode;
  fixed?: boolean;
  lead?: React.ReactNode;
  footer?: React.ReactNode;
  /// A control at the title's end (Sources' Attach files or folders).
  action?: React.ReactNode;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const heading = action ? (
    <div className="acpmux-summary-heading">
      <h3 className="acpmux-summary-title">{title}</h3>
      {action}
    </div>
  ) : (
    <h3 className="acpmux-summary-title">{title}</h3>
  );
  if (items.length === 0 && !lead) {
    if (!fixed) return null;
    return (
      <section className="acpmux-summary-section" aria-label={title}>
        {heading}
        <ul className="acpmux-summary-list">
          <li className="acpmux-summary-row acpmux-summary-none">{t("summary.none")}</li>
        </ul>
        {footer}
      </section>
    );
  }
  const shown = all ? items : items.slice(0, FOLDED);
  return (
    <section className="acpmux-summary-section" aria-label={title}>
      {heading}
      <ul className="acpmux-summary-list">
        {lead}
        {shown.map((item) => row(item))}
      </ul>
      {items.length > FOLDED && (
        <button type="button" className="acpmux-summary-more" onClick={() => setAll(!all)}>
          {all ? t("summary.showFewer") : t("summary.viewAll", { n: items.length })}
        </button>
      )}
      {footer}
    </section>
  );
}
