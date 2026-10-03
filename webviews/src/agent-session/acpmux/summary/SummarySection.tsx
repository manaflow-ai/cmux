import React, { useState } from "react";
import { t } from "../i18n";

/// Rows a section shows before "View all".
const FOLDED = 5;

/// One titled list in the summary popover. A long list shows its first rows and a "View all"
/// that opens the rest in place.
export function SummarySection<T>({
  title,
  items,
  row,
}: {
  title: string;
  items: readonly T[];
  row: (item: T) => React.ReactNode;
}) {
  const [all, setAll] = useState(false);
  if (items.length === 0) return null;
  const shown = all ? items : items.slice(0, FOLDED);
  return (
    <section className="acpmux-summary-section" aria-label={title}>
      <h3 className="acpmux-summary-title">{title}</h3>
      <ul className="acpmux-summary-list">{shown.map((item) => row(item))}</ul>
      {items.length > FOLDED && (
        <button type="button" className="acpmux-summary-more" onClick={() => setAll(!all)}>
          {all ? t("summary.showFewer") : t("summary.viewAll", { n: items.length })}
        </button>
      )}
    </section>
  );
}
