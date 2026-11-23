// Enumerable so a projected row that spreads its source keeps the book's durable revision.
// A symbol keeps this renderer metadata out of the serialized view.
export const BOOK_REVISION = Symbol("chat book row revision");

export function bookRevision(row: object): number | undefined {
  return (row as { [BOOK_REVISION]?: number })[BOOK_REVISION];
}
