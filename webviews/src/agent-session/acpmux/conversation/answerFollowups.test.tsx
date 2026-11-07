// l10n-allow-file: test fixtures.
// Review follow-ups of the pinned questions (PendingAsks.tsx):
// F1 an answer clicked on an older pinned card settles that card, not the newest with the same answers;
// F2 the transcript's card and its pinned copy share the answer on its way, so two clicks send once;
// F3 a send acpmux already took is sent, never "Not sent" (a retry would answer twice);
// F4 pinned questions show the asks stack without taking the composer's empty ⌘↩;
// then, a card taken over by a later one never hides an older one still waiting, and a clicked answer
// matches only a prompt sent past the click, not an earlier one with the same words.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { LANE_NOTICE_BATCH, type AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { nextStepAsk } from "./nextStepAsk";
import { answerThrough } from "./turnActions";
import { answersSent, NEXT_STEP, turnViewFrom, waitingAsks } from "./turns";
import {
  answerClaim,
  askKey,
  bottomAsks,
  claimAnswer,
  dismissAsk,
  dismissedAsks,
  resetAnswerClaims,
  settleClaim,
} from "./waitingAskStore";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  resetAnswerClaims();
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  resetAnswerClaims();
});

let at = 1_000_000;
const line = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}) =>
  ({ id, version: 1, at: (at += 1000), kind, ...extra }) as AcpmuxRow;
const inbound = (id: string, text: string) =>
  line(id, "user", {
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "peer-lane", text, raw: text } },
  } as Partial<AcpmuxRow>);

test("F1: an answer clicked on the older of two pinned questions settles the older one", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    inbound("m1", "Gallery ready."),
    line("a2", "assistant", { text: "[outward] Should I post the gallery?" }),
    line("s2", "turnSummary", { status: "completed" }),
    inbound("m2", "Checks green."),
    line("a3", "assistant", { text: "Noted." }),
    line("s3", "turnSummary", { status: "completed" }),
  ];
  const before = turnViewFrom(rows, new Set());
  const [older, newer] = waitingAsks(before);
  expect(older?.nextStep?.ask.question).toBe("Should agents keep working while the Mac is locked?");
  expect(newer?.nextStep?.ask.question).toBe("Should I post the gallery?");
  // The person clicks Yes on the older card; its prompt comes after both cards.
  claimAnswer(askKey(older!), "Yes", at);
  const answered = [...rows, line("p2", "user", { text: "Yes" })];
  const view = turnViewFrom(answered, new Set(), {}, before);
  const cards = view.rows.filter((row) => row.kind === NEXT_STEP);
  expect(cards[0]?.nextStep?.answer).toBe("Yes");
  expect(cards[0]?.nextStep?.superseded).toBeUndefined();
  expect(cards[1]?.nextStep?.answer).toBeUndefined();
  expect(cards[1]?.nextStep?.superseded).toBeUndefined();
  // The newer one still waits, pinned.
  expect(waitingAsks(view).map((card) => card.nextStep?.ask.question)).toEqual(["Should I post the gallery?"]);
  // A reload, with no earlier view, settles the same way.
  const reloaded = turnViewFrom(
    answered.map((row) => ({ ...row })),
    new Set(),
  );
  expect(reloaded.rows.filter((row) => row.kind === NEXT_STEP).map((row) => row.nextStep?.answer)).toEqual([
    "Yes",
    undefined,
  ]);
});

test("F1: a typed answer after the newer card answers it, and the older stays pinned and answerable", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    inbound("m1", "Gallery ready."),
    line("a2", "assistant", { text: "[outward] Should I post the gallery?" }),
    line("s2", "turnSummary", { status: "completed" }),
    line("p2", "user", { text: "Yes" }),
  ];
  const view = turnViewFrom(rows, new Set());
  const cards = view.rows.filter((row) => row.kind === NEXT_STEP);
  expect(cards[1]?.nextStep?.answer).toBe("Yes");
  expect(cards[0]?.nextStep?.answer).toBeUndefined();
  expect(cards[0]?.nextStep?.superseded).toBeUndefined();
  // Still waiting on the person, so still pinned: never live in the transcript but hidden above the composer.
  expect(waitingAsks(view).map((card) => card.nextStep?.ask.question)).toEqual([
    "Should agents keep working while the Mac is locked?",
  ]);
});

test("F2: the card's two copies share the answer on its way, so two clicks send it once", async () => {
  const ask = nextStepAsk("[taste] Which look should ship?\n- Box\n- Inline")!;
  const sent: string[] = [];
  let finish: () => void = () => undefined;
  const onAnswer = (text: string) => {
    sent.push(text);
    return new Promise<void>((resolve) => (finish = resolve));
  };
  const container = dom!.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <>
        <NextStepCard ask={ask} onAnswer={onAnswer} answerKey="card-1" />
        <NextStepCard ask={ask} onAnswer={onAnswer} answerKey="card-1" />
      </>,
    );
  });
  const buttons = () => [...container.querySelectorAll("button")].filter((b) => b.textContent?.includes("Inline"));
  await act(async () => buttons()[0]!.click());
  expect(buttons().every((b) => b.disabled)).toBe(true);
  await act(async () => buttons()[1]!.click());
  expect(sent).toEqual(["Inline"]);
  await act(async () => finish());
  expect(buttons().some((b) => b.disabled)).toBe(false);
});

test("F3: a send acpmux already took counts as sent; one it never took still says so", async () => {
  const taken = answerThrough(() => Promise.reject(Object.assign(new Error("turn failed"), { taken: true })))("Yes");
  await expect(taken).resolves.toBeUndefined();
  const refused = answerThrough(() => Promise.reject(new Error("refused")))("Yes");
  await expect(refused).rejects.toThrow("refused");
});

test("dismissals without local storage: a second one keeps the first", () => {
  delete scope.localStorage;
  resetAnswerClaims();
  dismissAsk("s1", "a");
  dismissAsk("s1", "b");
  expect([...dismissedAsks("s1")].sort()).toEqual(["a", "b"]);
});

test("F4: pinned questions show the stack but leave the composer's keys alone", () => {
  expect(bottomAsks(false, 2)).toEqual({ shows: true, holdsKeys: false });
  expect(bottomAsks(true, 0)).toEqual({ shows: true, holdsKeys: true });
  expect(bottomAsks(false, 0)).toEqual({ shows: false, holdsKeys: false });
});

test("an older question stays pinned behind a later one the person answered and a newer one took over", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    inbound("m1", "Gallery ready."),
    line("a2", "assistant", { text: "[outward] Should I post the gallery?" }),
    line("s2", "turnSummary", { status: "completed" }),
    line("p2", "user", { text: "Yes" }),
    line("a3", "assistant", { text: "[taste] Should I pin it above the composer?" }),
    line("s3", "turnSummary", { status: "completed" }),
    inbound("m2", "Checks green."),
    line("a4", "assistant", { text: "Noted." }),
    line("s4", "turnSummary", { status: "completed" }),
  ];
  const view = turnViewFrom(rows, new Set());
  const cards = view.rows.filter((row) => row.kind === NEXT_STEP);
  expect(cards[1]?.nextStep?.superseded).toBe(true);
  expect(waitingAsks(view).map((card) => card.nextStep?.ask.question)).toEqual([
    "Should agents keep working while the Mac is locked?",
    "Should I pin it above the composer?",
  ]);
});

test("a clicked answer settles its card only with a prompt sent past the click", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    inbound("m1", "Gallery ready."),
    line("a2", "assistant", { text: "[outward] Should I post the gallery?" }),
    line("s2", "turnSummary", { status: "completed" }),
    // The person answers the newer card Yes...
    line("p2", "user", { text: "Yes" }),
    line("a3", "assistant", { text: "Posting it." }),
    line("s3", "turnSummary", { status: "completed" }),
  ];
  const before = turnViewFrom(rows, new Set());
  const [older] = waitingAsks(before);
  expect(older?.nextStep?.ask.question).toBe("Should agents keep working while the Mac is locked?");
  // ...then clicks Yes on the older one, seconds later: the earlier Yes is past its boundary.
  const key = askKey(older!);
  claimAnswer(key, "Yes", at, answersSent(before, key, "Yes"));
  const waiting = turnViewFrom(rows, new Set(), {}, before);
  let cards = waiting.rows.filter((row) => row.kind === NEXT_STEP);
  expect(cards.map((row) => row.nextStep?.answer)).toEqual([undefined, "Yes"]);
  // Its own Yes, once sent, settles it; the newer keeps the one before.
  const answered = [...rows, line("p3", "user", { text: "Yes" })];
  const view = turnViewFrom(answered, new Set(), {}, waiting);
  cards = view.rows.filter((row) => row.kind === NEXT_STEP);
  expect(cards.map((row) => row.nextStep?.answer)).toEqual(["Yes", "Yes"]);
  expect(waitingAsks(view)).toEqual([]);
  // A reload settles the same way.
  const reloaded = turnViewFrom(
    answered.map((row) => ({ ...row })),
    new Set(),
  );
  expect(reloaded.rows.filter((row) => row.kind === NEXT_STEP).map((row) => row.nextStep?.answer)).toEqual([
    "Yes",
    "Yes",
  ]);
});

/// A review report from another agent; two in a row fold into one batch (laneNoticeBatches.ts).
const report = (id: string, verdict: string, extra: Partial<AcpmuxRow> = {}) => {
  const text = `Review (Astra): ${verdict} at 0123456789abcdef0123456789abcdef01234567`;
  return line(id, "user", {
    text,
    untyped: true,
    incoming: { kind: "message", message: { name: "review-lane", text, raw: text, report: true } },
    ...extra,
  } as Partial<AcpmuxRow>);
};

test("a question followed by two peer notices stays pinned once they fold into one batch", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    report("m1", "SHIP", { continues: true }),
    // Both delivered into the turn that asked, so the two fold into one batch.
    report("m2", "BLOCK", { continues: true }),
  ];
  const view = turnViewFrom(rows, new Set());
  expect(view.rows.filter((row) => row.kind === LANE_NOTICE_BATCH)).toHaveLength(1);
  expect(waitingAsks(view).map((card) => card.nextStep?.ask.question)).toEqual([
    "Should agents keep working while the Mac is locked?",
  ]);
});

test("a claim settles nothing past its send: a later prompt with the same words is not its answer", () => {
  const rows = [
    line("p1", "user", { text: "Why does it stop on lock?" }),
    line("a1", "assistant", { text: "[taste] Should agents keep working while the Mac is locked?" }),
    line("s1", "turnSummary", { status: "completed" }),
    inbound("m1", "Gallery ready."),
    line("a2", "assistant", { text: "[outward] Should I post the gallery?" }),
    line("s2", "turnSummary", { status: "completed" }),
  ];
  const [older] = waitingAsks(turnViewFrom(rows, new Set()));
  const key = askKey(older!);
  const answers = (when: number) => {
    at = when;
    const view = turnViewFrom([...rows, line("p2", "user", { text: "Yes" })], new Set());
    return view.rows.filter((row) => row.kind === NEXT_STEP).map((row) => row.nextStep?.answer);
  };
  // Clicked and sent: its prompt reached the chat by the time the send settled.
  const click = at;
  claimAnswer(key, "Yes", click, 0);
  settleClaim(key, click + 1000);
  expect(answers(click + 500)).toEqual(["Yes", undefined]);
  // A "Yes" well after that settled send is the person answering the newer card.
  expect(answers(click + 600_000)).toEqual([undefined, "Yes"]);
  // A claim whose send never settled (the pane closed) holds only so long.
  resetAnswerClaims();
  claimAnswer(key, "Yes", click, 0);
  expect(answers(click + 7_200_000)).toEqual([undefined, "Yes"]);
});

test("a failed send drops its claim", async () => {
  const ask = nextStepAsk("[taste] Which look should ship?\n- Box\n- Inline")!;
  const container = dom!.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(<NextStepCard ask={ask} onAnswer={() => Promise.reject(new Error("refused"))} answerKey="card-9" />);
  });
  const button = [...container.querySelectorAll("button")].find((b) => b.textContent?.includes("Inline"))!;
  await act(async () => button.click());
  expect(answerClaim("card-9")).toBeUndefined();
});
