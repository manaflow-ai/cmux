import { expect, test } from "bun:test";
import { findMatches, findMatchesIncremental } from "../src/agent-session/acpmux/conversation/chatFind";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, text: string): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "assistant",
  text,
});

test("find matches refresh when an immutable row snapshot is replaced", () => {
  const first = row("turn-1", "The first answer");
  expect(findMatches([first], "first")).toEqual([{ rowIndex: 0, rowId: "turn-1", occurrence: 0 }]);

  const replacement = row("turn-1", "The revised answer");
  expect(findMatches([replacement], "first")).toEqual([]);
  expect(findMatches([replacement], "revised")).toEqual([{ rowIndex: 0, rowId: "turn-1", occurrence: 0 }]);
});

test("incremental find rescans only a changed tail", () => {
  const first = row("turn-1", "first answer");
  const second = row("turn-2", "second answer");
  const initial = findMatchesIncremental([first, second], "answer");
  expect(initial.scannedRows).toBe(2);

  const third = row("turn-3", "third answer");
  const next = findMatchesIncremental([first, second, third], "answer", initial.cache);
  expect(next.scannedRows).toBe(1);
  expect(next.matches).toEqual([
    { rowIndex: 0, rowId: "turn-1", occurrence: 0 },
    { rowIndex: 1, rowId: "turn-2", occurrence: 0 },
    { rowIndex: 2, rowId: "turn-3", occurrence: 0 },
  ]);
});

test("incremental find invalidates the prefix when history is prepended or edited", () => {
  const first = row("turn-1", "first answer");
  const second = row("turn-2", "second answer");
  const initial = findMatchesIncremental([first, second], "answer");

  const prepended = row("turn-0", "old answer");
  const afterPrepend = findMatchesIncremental([prepended, first, second], "answer", initial.cache);
  expect(afterPrepend.scannedRows).toBe(3);
  expect(afterPrepend.matches.map(({ rowIndex, rowId }) => ({ rowIndex, rowId }))).toEqual([
    { rowIndex: 0, rowId: "turn-0" },
    { rowIndex: 1, rowId: "turn-1" },
    { rowIndex: 2, rowId: "turn-2" },
  ]);

  const replacement = row("turn-2", "revised");
  const afterEdit = findMatchesIncremental([prepended, first, replacement], "answer", afterPrepend.cache);
  expect(afterEdit.scannedRows).toBe(1);
  expect(afterEdit.matches).toEqual([
    { rowIndex: 0, rowId: "turn-0", occurrence: 0 },
    { rowIndex: 1, rowId: "turn-1", occurrence: 0 },
  ]);
});
