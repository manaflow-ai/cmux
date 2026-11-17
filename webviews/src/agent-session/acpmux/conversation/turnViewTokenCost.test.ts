import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnViewFrom } from "./turns";

// CMUX-571 god-chat-ratios: a streamed token into the last reply of a long chat must not copy a
// set of every reply id the chat holds. Each token copied all of them (`visibleReplyIds`), so a god
// chat's token cost grew with its length (transcript-replay's token and thought slope per 1,000 rows).

const TURNS = 20_000;

const rowsOf = (turns: number, lastText: string): AcpmuxRow[] => {
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < turns; turn += 1) {
    rows.push({ id: `user-${turn}`, version: 1, at: turn * 2, kind: "user" as const, text: "prompt" });
    rows.push({
      id: `reply-${turn}`,
      version: 1,
      at: turn * 2 + 1,
      kind: "assistant" as const,
      text: turn === turns - 1 ? lastText : "answer",
    });
  }
  return rows;
};

const RealSet = globalThis.Set;
afterEach(() => {
  globalThis.Set = RealSet;
});

/// Elements copied into new sets while `run` runs.
function setCopies(run: () => void): number {
  let copied = 0;
  class CountingSet<T> extends RealSet<T> {
    constructor(items?: Iterable<T> | null) {
      super(items);
      copied += this.size;
    }
  }
  globalThis.Set = CountingSet as SetConstructor;
  try {
    run();
  } finally {
    globalThis.Set = RealSet;
  }
  return copied;
}

test("a streamed token into a long chat's last reply copies no set of every reply", () => {
  const expanded = new Set<string>();
  const before = rowsOf(TURNS, "Answer final: one");
  const previous = turnViewFrom(before, expanded, { working: true, now: 0 });
  // The token: only the last reply changed; every earlier row is the same object.
  const after = before.slice();
  const last = after[after.length - 1]!;
  after[after.length - 1] = { ...last, version: 2, text: "Answer final: one two" };
  let view: ReturnType<typeof turnViewFrom> | undefined;
  const copied = setCopies(() => {
    view = turnViewFrom(after, expanded, { working: true, now: 0 }, previous);
  });
  expect(view).not.toBe(previous);
  // A handful of the changed turn's rows, never the chat's 20,000 replies.
  expect(copied).toBeLessThan(100);
});
