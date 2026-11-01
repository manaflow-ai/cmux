import React from "react";

/// One titled list in the summary popover. Long lists are drawn in full; the card body owns the
/// scrolling. A section with nothing to list is not drawn: no title over
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
  if (items.length === 0 && !lead && !footer && !keep) return null;
  const heading = action ? (
    <div className="acpmux-summary-heading">
      <h3 className="acpmux-summary-title">{title}</h3>
      {action}
    </div>
  ) : (
    <h3 className="acpmux-summary-title">{title}</h3>
  );
  return (
    <section className="acpmux-summary-section" aria-label={title}>
      {heading}
      <ul className="acpmux-summary-list">
        {lead}
        {items.map((item) => row(item))}
      </ul>
      {footer}
    </section>
  );
}
