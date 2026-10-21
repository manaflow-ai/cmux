// l10n-allow-file: test fixture replies, not shipped UI.
// The virtualizer's first-layout estimates (model.ts layoutConversation) match what the transcript's
// CSS draws (conversation/conversation.css, styles.css), so a row that mounts moves nothing below it
// and scrolling up never jumps:
//   - a reply right over its turn's footer (`.acpmux-row--before-footer`), or over the running turn's
//     line that the footer takes the place of: its text and the 4px meta gap, with no 34px floor;
//   - a task's result (`.cv-received`): its 26px line and the 8px message gap;
//   - a turn's footer: its 24px line and the 24px turn gap, or the 8px message gap for the chat's
//     last one (`.acpmux-row--last-footer`), so no band sits over the composer.
//
// Before: a reply over a footer was estimated as any reply (8px below it, at least 34px), and a
// task's result kept the old 16px below it.
import { expect, test } from "bun:test";
import { layoutConversation } from "./model";
import { turnView } from "./conversation/turns";
import { COLLAPSED_PROMPT_LINES, PASTE_CHIP_HEIGHT, PROMPT_MORE_HEIGHT } from "./conversation/promptCollapse";
import { currentChatMetrics } from "./chatDisplay";

const reply = (id: string, text: string) => ({ id, version: 1, at: 0, kind: "assistant", text });
// A footer carries its answer's text, for Copy (conversation/turns.ts), so the estimate never reads it.
const footer = (id: string) => ({
  id,
  version: 1,
  at: 0,
  kind: "turnSummary",
  status: "completed",
  text: "An answer long enough to wrap onto many lines. ".repeat(30),
});
const prompt = (id: string) => ({ id, version: 1, at: 0, kind: "user", text: "Next" });
const heightsOf = (rows: unknown[]) => [...layoutConversation(rows as never, 720).heights];

test("a reply over its footer is its text and the 4px meta gap, with no 34px floor", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  const [alone] = heightsOf([reply("a", long)]);
  const [over, summary] = heightsOf([reply("a", long), footer("f"), prompt("p")]);
  // The same text: 8px below it alone, 4px over its footer.
  expect(alone! - over!).toBeCloseTo(4, 5);
  // The footer: a 24px line and the 24px turn gap; the chat's last one, the 8px message gap.
  expect(summary).toBe(48);
  expect(heightsOf([reply("a", long), footer("f")])[1]).toBe(32);
  // A one-line reply over its footer is shorter than a row's 34px floor.
  const [short] = heightsOf([reply("b", "Done."), footer("g")]);
  expect(short!).toBeLessThan(34);
  expect(short! - 4).toBeGreaterThan(0);
});

test("a reply over its running turn's line is estimated as over the footer that takes its place", () => {
  const long = "A longer answer that wraps. ".repeat(40);
  // The running turn's line as its last row (conversation/turns.ts `below`): the footer's height.
  const line = { id: "live", version: 1, at: 0, kind: "thinking", below: true };
  const [running, lineHeight] = heightsOf([reply("a", long), line]);
  const [ended, footerHeight] = heightsOf([reply("a", long), footer("f")]);
  // The turn's end swaps the line for the footer and moves nothing above it.
  expect(lineHeight).toBe(footerHeight);
  expect(running).toBe(ended);
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

test("the chat's last footer is placed again when a prompt follows it", () => {
  const rows = [reply("a", "Done."), footer("f")];
  const first = layoutConversation(rows as never, 720);
  expect(first.heights[1]).toBe(32);
  const second = layoutConversation([...rows, prompt("p")] as never, 720, undefined, undefined, undefined, {
    rows,
    layout: first,
  });
  expect(second.heights[1]).toBe(48);
});

test("a task's result is its 26px line and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "r", version: 1, at: 0, kind: "user", text: "Run the tests", received: { offerId: "o", title: "Tests" } },
  ]);
  expect(height).toBe(34);
});

test("a footer shaped by turnView, which carries its answer's text, is its 24px line and gap", () => {
  const answer = "A longer answer that wraps. ".repeat(40);
  const source = [
    { id: "u1", version: 1, at: 1_000, kind: "user", text: "First" },
    { id: "a1", version: 1, at: 2_000, kind: "assistant", text: answer },
    { id: "s1", version: 1, at: 3_000, kind: "turnSummary", status: "completed", durationMs: 2_000 },
    { id: "u2", version: 1, at: 4_000, kind: "user", text: "Second" },
    { id: "a2", version: 1, at: 5_000, kind: "assistant", text: answer },
    { id: "s2", version: 1, at: 6_000, kind: "turnSummary", status: "completed", durationMs: 2_000 },
  ];
  const rows = turnView(source as never, new Set(), { now: 7_000 });
  const footers = rows.flatMap((row, index) => (row.kind === "turnSummary" ? [index] : []));
  expect(footers.length).toBe(2);
  expect(rows[footers[0]!]!.text).toBe(answer);
  const { heights } = layoutConversation(rows, 720);
  expect(heights[footers[0]!]).toBe(48);
  expect(heights[footers[1]!]).toBe(32);
});

test("a hidden row after the chat's last footer leaves it the last one", () => {
  const hidden = { id: "h", version: 1, at: 0, kind: "user", text: "", incoming: { kind: "hidden" } };
  const heights = heightsOf([reply("a", "Done."), footer("f"), hidden]);
  expect(heights[1]).toBe(32);
  expect(heights[2]).toBe(0);
});

test("another agent's message is its 26px line in 2px margins and the 8px message gap", () => {
  const message = { from: "cmux16/glass-lens", text: "Draft is up." };
  const [height] = heightsOf([
    { id: "m", version: 1, at: 0, kind: "user", text: "Draft is up.", incoming: { kind: "message", message } },
  ]);
  expect(height).toBe(2 + 26 + 2 + 8);
});

test("a task notice is a tool row's line, 2px under the row's top, and the 8px message gap", () => {
  const [height] = heightsOf([
    { id: "n", version: 1, at: 0, kind: "user", text: "Task done", incoming: { kind: "notice", text: "Task done" } },
  ]);
  expect(height).toBe(2 + 26 + 8);
});

test("a steer the agent has not read adds its Send now line under the steer's status", () => {
  const steer = (state: string) => ({ id: "s", version: 1, at: 0, kind: "user", text: "Also this", steer: state });
  const [landed] = heightsOf([steer("landed")]);
  const [waiting] = heightsOf([steer("waiting")]);
  // `.cv-user__pending`: 4px above a 16px line.
  expect(waiting! - landed!).toBe(20);
});

// A long prompt opens collapsed (conversation/UserBubble.tsx, promptCollapse.ts): its first ten
// lines over the 24px Show more line, inside the bubble's 16px of padding, with its 28px hover row
// under it and the 8px message gap. Estimated any taller, the row shrinks once drawn and the
// rows below jump up.
// Before: a prompt was estimated at its whole text, 2,000 lines tall.
test("a 2,000-line prompt is estimated at its collapsed height, at most ten lines", () => {
  const { lineHeight } = currentChatMetrics();
  const text = Array.from({ length: 2000 }, (_, index) => `line ${index + 1}`).join("\n");
  const [long] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(long).toBeCloseTo(16 + COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT + 4 + 24 + 8, 5);
  expect(long!).toBeLessThan(16 + 10.5 * lineHeight + 24 + 28 + 8);
});

test("a prompt of ten lines or fewer is estimated whole, with no Show more line", () => {
  const { lineHeight } = currentChatMetrics();
  const text = Array.from({ length: 3 }, (_, index) => `line ${index + 1}`).join("\n\n");
  const [short] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text }]);
  expect(short!).toBeLessThan(16 + COLLAPSED_PROMPT_LINES * lineHeight + 28 + 8);
});

// A pasted block (`pasted` ranges, the chip in UserBubble.tsx) is one chip line, however long the
// paste, and the prompt's own words around it.
test("a prompt with a 2,300-line paste is its typed line and one chip", () => {
  const { lineHeight } = currentChatMetrics();
  const typed = "Why does this fail?";
  const paste = Array.from({ length: 2300 }, (_, index) => `frame ${index}`).join("\n");
  const text = `${typed}\n${paste}`;
  const pasted = [{ start: typed.length + 1, end: text.length }];
  const [height] = heightsOf([{ id: "u", version: 1, at: 0, kind: "user", text, pasted }]);
  expect(height).toBeCloseTo(16 + lineHeight + PASTE_CHIP_HEIGHT + 28 + 8, 5);
});
