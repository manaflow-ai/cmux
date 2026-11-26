// l10n-allow-file: test fixtures, not shipped UI.
// One question renders once however often the agent asks it
// (https://github.com/manaflow-ai/cmux/issues/52766): a coordinator woken by other agents' messages
// ended five turns on the same question, and the chat drew it as four stacked "Needs your input"
// cards plus the composer hat's copy; another chat stacked six rewordings of one merge question.
// Each asking is its own card under its own key (its turn's time), so only the chat's newest
// question may show, once, and answering or dismissing it clears the stack.
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

test("putting the hat's copy away clears every asking", () => {
  const rows = askedAgain(5);
  const [question] = hat(rows);
  expect(question?.answerKey).toBeDefined();
  expect(drawn(rows, dismissAsk("chat", question!.answerKey!))).toEqual([]);
});

test("an asking that differs only in case or spacing is the same question", () => {
  const rows = askedAgain(3);
  const louder = ASK.replace(QUESTION, `  ${QUESTION.toUpperCase().replace(/ /g, "  ")}`);
  const mixed = [...rows, peer("m4", "Pushed 4."), line("a4", "assistant", { text: louder })];
  mixed.push(line("s4", "turnSummary", { status: "completed" }));
  expect(drawn(mixed)).toHaveLength(1);
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

test("a reworded or different newer question takes the older's place: one card, never a stack", () => {
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
  // The newest question is the hat's; the older one stays answerable in the transcript, unpinned.
  expect(drawn(rows)).toEqual([QUESTION]);
  // Once another turn follows, the newest pins alone.
  const later = [...rows, peer("m4", "Pushed 4."), line("a4", "assistant", { text: "Noted." })];
  expect(drawn(later)).toEqual([QUESTION]);
});

test("six reworded askings of one merge decision pin as one card, the newest", () => {
  clock = 0;
  const asks = [
    "Should I merge on the gallery renders, or wait for the dev build?\n- Yes\n- Not now",
    "Merge now that the gallery renders are green?\n- Merge on green\n- Wait",
    "Should I merge once web is green?\n- Merge when web is green\n- Hold",
    "Merge now, or wait for the base fix?\n- Wait for base fix\n- Merge now",
    "Should I retry the dev build once the build fleet is answering again, or skip it?\n- Yes\n- Not now",
    "Should I retry the dev build once the build fleet answers again, or skip it?\n- Yes\n- Not now",
  ];
  const rows = [line("p1", "user", { text: "Ship it." })];
  asks.forEach((text, index) => {
    if (index > 0) rows.push(peer(`m${index}`, `Background task finished ${index}.`));
    rows.push(line(`a${index}`, "assistant", { text: `Status.\n\n[outward] ${text}` }));
    rows.push(line(`s${index}`, "turnSummary", { status: "completed" }));
  });
  const newest = "Should I retry the dev build once the build fleet answers again, or skip it?";
  // The chat's last word: the hat holds it, nothing pins.
  expect(pinned(rows)).toEqual([]);
  expect(drawn(rows)).toEqual([newest]);
  // Another turn later: it pins, alone; its Dismiss clears the stack.
  const later = [...rows, peer("m9", "Background task finished."), line("a9", "assistant", { text: "Waiting." })];
  const stack = pinned(later);
  expect(stack.map((row) => row.nextStep!.ask.question)).toEqual([newest]);
  expect(drawn(later, dismissAsk("chat", askKey(stack[0]!)))).toEqual([]);
});

test("recap-only wrap-ups after a question never unpin it", () => {
  clock = 0;
  const rows = askedAgain(1);
  const question = turnView(rows, new Set()).find((row) => row.nextStep?.ask.question)!;
  const recap = (id: string, superseded?: boolean): AcpmuxRow => ({
    ...line(id, "nextStep"),
    nextStep: {
      ask: { tag: "wrap_up", recap: "Waiting on CI.", question: "", options: [], rest: "" },
      ...(superseded && { superseded }),
    },
  });
  // Two background turns each end on a recap with nothing to decide; settleNextSteps marks the older
  // recap superseded, which must not read as the question being taken over.
  const view = {
    rows: [
      question,
      peer("m2", "Background task finished."),
      recap("r1", true),
      peer("m3", "Background task finished."),
      recap("r2"),
    ],
    nextSteps: [
      { at: 0, row: question },
      { at: 2, row: question },
      { at: 4, row: question },
    ],
  };
  view.nextSteps[1]!.row = view.rows[2]!;
  view.nextSteps[2]!.row = view.rows[4]!;
  expect(waitingAsks(view).map((card) => card.nextStep?.ask.question)).toEqual([QUESTION]);
});
