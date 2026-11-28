// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-27, on two steers drawn a turn gap apart: "these cases are maybe taste calls, but
// potentially we can just stick the steered together." A person's own messages with nothing drawn
// between them stand the footer gap apart, one group; a prompt next to anything else keeps the turn gap.
import { expect, test } from "bun:test";
import { gridMark, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  MARK_MESSAGE,
  MARK_PROMPT,
  TRANSCRIPT_FOOTER_GAP,
  TRANSCRIPT_TURN_GAP,
  transcriptGap,
} from "../src/agent-session/acpmux/transcriptGrid";

let clock = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (clock += 1_000),
  ...extra,
});

test("adjacent own messages stick together, the footer gap apart", () => {
  const prompt = row("p", "user", { text: "fix the build" });
  const steer = row("s1", "user", { text: "also the tests", continuesTurn: true } as Partial<AcpmuxRow>);
  const again = row("s2", "user", { text: "and the docs", continuesTurn: true } as Partial<AcpmuxRow>);
  expect(transcriptGap(gridMark(prompt, undefined), gridMark(steer, prompt))).toBe(TRANSCRIPT_FOOTER_GAP);
  expect(transcriptGap(gridMark(steer, prompt), gridMark(again, steer))).toBe(TRANSCRIPT_FOOTER_GAP);
  expect(TRANSCRIPT_FOOTER_GAP).toBeLessThan(TRANSCRIPT_TURN_GAP);
});

test("a prompt next to a reply keeps the turn gap", () => {
  expect(transcriptGap(MARK_MESSAGE, MARK_PROMPT)).toBe(TRANSCRIPT_TURN_GAP);
  expect(transcriptGap(MARK_PROMPT, MARK_MESSAGE)).toBe(TRANSCRIPT_TURN_GAP);
});
