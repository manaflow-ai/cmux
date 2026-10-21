// l10n-allow-file: test fixture replies, not shipped UI.
// The virtualizer's first-layout estimates (model.ts layoutConversation) match what the transcript's
// CSS draws (conversation/conversation.css, styles.css), so a row that mounts moves nothing below it
// and scrolling up never jumps:
//   - a reply right over its turn's footer (`.acpmux-row--before-footer`): its text and the 4px meta
//     gap, with no 34px floor;
//   - a task's result (`.cv-received`): its 26px line and the 8px message gap;
//   - a turn's footer: its 24px line and the 24px turn gap.
//
// Before: a reply over a footer was estimated as any reply (8px below it, at least 34px), and a
// task's result kept the old 16px below it.
import { expect, test } from "bun:test";
import { layoutConversation } from "./model";

const reply = (id: string, text: string) => ({ id, version: 1, at: 0, kind: "assistant", text });
const footer = (id: string) => ({ id, version: 1, at: 0, kind: "turnSummary", status: "completed" });
const heightsOf = (rows: unknown[]) => [...layoutConversation(rows as never, 720).heights];

test("a reply over its footer is its text and the 4px meta gap, with no 34px floor", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  const [alone] = heightsOf([reply("a", long)]);
  const [over, summary] = heightsOf([reply("a", long), footer("f")]);
  // The same text: 8px below it alone, 4px over its footer.
  expect(alone! - over!).toBeCloseTo(4, 5);
  // The footer: a 24px line and the 24px turn gap.
  expect(summary).toBe(48);
  // A one-line reply over its footer is shorter than a row's 34px floor.
  const [short] = heightsOf([reply("b", "Done."), footer("g")]);
  expect(short!).toBeLessThan(34);
  expect(short! - 4).toBeGreaterThan(0);
});

test("a reply estimated alone, then with its footer after it, is estimated again", () => {
  const rows = [reply("a", "Done.")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[0]).toBe(34);
  const next = [...rows, footer("f")];
  const second = layoutConversation(next as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second.heights[0]).toBeLessThan(34);
  expect(second.tops[1]).toBe(second.heights[0]);
});

test("a task's result is its 26px line and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "r", version: 1, at: 0, kind: "user", text: "Run the tests", received: { offerId: "o", title: "Tests" } },
  ]);
  expect(height).toBe(34);
});
