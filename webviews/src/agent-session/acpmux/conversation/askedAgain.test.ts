// l10n-allow-file: test fixtures, not shipped UI.
// One question renders once however often the agent asks it
// (https://github.com/manaflow-ai/cmux/issues/52766): a coordinator woken by other agents' messages
// ended five turns on the same question, and the chat drew it as four stacked "Needs your input"
// cards plus the composer hat's copy. Each asking is its own card under its own key (its turn's
// time), so only the newest asking of a question may show, and answering or dismissing it clears it.
import { beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { hatQuestions } from "../question/hatModel";
import { hatQuestionsShown, stackCardKeys } from "../question/hatSeen";
import { turnView, turnViewFrom, waitingAsks } from "./turns";
import { askKey, dismissAsk, resetAnswerClaims, shownAsks } from "./waitingAskStore";

beforeEach(() => {
  globalThis.localStorage?.clear();
  resetAnswerClaims();
});

const QUESTION = "Can you click the dev build tab in my right split so I can take the after screenshots?";
const ASK = `Built it.\n\n[physical] ${QUESTION}\n- Launched it\n- Skip screenshots`;

let clock = 0;
const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}) =>
  ({ id, version: 1, at: (clock += 1000), kind, ...extra }) as AcpmuxRow;
const peer = (id: string, text: string) =>
  line(id, "user", {
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "helper", text, raw: text } },
  } as Partial<AcpmuxRow>);

/// The person's prompt, then `times` turns that each end on the same ask, every turn after the first
/// started by another agent's message.
function askedAgain(times: number, question = ASK): AcpmuxRow[] {
  clock = 0;
  const rows = [line("p1", "user", { text: "Take before and after screenshots." })];
  for (let turn = 1; turn <= times; turn += 1) {
    if (turn > 1) rows.push(peer(`m${turn}`, `Pushed ${turn}.`));
    rows.push(line(`a${turn}`, "assistant", { text: question }));
    rows.push(line(`s${turn}`, "turnSummary", { status: "completed" }));
  }
  return rows;
}

const pinned = (rows: AcpmuxRow[]) => waitingAsks(turnViewFrom(rows, new Set()));
const hat = (rows: AcpmuxRow[]) =>
  hatQuestions({ sessionId: "chat", nextStepOwner: "chat", rows: turnView(rows, new Set()), sessions: [], asks: [] });
/// Every copy of the ask drawn over the composer: the pinned cards and the hat's questions they leave.
function drawn(rows: AcpmuxRow[], dismissed: ReadonlySet<string> = new Set()) {
  const stack = shownAsks(pinned(rows), dismissed);
  const inHat = hatQuestionsShown(hat(rows), dismissed, stackCardKeys(stack, undefined));
  return [...stack.map((row) => row.nextStep!.ask.question), ...inHat.map((question) => question.prompt)];
}

test("the same question asked at the end of five turns draws once, in the hat", () => {
  const rows = askedAgain(5);
  // Every asking stays a card in the transcript, each still waiting on the person.
  expect(turnView(rows, new Set()).filter((row) => row.nextStep?.ask.question === QUESTION)).toHaveLength(5);
  expect(pinned(rows)).toEqual([]);
  expect(drawn(rows)).toEqual([QUESTION]);
});

test("once another turn followed the newest asking, the one pinned card is it", () => {
  const rows = [...askedAgain(5), peer("m6", "Pushed 6."), line("a6", "assistant", { text: "Noted." })];
  const stack = pinned(rows);
  expect(stack).toHaveLength(1);
  expect(stack[0]!.at).toBe(rows.find((row) => row.id === "a5")!.at);
  expect(drawn(rows)).toEqual([QUESTION]);
});

test("Dismiss on the one card clears every asking", () => {
  const rows = [...askedAgain(4), peer("m5", "Pushed 5."), line("a5", "assistant", { text: "Noted." })];
  const [card] = pinned(rows);
  expect(card).toBeDefined();
  const dismissed = dismissAsk("chat", askKey(card!));
  expect(drawn(rows, dismissed)).toEqual([]);
});

test("answering the newest asking clears the older askings too", () => {
  const rows = [...askedAgain(4), line("p2", "user", { text: "Launched it" })];
  expect(pinned(rows)).toEqual([]);
  expect(drawn(rows)).toEqual([]);
  // And after a later turn another agent's message started, the older askings stay settled.
  const later = [
    ...rows,
    line("a9", "assistant", { text: "Thanks." }),
    peer("m9", "Pushed 9."),
    line("a10", "assistant", { text: "Ok." }),
  ];
  expect(drawn(later)).toEqual([]);
});

test("different questions each still pin, oldest first", () => {
  clock = 0;
  const other = "Built it.\n\n[taste] Is 32 px right for the live line?\n- Yes\n- No";
  const rows = [
    line("p1", "user", { text: "Go." }),
    line("a1", "assistant", { text: other }),
    line("s1", "turnSummary", { status: "completed" }),
    peer("m2", "Pushed."),
    line("a2", "assistant", { text: ASK }),
    line("s2", "turnSummary", { status: "completed" }),
    peer("m3", "Pushed again."),
    line("a3", "assistant", { text: ASK }),
    line("s3", "turnSummary", { status: "completed" }),
  ];
  // The taste question pins; the screenshot question is the hat's, once.
  expect(drawn(rows)).toEqual(["Is 32 px right for the live line?", QUESTION]);
});
