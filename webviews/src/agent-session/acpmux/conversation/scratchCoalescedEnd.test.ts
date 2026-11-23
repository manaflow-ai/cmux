// SCRATCH (not committed): does endsTurn see a turn end drawn in the same render as the next prompt?
// Shapes from hidden-reshow TURN_TRACE (bench-fix.full, kept cpu=1 at 15089 ms; adopted cpu=4 at 9740 ms).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { endsTurn } from "./turnEndFold";
import { LIVE_THINKING } from "./turns";

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({ id, version: 1, at: 1, kind });

const before = [
  row("user-5865", "user"),
  row("working-user-5865", "working"),
  row("activity-5868", "activity"),
  row("assistant-5874"),
  row("activity-5877", "activity"),
  row("assistant-5881"),
  row(LIVE_THINKING, "thinking"),
];
const ended = [row("user-5865", "user"), row("worked-user-5865", "worked"), row("assistant-5881"), row("summary-turn-247", "turnSummary")];

test("SCRATCH: end alone folds", () => {
  console.log("alone", endsTurn(before, ended));
});
test("SCRATCH: end + next prompt (no line yet)", () => {
  console.log("next-prompt", endsTurn(before, [...ended, row("user-5886", "user")]));
});
test("SCRATCH: end + next prompt + its live line", () => {
  console.log("next-prompt+line", endsTurn(before, [...ended, row("user-5886", "user"), row(LIVE_THINKING, "thinking")]));
  console.log(
    "next-prompt+working+line",
    endsTurn(before, [...ended, row("user-5886", "user"), row("working-user-5886", "working"), row(LIVE_THINKING, "thinking")]),
  );
  const line = { ...row("user-5886", "user"), incoming: { kind: "message" } } as AcpmuxRow;
  console.log(
    "next-line+working+line",
    endsTurn(before, [...ended, row("working-user-5886", "working"), line, row("activity-5889", "activity"), row(LIVE_THINKING, "thinking")]),
  );
  expect(true).toBe(true);
});
