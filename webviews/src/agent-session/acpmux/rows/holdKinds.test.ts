// The hold's kinds against the translator's kind table (acpmux-book/src/translate/kinds.rs): each one
// is a `page(...)` line, none is a line that makes a row or is read by row code, and the table has
// no page-state kind the hold leaves out. The hold's params are the shape acpmux takes and no more.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { HOLD_KINDS, HOLD_MAX_KINDS, holdAttach, holdReads } from "./holdKinds";

const KINDS = readFileSync(
  `${import.meta.dir}/../../../../../cmux-tui/crates/acpmux-book/src/translate/kinds.rs`,
  "utf8",
);
/// Every kind a table line names with `constructor("name"`, by its constructor.
function lines(constructor: string): string[] {
  return [...KINDS.matchAll(new RegExp(`\\b${constructor}\\(\\s*"([^"]+)"`, "g"))].map((match) => match[1]!);
}

test("the hold's kinds are the table's page-state kinds, exact and within acpmux's bound", () => {
  expect([...HOLD_KINDS]).toEqual([...new Set(lines("page"))].sort());
  expect(HOLD_KINDS.length).toBeLessThanOrEqual(HOLD_MAX_KINDS);
  for (const drawn of ["notice", "code", "not", "row"]) {
    const named = new Set(lines(drawn));
    expect(HOLD_KINDS.filter((kind) => named.has(kind))).toEqual([]);
  }
  // `subsession` is page state only as its `limits` event.
  expect(KINDS).toContain('("subsession", "limits", Draw::PageState)');
  expect(holdReads({ kind: "subsession", msg: { event: "limits" } })).toBe(true);
  expect(holdReads({ kind: "subsession", msg: { event: "started" } })).toBe(false);
  expect(holdReads({ kind: "usage_update", msg: {} })).toBe(true);
});

test("a hold carries no log read, and the page builds none whose kinds fail the rule", () => {
  expect(holdAttach("chat-1", true)).toEqual({
    sessionId: "chat-1",
    hold: true,
    eventStream: true,
    kinds: [...HOLD_KINDS],
    visible: true,
    attending: true,
  });
  expect(holdAttach("chat-1", true, ["transcript"])).toBeUndefined();
  expect(holdAttach("chat-1", true, ["usage_update", "all"])).toBeUndefined();
  expect(holdAttach("chat-1", true, [""])).toBeUndefined();
  expect(
    holdAttach(
      "chat-1",
      true,
      Array.from({ length: HOLD_MAX_KINDS + 1 }, (_, n) => `k${n}`),
    ),
  ).toBeUndefined();
});
