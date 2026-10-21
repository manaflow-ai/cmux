import { expect, test } from "bun:test";
import { findMatches } from "../src/agent-session/acpmux/conversation/chatFind";
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
