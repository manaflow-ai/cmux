// l10n-allow-file: test fixture questions and todo items, not shipped UI.
// The answered question card and the todo list sit in a turn while the agent's reply streams below
// them. Each token re-renders the turn around them; neither card may redraw for it (Leo,
// 2026-10-21: no new O(rows) work per token in the transcript path). Both are memoized on their
// immutable inputs: the decided question record and the plan's entries.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act, Profiler, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxPlanEntry } from "../model";
import type { AgentQuestion } from "../question/model";
import { QuestionCard } from "../question/QuestionCard";
import { PlanList } from "./PlanList";

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

/// Commits of each card while `TOKENS` tokens stream, and of the turn around them.
async function stream(cards: (count: (id: string) => void) => ReactNode) {
  const commits: Record<string, number> = {};
  const count = (id: string) => (commits[id] = (commits[id] ?? 0) + 1);
  let setTokens: (token: number) => void = () => {};
  const root: Root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root.render(
      <Profiler id="turn" onRender={() => count("turn")}>
        <Turn push={(next) => (setTokens = next)} cards={() => cards(count)} />
      </Profiler>,
    ),
  );
  for (let token = 1; token <= TOKENS; token++) await act(async () => setTokens(token));
  const reply = dom.window.document.querySelector(".reply")?.textContent ?? "";
  await act(async () => root.unmount());
  return { commits, reply };
}

const card = (id: string, count: (id: string) => void, node: ReactNode) => (
  <Profiler id={id} onRender={() => count(id)}>
    {node}
  </Profiler>
);

test("streaming tokens never redraw an answered or skipped question or the todo list", async () => {
  const { commits, reply } = await stream((count) => (
    <>
      {card("answered", count, <QuestionCard question={answered} onReply={ignoreReply} />)}
      {card("skipped", count, <QuestionCard question={skipped} onReply={ignoreReply} />)}
      {card("plan", count, <PlanList entries={plan} />)}
    </>
  ));
  expect(reply.split(" ").length - 1).toBe(TOKENS);
  // The turn commits once per token; each card only on its first mount.
  expect(commits.turn).toBe(TOKENS + 1);
  expect(commits).toMatchObject({ answered: 1, skipped: 1, plan: 1 });
});

test("a plan update or the turn's end still redraws the list", async () => {
  let setEntries: (entries: AcpmuxPlanEntry[]) => void = () => {};
  let setEnded: (ended: boolean) => void = () => {};
  const commits: number[] = [];
  function Live() {
    const [entries, entriesSetter] = useState(plan);
    const [ended, endedSetter] = useState(false);
    setEntries = entriesSetter;
    setEnded = endedSetter;
    return (
      <Profiler id="plan" onRender={() => commits.push(1)}>
        <PlanList entries={entries} ended={ended} />
      </Profiler>
    );
  }
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(<Live />));
  await act(async () => setEntries(plan.map((entry) => ({ ...entry, status: "completed" }))));
  expect(host.querySelectorAll('.cv-plan__item[data-status="completed"]').length).toBe(3);
  await act(async () => setEnded(true));
  expect(host.querySelector(".cv-plan")?.hasAttribute("data-ended")).toBe(true);
  expect(commits.length).toBe(3);
  await act(async () => root.unmount());
});
