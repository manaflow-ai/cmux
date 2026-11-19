import { expect, test } from "bun:test";
import { RowPatchBook, type RowNotice } from "./rowPatch";

const rowOf = (notice: RowNotice) => {
  if ("missing" in notice) throw new Error("a patch with no row held");
  return notice.params.session as Record<string, unknown>;
};

test("patches laid over the held row equal each whole row, field changes, adds and removals", () => {
  const book = new RowPatchBook();
  const rows = [
    { sessionId: "a", n: 1, title: "t", usage: { x: 1 } },
    { sessionId: "a", n: 2, title: "t", usage: { x: 1 } },
    { sessionId: "a", n: 2, usage: { x: 2 }, retry: { at: 5 } },
  ];
  book.whole({ sessionId: "a", kind: "row", session: rows[0] });
  const second = book.patch({ sessionId: "a", kind: "row", listSeq: 7, patch: { n: 2 } });
  expect(rowOf(second)).toEqual(rows[1]);
  expect("missing" in second ? undefined : second.params.listSeq).toBe(7);
  expect("missing" in second ? undefined : second.params.patch).toBeUndefined();
  const third = book.patch({ sessionId: "a", patch: { usage: { x: 2 }, retry: { at: 5 } }, unset: ["title"] });
  expect(rowOf(third)).toEqual(rows[2]);
  // A new object each time, so a list keyed on row identity redraws the row.
  expect(rowOf(third)).not.toBe(rowOf(second));
  // An empty patch keeps the row as it is.
  expect(rowOf(book.patch({ sessionId: "a", patch: {} }))).toEqual(rows[2]);
});

test("a whole row after patches (a lag, a new watch) is the new base", () => {
  const book = new RowPatchBook();
  book.whole({ sessionId: "a", session: { sessionId: "a", n: 1, old: true } });
  book.patch({ sessionId: "a", patch: { n: 2 } });
  book.whole({ sessionId: "a", session: { sessionId: "a", n: 5 } });
  expect(rowOf(book.patch({ sessionId: "a", patch: { n: 6 } }))).toEqual({ sessionId: "a", n: 6 });
});

test("a peer's row and this daemon's row of the same id are held apart", () => {
  const book = new RowPatchBook();
  book.whole({ sessionId: "a", session: { sessionId: "a", here: true } });
  book.whole({ sessionId: "a", peer: "m", session: { sessionId: "a", there: true } });
  expect(rowOf(book.patch({ sessionId: "a", peer: "m", patch: { n: 1 } }))).toEqual({
    sessionId: "a",
    there: true,
    n: 1,
  });
  expect(rowOf(book.patch({ sessionId: "a", patch: { n: 2 } }))).toEqual({ sessionId: "a", here: true, n: 2 });
});

test("a patch with no row held is missing: after a purge, a reset, or never seen", () => {
  const book = new RowPatchBook();
  expect(book.patch({ sessionId: "a", patch: { n: 1 } })).toEqual({ missing: true });
  book.whole({ sessionId: "a", session: { sessionId: "a" } });
  book.whole({ sessionId: "a", kind: "purged", session: { sessionId: "a" } });
  expect(book.patch({ sessionId: "a", patch: { n: 1 } })).toEqual({ missing: true });
  book.whole({ sessionId: "b", session: { sessionId: "b" } });
  book.reset();
  expect(book.size).toBe(0);
  expect(book.patch({ sessionId: "b", patch: { n: 1 } })).toEqual({ missing: true });
});
