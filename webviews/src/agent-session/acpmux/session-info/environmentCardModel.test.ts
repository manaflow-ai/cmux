import { expect, test } from "bun:test";
import { cardBranchOf, environmentCardFits } from "./environmentCardModel";

test("a git.status reply's branch; a folder in no repository has none", () => {
  expect(cardBranchOf({ root: "/r", branch: "main", ahead: 0, behind: 0 })).toEqual({
    branch: "main",
    worktree: false,
    detached: false,
  });
  expect(cardBranchOf({ root: "/r/wt", branch: "codex/x", worktree: { main_root: "/r" }, base: "main" })).toEqual({
    branch: "codex/x",
    worktree: true,
    detached: false,
  });
  expect(cardBranchOf({ root: "/r", detached: true })).toEqual({ branch: undefined, worktree: false, detached: true });
  expect(cardBranchOf({ branch: "main" })).toBeUndefined();
  expect(cardBranchOf(undefined)).toBeUndefined();
});

test("the card shows only where the gutter beside the column holds it", () => {
  // 820 column: each gutter is (1400 - 820) / 2 = 290, room for 220 and two 12px gaps.
  expect(environmentCardFits(1400, 820, false)).toBe(true);
  // (1200 - 820) / 2 = 190: the card would cover the transcript.
  expect(environmentCardFits(1200, 820, false)).toBe(false);
  expect(environmentCardFits(2400, 820, true)).toBe(false);
  expect(environmentCardFits(600, 820, false)).toBe(false);
});
