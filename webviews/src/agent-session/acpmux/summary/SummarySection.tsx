import React, { useState } from "react";
import { useT } from "../i18n";

/// Rows a section shows before "View all".
const FOLDED = 5;

/// One titled list in the summary popover. A long list shows its first rows and a "View all"
/// that opens the rest in place. A section with nothing to list is not drawn: no title over
/// "None". `lead` is the list's first row, unfolded; `footer` draws under the list (Outputs'
/// gallery row), and a section with only a lead or a footer still draws.
export function SummarySection<T>({
  title,
  items,
  row,
  lead,
  footer,
  action,
  keep = false,
}: {
  title: string;
  items: readonly T[];
  row: (item: T) => React.ReactNode;
  lead?: React.ReactNode;
  footer?: React.ReactNode;
  /// A control at the title's end (Sources' Attach files or folders).
  action?: React.ReactNode;
  /// Draw the section with nothing to list (Sources while its + offers Use tools).
  keep?: boolean;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  if (items.length === 0 && !lead && !footer && !keep) return null;
  const heading = action ? (
    <div className="acpmux-summary-heading">
      <h3 className="acpmux-summary-title">{title}</h3>
      {action}
    </div>
  ) : (
    <h3 className="acpmux-summary-title">{title}</h3>
  );
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
