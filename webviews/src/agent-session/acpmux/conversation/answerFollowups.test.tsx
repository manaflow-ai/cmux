// l10n-allow-file: test fixtures.
// Review follow-ups of the pinned questions (PendingAsks.tsx):
// F1 an answer clicked on an older pinned card settles that card, not the newest with the same answers;
// F2 the transcript's card and its pinned copy share the answer on its way, so two clicks send once;
// F3 a send acpmux already took is sent, never "Not sent" (a retry would answer twice);
// F4 pinned questions show the asks stack without taking the composer's empty ⌘↩.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { nextStepAsk } from "./nextStepAsk";
import { answerThrough } from "./turnActions";
import { NEXT_STEP, turnViewFrom, waitingAsks } from "./turns";
import { askKey, bottomAsks, claimAnswer, dismissAsk, dismissedAsks, resetAnswerClaims } from "./waitingAskStore";
import { settleReact } from "../../../../test/support/domTeardown";

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
  await settleReact();
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

test("F1: an answer clicked on the older of two questions settles the older one", () => {
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
  // Only the newest question pins (turns.ts `waitingAsks`, https://github.com/manaflow-ai/cmux/issues/52766); the older stays answerable
  // in the transcript.
  const [older] = before.rows.filter((row) => row.kind === NEXT_STEP);
  expect(older?.nextStep?.ask.question).toBe("Should agents keep working while the Mac is locked?");
  expect(waitingAsks(before).map((card) => card.nextStep?.ask.question)).toEqual(["Should I post the gallery?"]);
  // The person clicks Yes on the older card in the transcript; its prompt comes after both cards.
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

test("F1: a typed answer after the newer card answers it; the older stays answerable, unpinned", () => {
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
  // The newest question stands for the older ones (https://github.com/manaflow-ai/cmux/issues/52766): answered, nothing stays pinned.
  expect(waitingAsks(view)).toEqual([]);
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
  const second = buttons()[1]!;
  await act(async () => buttons()[0]!.click());
  // Both copies read as answered from the click on: no answer left to click.
  expect(buttons()).toEqual([]);
  await act(async () => second.click());
  // No asker named: the quote is the question alone (nextStepAsk.ts `answerPrompt`).
  expect(sent).toEqual(["> Which look should ship?\n\nInline"]);
  await act(async () => finish());
  expect(buttons()).toEqual([]);
  expect(container.querySelectorAll(".acpmux-question-answered-answer")).toHaveLength(2);
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
  expect(bottomAsks(false, 2)).toEqual({ shows: true, holdsKeys: false, leaving: false });
  expect(bottomAsks(true, 0)).toEqual({ shows: true, holdsKeys: true, leaving: false });
  expect(bottomAsks(false, 0)).toEqual({ shows: false, holdsKeys: false, leaving: false });
});

test("a trust question folding out keeps the stack drawn, holds no keys, and marks it leaving", () => {
  expect(bottomAsks(false, 0, true)).toEqual({ shows: true, holdsKeys: false, leaving: true });
  expect(bottomAsks(true, 0, true)).toEqual({ shows: true, holdsKeys: true, leaving: false });
  expect(bottomAsks(false, 1, true)).toEqual({ shows: true, holdsKeys: false, leaving: false });
});
