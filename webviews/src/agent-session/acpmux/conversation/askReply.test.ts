// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// An answer to an agent's ask (NextStepCard.tsx, the composer hat) goes as a reply to that ask: the
// ask quoted with who asked, then the answer, the record Quote in Reply makes (`> ` lines and a
// blank line). Leo, 2026-11-08, on a bare "Not now" bubble: "wait this thing should've shown that
// it was a reply to an ask from you". The card still reads the answer under the quote, so it
// settles as before.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { answerOf, answerPrompt, askQuote, chosenAnswer, nextStepAsk, pickedAnswer } from "./nextStepAsk";
import { quoteMarkdown } from "./selectionReplyModel";
import { NEXT_STEP, turnView, turnViewFrom } from "./turns";
import { askKey, claimAnswer, resetAnswerClaims } from "./waitingAskStore";

const scope = globalThis as { localStorage?: Storage };
const kept = scope.localStorage;
beforeEach(() => {
  delete scope.localStorage;
  resetAnswerClaims();
});
afterEach(() => {
  if (kept) scope.localStorage = kept;
  resetAnswerClaims();
});

describe("the reply record", () => {
  test("quotes the ask under who asked, then the answer", () => {
    expect(answerPrompt("Should I open a PR for this?", "Not now", "Claude Code")).toBe(
      "> Claude Code: Should I open a PR for this?\n\nNot now",
    );
  });

  test("is Quote in Reply's own quote, so the bubble draws it as every quoted reply", () => {
    const question = "Which look should ship?";
    expect(answerPrompt(question, "Box", "Codex")).toBe(`${quoteMarkdown(askQuote(question, "Codex"))}Box`);
  });

  test("quotes the question alone when no one is named, and each line of a long ask", () => {
    expect(answerPrompt("Ship it?", "Yes")).toBe("> Ship it?\n\nYes");
    expect(answerPrompt("First line\nShip it?", "Yes", "Claude")).toBe("> Claude: First line\n> Ship it?\n\nYes");
  });

  test("a recap with no question sends the answer as it is", () => {
    expect(answerPrompt("", "Continue", "Claude")).toBe("Continue");
  });
});

describe("reading the answer under the quote", () => {
  test("drops this ask's quote, whoever it names", () => {
    expect(answerOf("Ship it?", "> Claude Code: Ship it?\n\nNot now")).toBe("Not now");
    expect(answerOf("Ship it?", "> Ship it?\n\nYes, and tag it\nafter")).toBe("Yes, and tag it\nafter");
  });

  test("keeps any other quote: a reply to something else is not this answer", () => {
    const other = "> The upload retries forever.\n\nYes";
    expect(answerOf("Ship it?", other)).toBe(other);
    expect(answerOf("Ship it?", "Yes")).toBe("Yes");
  });

  test("the card picks the answer under the quote, and a typed reply reads its own first line", () => {
    const ask = nextStepAsk("[outward] Should I open a PR for this?")!;
    expect(pickedAnswer(ask, answerPrompt(ask.question, "Not now", "Claude Code"))).toBe("Not now");
    expect(chosenAnswer(ask, answerPrompt(ask.question, "Only after CI\nis green", "Claude Code"))).toBe(
      "Only after CI",
    );
  });
});

describe("the card settles on a quoted answer", () => {
  let at = 0;
  const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
  const QUESTION = "Should I open a PR for this?";
  const asked = () => [
    line("p1", "user", { text: "Fix the grid" }),
    line("a1", "assistant", { text: `Fixed.\n\n[outward] ${QUESTION}` }),
    line("s1", "turnSummary", { status: "completed" }),
  ];

  test("a clicked Not now folds the card to Not now, not the quote", () => {
    const rows = [...asked(), line("p2", "user", { text: answerPrompt(QUESTION, "Not now", "Claude Code") })];
    const card = turnView(rows, new Set()).find((row) => row.kind === NEXT_STEP);
    expect(card?.nextStep?.answer).toBe("Not now");
  });

  test("a click's claim finds its quoted prompt, also after a reload", () => {
    const rows = asked();
    const card = turnViewFrom(rows, new Set()).rows.find((row) => row.kind === NEXT_STEP)!;
    claimAnswer(askKey(card), "Yes", at);
    const answered = [...rows, line("p2", "user", { text: answerPrompt(QUESTION, "Yes", "Claude Code") })];
    const shown = turnViewFrom(answered, new Set()).rows.find((row) => row.kind === NEXT_STEP);
    expect(shown?.nextStep?.answer).toBe("Yes");
  });

  test("a typed reply under the quote, superseded by a later card, reads the typed words", () => {
    const rows = [
      ...asked(),
      line("p2", "user", { text: answerPrompt(QUESTION, "Only after CI is green", "Claude Code") }),
      line("a2", "assistant", { text: "Waiting on CI.\n\n[outward] Should I merge once it is green?" }),
      line("s2", "turnSummary", { status: "completed" }),
    ];
    const [first] = turnView(rows, new Set()).filter((row) => row.kind === NEXT_STEP);
    expect(first?.nextStep).toMatchObject({ superseded: true, answer: "Only after CI is green" });
  });
});
