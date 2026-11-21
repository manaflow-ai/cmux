// l10n-allow-file: test fixtures, not shipped UI.
// One ask renders once (Leo, 2026-11-15, with the coordinator's chat showing one [taste] ask twice
// over the composer, pinned under "Needs your input" and again in the composer hat: "there should
// not be 2 of these"). A card in the asks stack (a pinned tagged ask, a sub-session's ask) keeps
// the ask; the hat (hatSeen.ts `hatQuestionsShown`) leaves it out and keeps the rest.
import { expect, test } from "bun:test";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { NEXT_STEP, turnView, turnViewFrom, waitingAsks } from "../conversation/turns";
import type { AcpmuxPermission, AcpmuxRow } from "../model";
import type { WatchedAsk } from "../needsYou/model";
import type { AcpmuxSessionEntry } from "../sessionList";
import { childAsks } from "../subagents/childAsks";
import { hatQuestions } from "./hatModel";
import { hatQuestionsShown, stackCardKeys } from "./hatSeen";
import { questionFromPermission, type AgentQuestion } from "./model";

const FIXTURES = fileURLToPath(
  new URL("../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/", import.meta.url),
);
const fixture = (name: string): AgentQuestion =>
  questionFromPermission(JSON.parse(fs.readFileSync(`${FIXTURES}${name}.request.json`, "utf8")))!;

// The coordinator's order: its turn ended on a tagged ask, then a helper's message started a turn
// of its own. Nothing the person said came after, so the ask is both the hat's (`liveNextStep`)
// and pinned (`waitingAsks`, another turn came after it).
function askThenPeerTurn(): AcpmuxRow[] {
  let at = 0;
  const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}) =>
    ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
  const ask =
    "Ready for review.\n\n[taste] Is 32 px right for the live line in #43627?\nIf yes, it merges at 32 and the value moves to one place.";
  return [
    line("p1", "user", { text: "Ship the live line." }),
    line("a1", "assistant", { text: ask }),
    line("s1", "turnSummary", { status: "completed" }),
    line("m1", "user", {
      text: "Pushed abc123.",
      untyped: true,
      incoming: { kind: "message", message: { name: "helper", text: "Pushed abc123.", raw: "Pushed abc123." } },
    } as Partial<AcpmuxRow>),
    line("a2", "assistant", { text: "Noted." }),
    line("s2", "turnSummary", { status: "completed" }),
  ];
}

test("a tagged ask pinned above the composer is not also in the composer hat", () => {
  const rows = askThenPeerTurn();
  const shaped = turnView(rows, new Set());
  const pinned = waitingAsks(turnViewFrom(rows, new Set()));
  const hat = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", rows: shaped, sessions: [], asks: [] });
  // Both read the same ask: that is the two cards Leo saw.
  expect(pinned.map((row) => row.nextStep?.ask.question)).toEqual(["Is 32 px right for the live line in #43627?"]);
  expect(hat.map((question) => [question.source, question.prompt])).toEqual([
    ["nextStep", "Is 32 px right for the live line in #43627?"],
  ]);
  // Drawn: the pinned card keeps it, the hat leaves it.
  expect(hatQuestionsShown(hat, new Set(), stackCardKeys(pinned, undefined))).toEqual([]);
  // Before another turn came, nothing is pinned: the hat is where the ask shows.
  const before = rows.slice(0, 3);
  const beforeShaped = turnView(before, new Set());
  expect(waitingAsks(turnViewFrom(before, new Set()))).toEqual([]);
  const alone = hatQuestions({ sessionId: "chat", nextStepOwner: "chat", rows: beforeShaped, sessions: [], asks: [] });
  expect(hatQuestionsShown(alone, new Set(), stackCardKeys([], undefined)).map((q) => q.source)).toEqual(["nextStep"]);
  expect(beforeShaped.some((row) => row.kind === NEXT_STEP)).toBe(true);
});

test("a sub-session's ask on its card in the stack is not also in the hat; the one behind it stays", () => {
  const sessions = [
    { sessionId: "chat", title: "Coordinator" },
    { sessionId: "child", name: "helper", harness: "claude", startedBy: "chat", pendingPermissions: 1 },
    { sessionId: "child-2", name: "helper-2", harness: "claude", startedBy: "chat", pendingPermissions: 1 },
  ] as unknown as AcpmuxSessionEntry[];
  const asked = (sessionId: string, id: string, at: number): WatchedAsk => {
    const question = fixture("pending-single");
    const permission = {
      permissionId: id,
      pending: true,
      options: [],
      question: { ...question, source: { ...question.source, session: sessionId } },
    } as unknown as AcpmuxPermission;
    return { sessionId, permission, at };
  };
  const asks = [asked("child", "perm-child", 1), asked("child-2", "perm-child-2", 2)];
  const onCard = childAsks(asks, sessions, "chat")[0];
  expect(onCard?.ask.permission.permissionId).toBe("perm-child");
  const hat = hatQuestions({ sessionId: "chat", rows: [], sessions, asks });
  expect(hat.map((question) => question.sessionId ?? "").sort((a, b) => a.localeCompare(b))).toEqual([
    "child",
    "child-2",
  ]);
  const shown = hatQuestionsShown(hat, new Set(), stackCardKeys([], onCard));
  expect(shown.map((question) => question.sessionId)).toEqual(["child-2"]);
});

test("nothing on the stack keeps the hat's list as it is", () => {
  const hat = hatQuestions({
    sessionId: "chat",
    nextStepOwner: "chat",
    rows: turnView(askThenPeerTurn().slice(0, 3), new Set()),
    sessions: [],
    asks: [],
  });
  expect(hatQuestionsShown(hat, new Set(), stackCardKeys([], undefined))).toBe(hat);
});
