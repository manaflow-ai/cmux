import React, { useState } from "react";
import { useT } from "../i18n";

/// Rows a section shows before "View all".
const FOLDED = 5;

/// One titled list in the summary popover. A long list shows its first rows and a "View all"
/// that opens the rest in place. A `fixed` section stays while empty, with "None", so the
/// popover keeps its sections in place while a turn adds to them. `footer` draws under the list,
/// empty or not. `action` sits at the title's end (Sources' "+"); `id` names the section for the
/// summary's menu and for automation.
export function SummarySection<T>({
  id,
  title,
  items,
  row,
  fixed = false,
  footer,
  action,
}: {
  id?: string;
  title: string;
  items: readonly T[];
  row: (item: T) => React.ReactNode;
  fixed?: boolean;
  footer?: React.ReactNode;
  action?: React.ReactNode;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const heading = action ? (
    <div className="flex items-center justify-between pr-1">
      <h3 className="acpmux-summary-title">{title}</h3>
      {action}
    </div>
  ) : (
    <h3 className="acpmux-summary-title">{title}</h3>
  );
  if (items.length === 0) {
    if (!fixed) return null;
    return (
      <section className="acpmux-summary-section" aria-label={title} data-summary-section={id}>
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
    <section className="acpmux-summary-section" aria-label={title} data-summary-section={id}>
      {heading}
      <ul className="acpmux-summary-list">{shown.map((item) => row(item))}</ul>
      {items.length > FOLDED && (
        <button type="button" className="acpmux-summary-more" onClick={() => setAll(!all)}>
          {all ? t("summary.showFewer") : t("summary.viewAll", { n: items.length })}
        </button>
      )}
      {footer}
    </section>
  );
}
