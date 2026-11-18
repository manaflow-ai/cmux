// A row store row's id (wire.ts ChatRow.id) as its own type. A v1 chat's log seq is a number too,
// and one passed where a row id goes would page the wrong rows (6d decision 410): only a store row's
// view id (`row-<id>`, rows/adapter.ts) makes a RowId, so a seq cannot compile into
// `ChatSource.through`.
declare const rowIdBrand: unique symbol;
export type RowId = number & { readonly [rowIdBrand]: true };

/// The store row a view row names (`row-<id>`), or undefined for a v1 row (`user-<seq>`, ...).
export function promptRowId(viewId: string): RowId | undefined {
  const match = /^row-(\d+)$/.exec(viewId);
  return match ? (Number(match[1]) as RowId) : undefined;
}
