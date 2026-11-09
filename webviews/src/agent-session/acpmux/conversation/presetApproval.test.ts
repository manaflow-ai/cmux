// l10n-allow-file: test fixtures.
// A no-prompt preset's approval card state (presetApproval.ts), folded from acpmux's
// `preset_approval_request` and `preset_approval_decision` records by seq.
import { expect, test } from "bun:test";
import {
  PresetApprovalFold,
  presetApprovalAsk,
  presetApprovalDecision,
  presetApprovalFailed,
  presetApprovalSending,
  type PresetApprovalChange,
} from "./presetApproval";

const RECORD = {
  preset: "lane",
  digest: "d1",
  harness: "claude",
  model: "opus",
  policy: "approve-all",
  host: "build-linux-3",
};
const ask = (data: Record<string, unknown> = {}) => presetApprovalAsk({ ...RECORD, ...data })!;

test("a request record opens a card; one the card cannot answer is skipped", () => {
  expect(ask()).toEqual(RECORD);
  expect(presetApprovalAsk({ ...RECORD, effort: " ", description: "" })).toEqual(RECORD);
  for (const missing of ["preset", "digest", "harness", "policy"])
    expect(presetApprovalAsk({ ...RECORD, [missing]: undefined })).toBeUndefined();
  expect(presetApprovalDecision({ preset: "lane", digest: "d1", outcome: "maybe" })).toBeUndefined();
  const fold = new PresetApprovalFold();
  const opened = fold.request(4, 40, ask());
  expect(opened).toEqual({ removed: [], cards: [{ rowId: "preset-approval-4", ask: ask(), at: 40 }] });
  expect(fold.outcome("preset-approval-4")).toBeUndefined();
});

/// The key's cards as row, outcome pairs.
const shown = (change: PresetApprovalChange) => change.cards.map((card) => [card.rowId, card.outcome]);

test("a later decision for its preset and digest closes the card; a request after it opens a new one", () => {
  const fold = new PresetApprovalFold();
  fold.request(4, 40, ask());
  // The agent tried again before the person answered: the same card.
  expect(shown(fold.request(6, 60, ask()))).toEqual([["preset-approval-4", undefined]]);
  expect(shown(fold.decide(9, { preset: "lane", digest: "d1", outcome: "approved" }))).toEqual([
    ["preset-approval-4", "approved"],
  ]);
  expect(fold.outcome("preset-approval-4")).toBe("approved");
  // The same record read again changes nothing.
  expect(shown(fold.decide(9, { preset: "lane", digest: "d1", outcome: "approved" }))).toEqual([
    ["preset-approval-4", "approved"],
  ]);
  expect(shown(fold.request(12, 120, ask()))).toEqual([
    ["preset-approval-4", "approved"],
    ["preset-approval-12", undefined],
  ]);
});

test("a decision for another digest or preset leaves the card open", () => {
  const fold = new PresetApprovalFold();
  fold.request(4, 40, ask());
  expect(shown(fold.request(5, 50, ask({ digest: "d2" })))).toEqual([["preset-approval-5", undefined]]);
  expect(shown(fold.decide(7, { preset: "lane", digest: "d2", outcome: "declined" }))).toEqual([
    ["preset-approval-5", "declined"],
  ]);
  expect(fold.decide(8, { preset: "other", digest: "d1", outcome: "approved" }).cards).toEqual([]);
  expect(fold.outcome("preset-approval-4")).toBeUndefined();
  expect(fold.outcome("preset-approval-5")).toBe("declined");
});

test("records read out of order settle the card the same way", () => {
  const fold = new PresetApprovalFold();
  // A later page first: the decision at 9, then the request at 4 it answered.
  fold.decide(9, { preset: "lane", digest: "d1", outcome: "declined" });
  expect(shown(fold.request(4, 40, ask()))).toEqual([["preset-approval-4", "declined"]]);
  // A request after the decision is still open.
  expect(fold.outcome(fold.request(11, 110, ask()).cards[1].rowId)).toBeUndefined();
  fold.clear();
  expect(shown(fold.request(4, 40, ask()))).toEqual([["preset-approval-4", undefined]]);
});

test("request 12, then request 4, then a decline at 9: a declined card at 4 and an open card at 12", () => {
  const fold = new PresetApprovalFold();
  expect(shown(fold.request(12, 120, ask()))).toEqual([["preset-approval-12", undefined]]);
  // The older request joins the same card, which now starts at 4.
  const joined = fold.request(4, 40, ask());
  expect(joined.removed).toEqual(["preset-approval-12"]);
  expect(shown(joined)).toEqual([["preset-approval-4", undefined]]);
  // The decline read late falls between them: the card splits.
  const split = fold.decide(9, { preset: "lane", digest: "d1", outcome: "declined" });
  expect(split.removed).toEqual([]);
  expect(split.cards).toEqual([
    { rowId: "preset-approval-4", ask: ask(), at: 40, outcome: "declined" },
    { rowId: "preset-approval-12", ask: ask(), at: 120 },
  ]);
  expect(fold.outcome("preset-approval-4")).toBe("declined");
  expect(fold.outcome("preset-approval-12")).toBeUndefined();
});

test("a refused answer keeps the card open with acpmux's message; the next answer clears it", () => {
  const sending = presetApprovalSending({ ask: ask() }, "approved");
  expect(sending.busy).toBe("approved");
  const failed = presetApprovalFailed(sending, "preset lane changed");
  expect(failed).toEqual({ ask: ask(), error: "preset lane changed" });
  expect(presetApprovalSending(failed, "declined")).toEqual({ ask: ask(), busy: "declined" });
});
