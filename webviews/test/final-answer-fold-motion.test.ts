// l10n-allow-file: synthetic transcript rows for the final-answer transition.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { endsTurn } from "../src/agent-session/acpmux/conversation/turnEndFold";
import { ACTIVITY_LINE, LIVE_THINKING, WORKED, WORKING } from "../src/agent-session/acpmux/conversation/turns";

const row = (id: string, kind: AcpmuxRow["kind"]): AcpmuxRow => ({ id, kind, version: 1, at: 1000 });
const prompt = row("prompt", "user");
const header = row(`${WORKING}-prompt`, WORKING);
const worked = row(`${WORKED}-prompt`, WORKED);
const live = row(LIVE_THINKING, "thinking");

test("the final answer folds prior work while the live line remains", () => {
  expect(
    endsTurn([prompt, header, row("work", "activity"), live], [prompt, worked, row("answer", "assistant"), live]),
  ).toBe(true);
});

test("an ordinary status update does not play a turn fold", () => {
  expect(endsTurn([prompt, header, live], [prompt, header, row("status", ACTIVITY_LINE)])).toBe(false);
});

test("continued final-answer chunks do not restart the fold", () => {
  expect(
    endsTurn([prompt, worked, row("answer", "assistant"), live], [prompt, worked, row("answer", "assistant"), live]),
  ).toBe(false);
});

test("a different prompt replacing the chat does not fold the old transcript", () => {
  expect(endsTurn([prompt, header, live], [row("other", "user"), worked, row("answer", "assistant"), live])).toBe(
    false,
  );
});
