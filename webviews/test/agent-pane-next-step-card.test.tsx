// l10n-allow-file: test fixture prompts and agent answers, not shipped UI.
// A coordinator's tagged ask at the end of a turn (conversation/nextStepAsk.ts) draws as a card
// under the answer with its answers as buttons (NextStepCard.tsx); once a prompt follows, the card
// folds to the question and the answer. Leo, 2026-11-03: "for multiple choice things like that we
// can just render something pretty and usable", and "it might be more tiresome than otherwise", so
// an ordinary turn never gets one.
import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { assistant, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { NEXT_STEP, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { NextStepCard } from "../src/agent-session/acpmux/conversation/NextStepCard";
import { nextStepAsk } from "../src/agent-session/acpmux/conversation/nextStepAsk";
import { recapFrom } from "../src/agent-session/acpmux/recap";

const ANSWER =
  "The lane ran about 40 slow commands in the foreground.\n\n[outward] Add a hook that pushes them to the background?\n- Yes, add the hook\n- Not now\n- Fix CI first";

const turn = (answer: string, status = "completed"): AcpmuxRow[] => [
  user("Why did the lane stall?", 6),
  assistant(answer, 5),
  summary(5, { status }),
];

const nextSteps = (rows: readonly AcpmuxRow[]) => rows.filter((row) => row.kind === NEXT_STEP);
const answerText = (rows: readonly AcpmuxRow[]) => rows.find((row) => row.kind === "assistant")?.text;

describe("a tagged ask in the transcript", () => {
  test("the last finished turn draws it as a waiting card, and the prose drops the ask's lines", () => {
    const drawn = turnView(turn(ANSWER), new Set());
    const [card] = nextSteps(drawn);
    expect(card?.nextStep?.ask.question).toBe("Add a hook that pushes them to the background?");
    expect(card?.nextStep?.ask.options.map((option) => option.label)).toEqual([
      "Yes, add the hook",
      "Not now",
      "Fix CI first",
    ]);
    expect(card?.nextStep?.answer).toBeUndefined();
    expect(answerText(drawn)).toBe("The lane ran about 40 slow commands in the foreground.");
    // Right under the answer, before the footer.
    const kinds = drawn.map((row) => row.kind);
    expect(kinds.indexOf(NEXT_STEP)).toBe(kinds.indexOf("assistant") + 1);
    expect(kinds.indexOf("turnSummary")).toBeGreaterThan(kinds.indexOf(NEXT_STEP));
    // The footer's Copy keeps the whole answer.
    expect(drawn.find((row) => row.kind === "turnSummary")?.text).toBe(ANSWER);
  });

  test("a prompt after it folds the card to the question and the chosen answer", () => {
    const drawn = turnView([...turn(ANSWER), user("Not now", 1)], new Set());
    expect(nextSteps(drawn)[0]?.nextStep?.answer).toBe("Not now");
  });

  test("a prompt still on its way answers it too", () => {
    const drawn = turnView([...turn(ANSWER), user("fix ci first", 1, { pending: true })], new Set());
    expect(nextSteps(drawn)[0]?.nextStep?.answer).toBe("Fix CI first");
  });

  test("ordinary answers, a running turn and a stopped turn draw no card and keep their prose", () => {
    for (const rows of [
      turn("All 14 tests pass. Should I open a PR?"),
      turn(ANSWER, "cancelled"),
      [user("Why did the lane stall?", 6), assistant(ANSWER, 5, { streaming: true })],
    ]) {
      const drawn = turnView(rows, new Set(), { working: rows.length === 2 });
      expect(nextSteps(drawn)).toHaveLength(0);
    }
    expect(answerText(turnView(turn(ANSWER, "cancelled"), new Set()))).toBe(ANSWER);
  });

  test("another agent's notice after the turn leaves the ask in the prose", () => {
    const drawn = turnView(
      [...turn(ANSWER), user("Report from the timer helper", 1, { incoming: { kind: "notice", text: "Timer fixed" } })],
      new Set(),
    );
    expect(nextSteps(drawn)).toHaveLength(0);
  });

  test("the recap card steps aside for a tagged ask", () => {
    expect(recapFrom(turn("[outward] Should I post the release notes?"))).toBeNull();
    expect(recapFrom(turn("Done. Should I open a PR?"))?.question).toBe("Should I open a PR?");
  });
});

describe("NextStepCard", () => {
  const ask = nextStepAsk(ANSWER)!;
  test("waiting: the question and one button per answer, the first with ⌘↩", () => {
    const html = renderToStaticMarkup(
      createElement(NextStepCard, { ask, onAnswer: async () => undefined, registerKey: () => () => undefined }),
    );
    expect(html).toContain("Add a hook that pushes them to the background?");
    expect(html.match(/acpmux-next-step__answer\b(?!s)/g)).toHaveLength(3);
    expect(html).toContain('aria-keyshortcuts="Meta+Enter"');
    expect(html).toContain("⌘↩");
  });

  test("a pane that cannot send draws no buttons", () => {
    const html = renderToStaticMarkup(createElement(NextStepCard, { ask }));
    expect(html).not.toContain("acpmux-next-step__answer");
  });

  test("answered: the question and the answer, no buttons", () => {
    const html = renderToStaticMarkup(createElement(NextStepCard, { ask, answer: "Not now" }));
    expect(html).toContain("acpmux-question-answered-answer");
    expect(html).toContain("Not now");
    expect(html).not.toContain("<button");
  });
});
