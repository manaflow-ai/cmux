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
  const opened = fold.request(4, ask());
  expect(opened.outcome).toBeUndefined();
  expect(fold.outcome(opened.rowId)).toBeUndefined();
});

test("a later decision for its preset and digest closes the card; a request after it opens a new one", () => {
  const fold = new PresetApprovalFold();
  const { rowId } = fold.request(4, ask());
  // The agent tried again before the person answered: the same card.
  expect(fold.request(6, ask()).rowId).toBe(rowId);
  expect(fold.decide(9, { preset: "lane", digest: "d1", outcome: "approved" })).toEqual([
    { rowId, outcome: "approved" },
  ]);
  expect(fold.outcome(rowId)).toBe("approved");
  // The same record read again closes nothing more.
  expect(fold.decide(9, { preset: "lane", digest: "d1", outcome: "approved" })).toEqual([]);
  const again = fold.request(12, ask());
  expect(again.rowId).not.toBe(rowId);
  expect(again.outcome).toBeUndefined();
});

test("a decision for another digest or preset leaves the card open", () => {
  const fold = new PresetApprovalFold();
  const { rowId } = fold.request(4, ask());
  const changed = fold.request(5, ask({ digest: "d2" }));
  expect(changed.rowId).not.toBe(rowId);
  expect(fold.decide(7, { preset: "lane", digest: "d2", outcome: "declined" })).toEqual([
    { rowId: changed.rowId, outcome: "declined" },
  ]);
  expect(fold.decide(8, { preset: "other", digest: "d1", outcome: "approved" })).toEqual([]);
  expect(fold.outcome(rowId)).toBeUndefined();
  expect(fold.outcome(changed.rowId)).toBe("declined");
});

test("records read out of order settle the card the same way", () => {
  const fold = new PresetApprovalFold();
  // A later page first: the decision at 9, then the request at 4 it answered.
  fold.decide(9, { preset: "lane", digest: "d1", outcome: "declined" });
  expect(fold.request(4, ask()).outcome).toBe("declined");
  // A request after the decision is still open.
  expect(fold.request(11, ask()).outcome).toBeUndefined();
  fold.clear();
  expect(fold.request(4, ask()).outcome).toBeUndefined();
});

test("a refused answer keeps the card open with acpmux's message; the next answer clears it", () => {
  const sending = presetApprovalSending({ ask: ask() }, "approved");
  expect(sending.busy).toBe("approved");
  const failed = presetApprovalFailed(sending, "preset lane changed");
  expect(failed).toEqual({ ask: ask(), error: "preset lane changed" });
  expect(presetApprovalSending(failed, "declined")).toEqual({ ask: ask(), busy: "declined" });
});
