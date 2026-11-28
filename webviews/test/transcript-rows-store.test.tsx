// The transcript rows store (pane/rowsStore.ts, stage 1 of the pane split): the pane's `rowsRef` is
// the store, so each `rowsRef.current = next.rows` the client paths make publishes that same array, in
// order, and the store's snapshot is always the snapshot's rows the pane is handed beside it.
import { expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { createRowsStore, TranscriptRowsContext, useTranscriptRows } from "../src/agent-session/acpmux/pane/rowsStore";

const row = (id: string) => ({ id }) as unknown as AcpmuxRow;

test("each record's rows publish as the same array, in order, with one notice per change", () => {
  const first = [row("a")];
  const store = createRowsStore(first);
  const seen: (readonly AcpmuxRow[])[] = [];
  const stop = store.subscribe(() => seen.push(store.snapshot()));
  expect(store.snapshot()).toBe(first);
  // The records a live chat sends: each a new rows array, as `receive` assigns `rowsRef.current`.
  const records = [
    [row("a"), row("b")],
    [row("a"), row("b"), row("c")],
    [row("a"), row("b"), row("c2")],
  ];
  for (const rows of records) {
    store.current = rows;
    expect(store.snapshot()).toBe(rows);
    expect(store.current).toBe(rows);
  }
  expect(seen).toEqual(records);
  for (const [index, rows] of seen.entries()) expect(rows).toBe(records[index]!);
  // The same array again is no news.
  store.current = records[2]!;
  expect(seen.length).toBe(3);
  stop();
  store.current = [row("z")];
  expect(seen.length).toBe(3);
});

test("useTranscriptRows reads the pane's store, and an empty one outside a pane", () => {
  function Ids() {
    return (
      <>
        {useTranscriptRows()
          .map((r) => r.id)
          .join(",")}
      </>
    );
  }
  const store = createRowsStore([row("x"), row("y")]);
  expect(
    renderToString(
      <TranscriptRowsContext.Provider value={store}>
        <Ids />
      </TranscriptRowsContext.Provider>,
    ),
  ).toBe("x,y");
  expect(renderToString(<Ids />)).toBe("");
});
