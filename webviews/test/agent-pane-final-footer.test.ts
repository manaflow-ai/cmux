// l10n-allow-file: test fixture rows, not shipped UI.
// Leo, 2026-11-04, comparing ChatGPT's last reply with ours: "we don't have the time worked for nor
// the thing always showing at hte bottom (excl. thumb up/down)". The last ended turn's footer shows
// at rest (App.tsx `acpmux-row--final-footer`) until the person's next prompt, also when another
// agent's message, a notice or a background line is drawn under it.
import { expect, test } from "bun:test";
import { type AcpmuxRow, finalFooterId } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, version: 1, at: 0, kind, ...extra }) as AcpmuxRow;
const turn = [
  row("p1", "user", { text: "hi" }),
  row("a1", "assistant", { text: "hello" }),
  row("s1", "turnSummary", { text: "hello" }),
];

test("the chat's last footer is the final one", () => {
  expect(finalFooterId(turn)).toBe("s1");
});

test("another agent's message under the last footer leaves it shown", () => {
  const message = row("m1", "user", { text: "lane -> coord: done", incoming: { kind: "message" } as never });
  expect(finalFooterId([...turn, message])).toBe("s1");
});

test("a notice or background line under it leaves it shown", () => {
  expect(finalFooterId([...turn, row("n1", "notice"), row("b1", "backgroundTurn")])).toBe("s1");
});

test("a later turn's footer takes over", () => {
  expect(finalFooterId([...turn, row("p2", "user", { text: "more" }), row("s2", "turnSummary", { text: "ok" })])).toBe(
    "s2",
  );
});

test("the person's next prompt hides it while that turn runs", () => {
  expect(finalFooterId([...turn, row("p2", "user", { text: "more" }), row("t", "thinking")])).toBeUndefined();
});

test("a turn another agent's message started takes it away while it runs", () => {
  const message = row("m1", "user", { text: "lane -> coord: done", incoming: { kind: "message" } as never });
  expect(finalFooterId([...turn, message, row("a2", "assistant", { text: "on it" })])).toBeUndefined();
  expect(
    finalFooterId([...turn, message, row("a2", "assistant", { text: "ok" }), row("s2", "turnSummary", { text: "ok" })]),
  ).toBe("s2");
});

test("an empty footer after it (a bookkeeping turn) leaves the answer's footer shown", () => {
  const bookkeeping = row("h1", "user", { text: "", incoming: { kind: "hidden" } as never });
  expect(finalFooterId([...turn, bookkeeping, row("s3", "turnSummary")])).toBe("s1");
});

test("a chat with no ended turn has none", () => {
  expect(finalFooterId([row("p1", "user", { text: "hi" })])).toBeUndefined();
});
