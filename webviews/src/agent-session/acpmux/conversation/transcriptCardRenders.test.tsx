// l10n-allow-file: test fixture questions and todo items, not shipped UI.
// The answered question card and the todo list sit in a turn while the agent's reply streams below
// them. Each token re-renders the turn around them; neither card may redraw for it (Leo,
// 2026-10-21: no new O(rows) work per token in the transcript path). Both are memoized on their
// immutable inputs: the decided question record and the plan's entries.
//
// A card's renders are counted through `useT`, which each of them calls once per render (and
// nothing else in this tree calls). A React Profiler can't count them: one made again on every
// render reports a commit even when the memoized card inside it bails out.
import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { act, Profiler, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import * as i18n from "../i18n";
import type { AcpmuxPermission, AcpmuxPlanEntry } from "../model";
import type { AgentQuestion } from "../question/model";

let cardRenders = 0;
const realUseT = i18n.useT;
void mock.module("../i18n", () => ({
  ...i18n,
  useT: () => {
    cardRenders++;
    return realUseT();
  },
}));
const { QuestionCard } = await import("../question/QuestionCard");
const { PlanList } = await import("./PlanList");
const { PermissionQuestion } = await import("../question/PermissionQuestion");

const TOKENS = 200;
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const answered: AgentQuestion = {
  id: "perm_ask",
  source: { harness: "claude", session: "sess_1", permission: "perm_ask", answerOption: "allow_once" },
  items: [
    {
      id: "q0",
      header: "Auth method",
      prompt: "Which auth method should the API use?",
      options: [
        { id: "OAuth 2.0", label: "OAuth 2.0" },
        { id: "Passkeys", label: "Passkeys" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "answered", answer: { selections: { q0: { optionIDs: ["Passkeys"] } } } },
};
const skipped: AgentQuestion = { ...answered, id: "perm_skip", state: { kind: "cancelled", reason: "skipped" } };
const plan: AcpmuxPlanEntry[] = [
  { content: "Check the current auth config", status: "completed" },
  { content: "Switch to the personal account", status: "in_progress" },
  { content: "Verify the login", status: "pending" },
];
const ignoreReply = () => {};

/// A turn: the cards above, then the reply that streams one token per update. The cards are made
/// again on every render, as the transcript's rows are, so only their memo keeps them still.
function Turn({ cards, push }: { cards: () => ReactNode; push: (next: (token: number) => void) => void }) {
  const [tokens, setTokens] = useState(0);
  push(setTokens);
  return (
    <article>
      {cards()}
      <p className="reply">{"token ".repeat(tokens)}</p>
    </article>
  );
}

/// Card renders while `TOKENS` tokens stream, and commits of the turn around them.
async function stream(cards: () => ReactNode) {
  let turn = 0;
  cardRenders = 0;
  let setTokens: (token: number) => void = () => {};
  const root: Root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <Profiler id="turn" onRender={() => turn++}>
        <Turn push={(next) => (setTokens = next)} cards={cards} />
      </Profiler>,
    ),
  );
  for (let token = 1; token <= TOKENS; token++) await act(async () => setTokens(token));
  const reply = dom.window.document.querySelector(".reply")?.textContent ?? "";
  await act(async () => root.unmount());
  return { turn, cards: cardRenders, reply };
}

test("streaming tokens never redraw an answered or skipped question or the todo list", async () => {
  const { turn, cards, reply } = await stream(() => (
    <>
      <QuestionCard question={answered} onReply={ignoreReply} />
      <QuestionCard question={skipped} onReply={ignoreReply} />
      <PlanList entries={plan} />
    </>
  ));
  expect(reply.split(" ").length - 1).toBe(TOKENS);
  // The turn commits once per token; the three cards render once each, on mount.
  expect(turn).toBe(TOKENS + 1);
  expect(cards).toBe(3);
});

test("the live ask's card keeps still while the pane streams", async () => {
  const pending: AgentQuestion = { ...answered, id: "perm_live", state: { kind: "pending" } };
  // The pane passes the same permission record on every token (direct.ts keeps a pending ask's
  // object across snapshots) and App.tsx's module-level replyToQuestion as `send`.
  const permission = { permissionId: "perm_live", pending: true, options: [], question: pending } as AcpmuxPermission;
  const send = () => {};
  const { cards } = await stream(() => <PermissionQuestion permission={permission} question={pending} send={send} />);
  // PendingAsk and PendingQuestion each read the strings once, on mount only.
  expect(cards).toBe(2);
});

test("a plan update or the turn's end still redraws the list", async () => {
  let setEntries: (entries: AcpmuxPlanEntry[]) => void = () => {};
  let setEnded: (ended: boolean) => void = () => {};
  function Live() {
    const [entries, entriesSetter] = useState(plan);
    const [ended, endedSetter] = useState(false);
    setEntries = entriesSetter;
    setEnded = endedSetter;
    return <PlanList entries={entries} ended={ended} />;
  }
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  cardRenders = 0;
  await act(async () => root.render(<Live />));
  await act(async () => setEntries(plan.map((entry) => ({ ...entry, status: "completed" }))));
  expect(host.querySelectorAll('.cv-plan__item[data-status="completed"]').length).toBe(3);
  await act(async () => setEnded(true));
  expect(host.querySelector(".cv-plan")?.hasAttribute("data-ended")).toBe(true);
  expect(cardRenders).toBe(3);
  await act(async () => root.unmount());
});
