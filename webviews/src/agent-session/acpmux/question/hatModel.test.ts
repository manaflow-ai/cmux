// l10n-allow-file: test fixtures, not shipped UI.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { NEXT_STEP } from "../conversation/turns";
import type { AcpmuxPermission, AcpmuxRow } from "../model";
import type { WatchedAsk } from "../needsYou/model";
import type { AcpmuxSessionEntry } from "../sessionList";
import {
  hatQuestions,
  hatShows,
  hatTag,
  keepShown,
  liveNextStep,
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
  test("a tagged ask leaves the hat once the person says anything after it, or a later card settles it", () => {
    const ask = tagged();
    expect(liveNextStep([said("go"), row("assistant"), ask])).toBe(ask);
    expect(liveNextStep([ask, said("I made the key but on the other account")])).toBeUndefined();
    // What answers nothing leaves it: another agent's message, one received, a failed or blank send.
    expect(liveNextStep([ask, row("user", { text: "from the chief", incoming: {} as never })])).toBe(ask);
    expect(liveNextStep([ask, row("user", { text: "from the phone", received: {} as never })])).toBe(ask);
    expect(liveNextStep([ask, row("user", { text: "Yes", failed: true })])).toBe(ask);
    expect(liveNextStep([ask, row("user", { text: "" })])).toBe(ask);
    expect(liveNextStep([tagged({ answer: "Yes" })])).toBeUndefined();
    expect(liveNextStep([tagged({ superseded: true })])).toBeUndefined();
    const [shown] = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", rows: [ask], sessions: [], asks: [] });
    expect(shown).toMatchObject({ source: "nextStep", sessionId: "chat", tag: "physical", typed: true });
    expect(shown!.answers.map((answer) => answer.key)).toEqual(["recap.yes", "recap.notNow"]);
    // Where the composer could not send it (View Only, a read-only pane), the hat offers no answer.
    expect(hatQuestions({ sessionId: "chat", rows: [ask], sessions: [], asks: [] })).toEqual([]);
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
      rows: [tagged()],
      sessions: [],
      asks: [],
    });
    expect(list.map((question) => question.source)).toEqual(["own"]);
  });

  // Leo, 2026-11-10: "this is unusable to respond to i necessarily have to open... this is bad ui".
  test("a started chat's question is answered in the hat: who asks, what about, its choices and Other", () => {
    const sessions = [
      { sessionId: "chat", title: "Coordinator" },
      {
        sessionId: "child",
        name: "coord-deputy",
        title: "From claude-sr2-coord: coord-deputy left real product a…",
        harness: "claude",
        startedBy: "chat",
        pendingPermissions: 1,
      },
      {
        sessionId: "unnamed",
        name: "claude-2",
        title: "A long generated title",
        harness: "claude",
        startedBy: "chat",
        pendingPermissions: 1,
      },
      { sessionId: "planner", name: "planner", harness: "codex", startedBy: "chat", pendingPermissions: 1 },
    ] as unknown as AcpmuxSessionEntry[];
    const asked = (sessionId: string, id: string, question = fixture("pending-single")): WatchedAsk => ({
      sessionId,
      permission: permission({ ...question, source: { ...question.source, session: sessionId } }, id),
      at: 1,
    });
    const recommended = fixture("pending-single");
    recommended.items[0]!.options[1] = {
      ...recommended.items[0]!.options[1]!,
      id: "API keys (Recommended)",
      label: "API keys (Recommended)",
    };
    const [named, longer, generated] = hatQuestions({
      sessionId: "chat",
      rows: [],
      sessions,
      asks: [
        asked("child", "perm-child", recommended),
        asked("unnamed", "perm-unnamed"),
        asked("planner", "perm-four", fixture("pending-4-questions")),
      ],
    }).sort((a, b) => a.id.localeCompare(b.id));
    // Who asks is the chat's own name, never its long title; what about is the question's header.
    expect(named).toMatchObject({ source: "child", who: "coord-deputy", about: "Auth method", typed: true });
    expect(named!.answers.map((answer) => [answer.label, answer.recommended ?? false])).toEqual([
      ["OAuth 2.0", false],
      ["API keys", true],
      ["Passkeys", false],
    ]);
    // The answer still sends the option as the agent wrote it.
    expect(named!.answers[1]!.id).toBe("API keys (Recommended)");
    // A chat with only a generated name is named by its agent.
    expect(generated).toMatchObject({ who: "Claude" });
    // Several questions in one ask need the card: no buttons, no field; Open Chat takes it.
    expect(longer).toMatchObject({ answers: [], typed: false });
  });

  test("a started chat's question shows; another chat's never shows", () => {
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
      ["child", "child", 3],
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
    const one = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", rows: [ask], sessions: [], asks: [] });
    const two = hatQuestions({
      sessionId: "chat",
      nextStepOwner: "chat",
      rows: [ask, row("thinking")],
      sessions: [],
      asks: [],
    });
    expect(one).not.toBe(two);
    expect(sameHatQuestions(one, two)).toBe(true);
    expect(sameHatQuestions(one, [])).toBe(false);
  });
});
