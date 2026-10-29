// l10n-allow-file: transcript geometry fixtures.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow, type RowHeights } from "./model";

const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 0,
  ...fields,
});
const footer = row("footer", "turnSummary", { text: "Done.", durationMs: 1000, status: "completed" });

test("same assistant continuation halves the footer gap; a speaker change and the end retain it", () => {
  const assistant = row("next", "assistant", { text: "Next update." });
  const height = (next?: AcpmuxRow) => layoutConversation(next ? [footer, next] : [footer], 720).heights[0];
  expect(height(assistant)).toBe(32);
  expect(height(row("user", "user", { text: "Next task." }))).toBe(40);
  expect(
    height(
      row("peer", "user", {
        incoming: { kind: "message", message: { name: "other-agent", text: "Report.", raw: "Report." } },
      }),
    ),
  ).toBe(40);
  expect(height()).toBe(40);
});

test("a retained footer changes its estimate when a continuation arrives or becomes a user row", () => {
  const hidden = row("hidden", "user", { incoming: { kind: "hidden" } });
  const known: RowHeights = new WeakMap();
  const rows = [footer, hidden];
  const layout = layoutConversation(rows, 720, undefined, undefined, known);
  const next = [...rows, row("next", "assistant", { text: "Next update." })];
  const continued = layoutConversation(next, 720, undefined, undefined, known, { rows, layout });
  expect(continued.heights[0]).toBe(32);
  expect(continued).toEqual(layoutConversation(next, 720));
  const changed = [...rows, row("next", "user", { text: "Next task." })];
  const switched = layoutConversation(changed, 720, undefined, undefined, known, { rows: next, layout: continued });
  expect(switched.heights[0]).toBe(40);
  expect(switched).toEqual(layoutConversation(changed, 720));
});

test("empty continuation footers retain the full hover-control floor", () => {
  const empty = row("empty", "turnSummary", { status: "completed", durationMs: 0 });
  expect(layoutConversation([empty, row("next", "assistant", { text: "Next update." })], 720).heights[0]).toBe(24);
});
