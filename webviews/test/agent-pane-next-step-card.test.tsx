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

  // Leo, 2026-11-06: another agent's message answers nothing; the question stays the person's.
  test("another agent's notice after the turn keeps the card waiting", () => {
    const drawn = turnView(
      [...turn(ANSWER), user("Report from the timer helper", 1, { incoming: { kind: "notice", text: "Timer fixed" } })],
      new Set(),
    );
    expect(nextSteps(drawn)[0]?.nextStep?.ask.question).toBe("Add a hook that pushes them to the background?");
    expect(nextSteps(drawn)[0]?.nextStep?.answer).toBeUndefined();
  });
});

describe("NextStepCard", () => {
  const ask = nextStepAsk(ANSWER)!;
  test("waiting: the question and one numbered row per answer, the first with ⌘↩", () => {
    const html = renderToStaticMarkup(
      createElement(NextStepCard, { ask, onAnswer: async () => undefined, registerKey: () => () => undefined }),
    );
    expect(html).toContain("Add a hook that pushes them to the background?");
    expect(html.match(/acpmux-next-step__answer\b(?!s)/g)).toHaveLength(3);
    // The first row takes its number key and ⌘↩; the arrow, not a keycap, marks it (questionCard.css).
    expect(html).toContain('aria-keyshortcuts="1 Meta+Enter"');
    expect(html).toContain('aria-keyshortcuts="2"');
    expect(html).toContain("acpmux-question-number");
  });

  // Lucas, 2026-11-24: where the pane cannot send, the same card, read only, so it reads the same and
  // stays as tall as its estimate. The answers are a numbered list; the last row says why.
  test("a pane that cannot send draws the same card read only, with no control", () => {
    const html = renderToStaticMarkup(createElement(NextStepCard, { ask, blocked: "watching" }));
    expect(html).toContain("Needs your input");
    expect(html).toContain("Add a hook that pushes them to the background?");
    expect(html.match(/<li class="acpmux-next-step__answer"/g)).toHaveLength(3);
    expect(html).toContain('<ul class="acpmux-next-step__answers" data-read-only="" role="list"');
    for (const label of ["Yes, add the hook", "Not now", "Fix CI first"]) expect(html).toContain(label);
    // Nothing to press or type, and nothing that claims a key.
    expect(html).not.toContain("<button");
    expect(html).not.toContain("<input");
    expect(html).not.toContain("aria-keyshortcuts");
    expect(html).not.toContain("is-primary");
    expect(html).toContain("Take over to answer");
  });

  test("the last row names why, for every pane that cannot send", () => {
    const reasons = {
      watching: "Take over to answer",
      bridged: "Reply below to answer",
      subagent: "Answer in the main chat",
      disconnected: "Not connected",
      remote: "Not available from here",
      origin: "Update cmux to answer here",
      guest: "Only the owner can answer",
    } as const;
    for (const [blocked, text] of Object.entries(reasons)) {
      const html = renderToStaticMarkup(createElement(NextStepCard, { ask, blocked: blocked as keyof typeof reasons }));
      expect(html).toContain(`<span class="acpmux-next-step__reason" title="${text}">${text}</span>`);
      expect(html.match(/acpmux-next-step__reason/g)).toHaveLength(1);
    }
    // A host that does not say why reads as not connected.
    expect(renderToStaticMarkup(createElement(NextStepCard, { ask }))).toContain("Not connected");
  });

  test("a pane that can send has no reason row; a question with no answers has no last row in any pane", () => {
    const sending = renderToStaticMarkup(createElement(NextStepCard, { ask, onAnswer: async () => undefined }));
    expect(sending).not.toContain("acpmux-next-step__reason");
    const bare = { ...ask, options: [] };
    for (const props of [
      { ask: bare, onAnswer: async () => undefined },
      { ask: bare, blocked: "watching" as const },
    ]) {
      const html = renderToStaticMarkup(createElement(NextStepCard, props));
      expect(html).not.toContain("acpmux-question-footer");
      expect(html).toContain("Needs your input");
    }
  });

  test("answered: the question and the answer, no buttons", () => {
    const html = renderToStaticMarkup(createElement(NextStepCard, { ask, answer: "Not now" }));
    expect(html).toContain("acpmux-question-answered-answer");
    expect(html).toContain("Not now");
    expect(html).not.toContain("<button");
  });
});
