// l10n-allow-file: test fixtures, not shipped UI.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { NEXT_STEP, turnViewFrom, waitingAsks } from "../conversation/turns";
import { askKey } from "../conversation/waitingAskStore";
import type { AcpmuxPermission, AcpmuxRow } from "../model";
import type { WatchedAsk } from "../needsYou/model";
import type { AcpmuxSessionEntry } from "../sessionList";
import {
  hatQuestions,
  hatShows,
  hatTag,
  keepShown,
  messagesNextStep,
  oneClickAnswers,
  sameHatQuestions,
} from "./hatModel";
import { questionFromPermission, type AgentQuestion } from "./model";

const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const fixture = (name: string): AgentQuestion =>
  questionFromPermission(JSON.parse(fs.readFileSync(`${FIXTURES}${name}.request.json`, "utf8")))!;

const permission = (question: AgentQuestion, id = question.source.permission ?? "perm-1"): AcpmuxPermission =>
  ({ permissionId: id, pending: true, options: [], question }) as unknown as AcpmuxPermission;

let seq = 0;
const row = (kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id: `row-${++seq}`, version: 1, at: seq, kind, ...extra }) as AcpmuxRow;
const tagged = (extra: { answer?: string; superseded?: boolean } = {}) =>
  row(NEXT_STEP, {
    nextStep: {
      ask: {
        tag: "physical",
        question: "Can you create that key and run the command?",
        options: [
          { label: "Yes", key: "recap.yes" },
          { label: "Not now", key: "recap.notNow" },
        ],
        rest: "",
      },
      ...extra,
    },
  });
const said = (text: string) => row("user", { text });
/// A turn view whose last word is `card` (turns.ts `lastWordAsk`), for the hat's own rules.
const lastWord = (card: AcpmuxRow, extra: { later?: boolean; spoke?: boolean } = {}) => ({
  turns: { nextSteps: [{ at: 0, row: card, turn: 0, ...extra }], rows: [card] },
});

describe("the questions the composer hat holds", () => {
  test("one click answers a single choice of up to four, and nothing that needs more", () => {
    expect(oneClickAnswers(fixture("pending-single")).length).toBeGreaterThan(1);
    expect(oneClickAnswers(fixture("pending-multi"))).toEqual([]);
    expect(oneClickAnswers(fixture("pending-4-questions"))).toEqual([]);
    expect(oneClickAnswers(fixture("pending-with-preview"))).toEqual([]);
    // A single choice with one option is still one click.
    const single = fixture("pending-single");
    const one = { ...single, items: [{ ...single.items[0]!, options: single.items[0]!.options.slice(0, 1) }] };
    expect(oneClickAnswers(one)).toHaveLength(1);
  });

  test("the chat's own question comes first; the card answers the one it shows, the hat points to it", () => {
    const asked = fixture("pending-single");
    const [own, ...rest] = hatQuestions({
      sessionId: "chat",
      permission: permission(asked),
      rows: [],
      sessions: [],
      asks: [],
    });
    expect(rest).toEqual([]);
    expect(own).toMatchObject({ source: "own", prompt: asked.items[0]!.prompt, onCard: true, answers: [] });
    // That one alone: the card asks it, so the band stays away rather than ask it twice.
    expect(hatShows([own!])).toBe(false);
    expect(hatTag("Physical")).toBe("physical");
    expect(hatTag("[check in]")).toBe("check-in");
    expect(hatTag("Auth method")).toBeUndefined();
  });

  // Leo, 2026-11-07: "what happens if they respond to it in another way, right? ... the question fade
  // from relevance is a thing that needs to be accounted for".
  test("a tagged ask leaves the hat once any prompt follows it, or a later card settles it", () => {
    const ask = tagged();
    const hat = (turns: ReturnType<typeof lastWord>) =>
      hatQuestions({ sessionId: "chat", nextStepOwner: "chat", ...turns, sessions: [], asks: [] });
    const [shown] = hat(lastWord(ask));
    expect(shown).toMatchObject({ source: "nextStep", sessionId: "chat", tag: "physical", typed: true });
    expect(shown!.answers.map((answer) => answer.key)).toEqual(["recap.yes", "recap.notNow"]);
    // The person said something after it; any prompt came after it (pinned then, #38964 below);
    // answered or superseded.
    expect(hat(lastWord(ask, { spoke: true }))).toEqual([]);
    expect(hat(lastWord(ask, { later: true }))).toEqual([]);
    expect(hat(lastWord(tagged({ answer: "Yes" })))).toEqual([]);
    expect(hat(lastWord(tagged({ superseded: true })))).toEqual([]);
    // Where the composer could not send it (View Only, a read-only pane), the hat offers no answer.
    expect(hatQuestions({ sessionId: "chat", ...lastWord(ask), sessions: [], asks: [] })).toEqual([]);
  });

  test("in Messages, the tagged ask is read from the completed turn's reply itself", () => {
    const reply = row("assistant", {
      text: "Made the config.\n\n[physical] Can you create that key and run the command?",
    });
    const done = row("turnSummary", { status: "completed" });
    expect(messagesNextStep([said("go"), reply, done])?.nextStep?.ask.question).toBe(
      "Can you create that key and run the command?",
    );
    // Still running, stopped, or with any prompt after it: none.
    expect(messagesNextStep([said("go"), reply])).toBeUndefined();
    expect(messagesNextStep([said("go"), reply, row("turnSummary", { status: "cancelled" })])).toBeUndefined();
    expect(messagesNextStep([reply, done, said("not yet")])).toBeUndefined();
    const [shown] = hatQuestions({
      sessionId: "chat",
      nextStepOwner: "chat",
      messages: true,
      rows: [said("go"), reply, done],
      sessions: [],
      asks: [],
    });
    expect(shown).toMatchObject({ source: "nextStep", tag: "physical" });
  });

  test("every question acpmux holds for the chat is in the hat, the card's first, each once", () => {
    const asked = fixture("pending-single");
    const ask = (id: string, sessionId = "chat"): WatchedAsk => ({
      sessionId,
      permission: permission(asked, id),
      at: 1,
    });
    const list = hatQuestions({
      sessionId: "chat",
      permission: permission(asked, "perm-2"),
      rows: [],
      sessions: [],
      asks: [ask("perm-1"), ask("perm-2"), ask("perm-3"), ask("perm-x", "other")],
    });
    expect(list.map((question) => question.id)).toEqual(["perm-2", "perm-1", "perm-3"]);
    // The others answer in one click; with them to step to, the band shows.
    expect(list.map((question) => question.answers.length > 0)).toEqual([false, true, true]);
    expect(hatShows(list)).toBe(true);
  });

  test("the asks queued behind the card come next, each once, before any the watch reports", () => {
    const asked = fixture("pending-single");
    const list = hatQuestions({
      sessionId: "chat",
      permission: permission(asked, "perm-1"),
      queued: [permission(asked, "perm-2"), permission(asked, "perm-3")],
      rows: [],
      sessions: [],
      asks: [{ sessionId: "chat", permission: permission(asked, "perm-3"), at: 1 }],
    });
    expect(list.map((question) => question.id)).toEqual(["perm-1", "perm-2", "perm-3"]);
    // One that needs more than a click waits for the card: the hat could not point to it.
    const several = hatQuestions({
      sessionId: "chat",
      permission: permission(asked, "perm-1"),
      queued: [permission(fixture("pending-multi"), "perm-multi")],
      rows: [],
      sessions: [],
      asks: [],
    });
    expect(several.map((question) => question.id)).toEqual(["perm-1"]);
  });

  test("while the chat's own question waits, no tagged ask shows: a turn is running", () => {
    const list = hatQuestions({
      sessionId: "chat",
      permission: permission(fixture("pending-single")),
      nextStepOwner: "chat",
      ...lastWord(tagged()),
      sessions: [],
      asks: [],
    });
    expect(list.map((question) => question.source)).toEqual(["own"]);
  });

  test("a started chat's question opens that chat; another chat's never shows", () => {
    const sessions = [
      { sessionId: "chat", title: "Coordinator" },
      { sessionId: "child", title: "Key setup", startedBy: "chat", pendingPermissions: 1 },
      { sessionId: "stranger", title: "Elsewhere", pendingPermissions: 1 },
    ] as unknown as AcpmuxSessionEntry[];
    const asked = (sessionId: string, id: string): WatchedAsk => ({
      sessionId,
      permission: permission({ ...fixture("pending-single"), source: { harness: "claude", session: sessionId } }, id),
      at: 1,
    });
    const list = hatQuestions({
      sessionId: "chat",
      rows: [],
      sessions,
      asks: [asked("child", "perm-child"), asked("stranger", "perm-stranger")],
    });
    expect(list.map((question) => [question.source, question.sessionId, question.answers.length])).toEqual([
      ["child", "child", 0],
    ]);
  });

  test("the pager keeps the question shown, else the one that took its place", () => {
    const q = (id: string) => ({ id }) as never;
    expect(keepShown([q("a"), q("b"), q("c")], "b", ["a", "b", "c"])).toBe(1);
    expect(keepShown([q("a"), q("c")], "b", ["a", "b", "c"])).toBe(1);
    expect(keepShown([q("a"), q("b")], "c", ["a", "b", "c"])).toBe(1);
    expect(keepShown([q("x")], undefined, [])).toBe(0);
  });

  test("a list that draws the same keeps its identity, so a streamed chunk never redraws the hat", () => {
    const ask = tagged();
    const one = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", ...lastWord(ask), sessions: [], asks: [] });
    // A streamed chunk shapes a new turn view, with a new row after the card.
    const streamed = { turns: { nextSteps: [{ at: 0, row: ask, turn: 0 }], rows: [ask, row("thinking")] } };
    const two = hatQuestions({
      sessionId: "chat",
      nextStepOwner: "chat",
      ...streamed,
      sessions: [],
      asks: [],
    });
    expect(one).not.toBe(two);
    expect(sameHatQuestions(one, two)).toBe(true);
    expect(sameHatQuestions(one, [])).toBe(false);
  });
});

// #38964: one waiting question drew twice at the composer, as a pinned "Needs your input" card
// (conversation/PendingAsks.tsx) and again in the hat right under it, and the card's Dismiss seemed to
// do nothing: it hid the card, and the hat's copy stayed in its place. The hat holds a tagged ask
// while it is the chat's last word; once another turn came after it, the pinned card holds it, with
// its Dismiss. Both read the one turn view the pane shapes (App.tsx `lastTurns`), whose cards know
// whether a prompt came after them from the turns themselves: the drawn rows can fold that prompt
// away (a Codex turn's Worked for) or merge several into one line (laneNoticeBatches.ts).
describe("a waiting tagged ask is in the hat or pinned above the composer, never both", () => {
  let at = 0;
  const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
  const ASK = "Read the lock path.\n\n[taste] Do you mean computer use, still working while the Mac is locked?";
  const asked = [
    line("p1", "user", { text: "Why does capture stop on lock?" }),
    line("a1", "assistant", { text: ASK }),
    line("s1", "turnSummary", { status: "completed" }),
  ];
  const peer = (id: string, text: string) =>
    line(id, "user", {
      text,
      untyped: true,
      incoming: { kind: "message", message: { name: "ci-lane", text, raw: text } },
    } as Partial<AcpmuxRow>);
  const surfaces = (
    rows: readonly AcpmuxRow[],
    working = false,
    { agentFamily, open }: { agentFamily?: string; open?: string } = {},
  ) => {
    const view = turnViewFrom(rows, new Set(open ? [open] : []), { working, ...(agentFamily && { agentFamily }) });
    const hat = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", turns: view, sessions: [], asks: [] });
    return { hat: hat.map((question) => question.prompt), pinned: waitingAsks(view).map(questionOf) };
  };
  const questionOf = (card: AcpmuxRow) => card.nextStep?.ask.question;
  const QUESTION = "Do you mean computer use, still working while the Mac is locked?";

  test("the chat's last word: in the hat only", () => {
    expect(surfaces(asked)).toEqual({ hat: [QUESTION], pinned: [] });
  });

  test("another agent's message opened a turn after it: pinned only, while that turn runs and after", () => {
    const opened = [...asked, peer("m1", "Pushed abc123; the focused checks are running.")];
    expect(surfaces([...opened, line("a2", "assistant", { text: "Reading" })], true)).toEqual({
      hat: [],
      pinned: [QUESTION],
    });
    const ended = [
      ...opened,
      line("a2", "assistant", { text: "Noted." }),
      line("s2", "turnSummary", { status: "completed" }),
    ];
    expect(surfaces(ended)).toEqual({ hat: [], pinned: [QUESTION] });
  });

  test("two other agents' messages after it, which draw as one line: pinned only", () => {
    const rows = [
      ...asked,
      peer("m1", "Pushed abc123."),
      peer("m2", "The focused checks are green."),
      line("a2", "assistant", { text: "Noted." }),
      line("s2", "turnSummary", { status: "completed" }),
    ];
    expect(surfaces(rows)).toEqual({ hat: [], pinned: [QUESTION] });
  });

  test("a Codex turn another agent started: pinned while it runs, after it ends, its Worked for open or closed", () => {
    const opened = [
      ...asked,
      peer("m1", "Pushed abc123."),
      line("t1", "activity", { items: [] } as Partial<AcpmuxRow>),
    ];
    const codex = { agentFamily: "codex" };
    expect(surfaces([...opened, line("a2", "assistant", { text: "Reading" })], true, codex)).toEqual({
      hat: [],
      pinned: [QUESTION],
    });
    const ended = [
      ...opened,
      line("a2", "assistant", { text: "Noted." }),
      line("s2", "turnSummary", { status: "completed" }),
    ];
    // Closed, the Worked for folds the other agent's prompt in: no prompt row is drawn after the card.
    expect(surfaces(ended, false, codex)).toEqual({ hat: [], pinned: [QUESTION] });
    expect(surfaces(ended, false, { ...codex, open: "worked-m1" })).toEqual({ hat: [], pinned: [QUESTION] });
  });

  test("a send that failed after it: pinned only, still answerable", () => {
    expect(surfaces([...asked, line("p2", "user", { text: "Yes", failed: true })])).toEqual({
      hat: [],
      pinned: [QUESTION],
    });
  });

  test("a bookkeeping turn that draws nothing after it: still the last word, in the hat only", () => {
    const blank = [...asked, line("b1", "user", { text: "" }), line("s2", "turnSummary", { status: "completed" })];
    expect(surfaces(blank)).toEqual({ hat: [QUESTION], pinned: [] });
  });

  test("a question the person dismissed never comes back in the hat", () => {
    const view = turnViewFrom(asked, new Set());
    const [card] = view.nextSteps;
    const dismissed = new Set([askKey(view.rows[card!.at]!)]);
    const hat = hatQuestions({
      sessionId: "chat",
      nextStepOwner: "chat",
      turns: view,
      dismissed,
      sessions: [],
      asks: [],
    });
    expect(hat).toEqual([]);
  });

  test("the person's reply after it: in neither", () => {
    expect(surfaces([...asked, line("p2", "user", { text: "Not yet" })])).toEqual({ hat: [], pinned: [] });
  });
});
