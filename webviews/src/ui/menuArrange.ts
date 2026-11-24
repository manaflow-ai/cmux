// The order and icon columns of a page-drawn context menu under the menu-style-v2 experiment
// (menuStyleV2.experiment.ts). Pure: one pass over the rows, no measurement, so its cost grows with
// the rows and nothing else.

/** The fields of a row the arrangement reads (ContextMenu's `ContextMenuItem`). */
export interface ArrangeableRow {
  icon?: unknown;
  destructive?: boolean;
  separatorBefore?: boolean;
}

export interface ArrangedRow<Row> {
  item: Row;
  /** A divider draws above this row: it starts a group that is not the first. */
  separatorBefore: boolean;
  /** The row draws its icon: icons are all-or-none per divider group, so a group where any row has
   *  none draws no icons at all (the native menu's rule, ActionRegistry+ContextMenus styleV2). */
  iconSlot: boolean;
}

/**
 * The rows in their v2 order: the groups between dividers as given, less their destructive rows,
 * which move, in their order, into one last group of their own. A group a move empties drops out,
 * with its divider. A group draws its icons only when every row in it has one.
 */
export function arrangeMenuRows<Row extends ArrangeableRow>(rows: readonly Row[]): ArrangedRow<Row>[] {
  const groups: Row[][] = [];
  const destructive: Row[] = [];
  for (const row of rows) {
    if (row.separatorBefore || groups.length === 0) groups.push([]);
    if (row.destructive) destructive.push(row);
    else groups[groups.length - 1]!.push(row);
  }
  const ordered = groups.filter((group) => group.length > 0);
  if (destructive.length > 0) ordered.push(destructive);
  const arranged: ArrangedRow<Row>[] = [];
  ordered.forEach((group, index) => {
    const iconSlot = group.every((row) => Boolean(row.icon));
    group.forEach((item, at) => arranged.push({ item, separatorBefore: index > 0 && at === 0, iconSlot }));
  });
  return arranged;
}

/** Whether a row's `onSelect` returned its work's promise (an async row, menu-row-states). */
export function isThenable(value: unknown): value is PromiseLike<unknown> {
  return (
    (typeof value === "object" || typeof value === "function") &&
    value !== null &&
    typeof (value as { then?: unknown }).then === "function"
  );
}
