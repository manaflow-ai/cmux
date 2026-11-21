// The agent's todo list (conversation/PlanList.tsx) redraws only the step that changed: each `plan`
// update sends every entry as a fresh object, and a step whose content and status did not change
// renders 0 times, also when the list reorders (each step keyed by its content, not its place).
// Counted from React's commits (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxPlanEntry } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    HTMLElement: window.HTMLElement,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(async () => {
  await act(async () => root?.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const N = 50;
/// Fresh entry objects, as each wire update brings them.
const plan = (status: (i: number) => AcpmuxPlanEntry["status"], order = (i: number) => i): AcpmuxPlanEntry[] =>
  Array.from({ length: N }, (_, i) => ({ content: `Step ${order(i)}`, status: status(order(i)) }));

test("one step's change renders that step only; a resend or a reorder renders none", async () => {
  const { PlanList } = await import("../src/agent-session/acpmux/conversation/PlanList");
  const host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  const first = (i: number): AcpmuxPlanEntry["status"] => (i < 10 ? "completed" : i === 10 ? "in_progress" : "pending");
  await act(async () => root!.render(<PlanList entries={plan(first)} />));
  expect(host.querySelectorAll("li.cv-plan__item").length).toBe(N);
  // Rows drawn per update: a row component's renders where each step is one, else (rows drawn inline
  // in the list) every row of each render of the list.
  const inline = !("PlanItem" in rowRenders.all());
  const drawn = () => (inline ? rowRenders.count("PlanList") * N : rowRenders.count("PlanItem"));

  rowRenders.reset();
  const next = (i: number): AcpmuxPlanEntry["status"] => (i <= 10 ? "completed" : i === 11 ? "in_progress" : "pending");
  // Steps 10 and 11 change status; the other 48 do not.
  await act(async () => root!.render(<PlanList entries={plan(next)} />));
  console.log(`PLAN-LIST two steps' status change: rows drawn=${drawn()}`);
  expect(drawn()).toBe(2);

  rowRenders.reset();
  await act(async () => root!.render(<PlanList entries={plan(next)} />));
  console.log(`PLAN-LIST same entries resent: rows drawn=${drawn()}`);
  expect(drawn()).toBe(0);

  rowRenders.reset();
  const swap = (i: number) => (i === 20 ? 30 : i === 30 ? 20 : i);
  await act(async () => root!.render(<PlanList entries={plan(next, swap)} />));
  console.log(`PLAN-LIST two steps swapped: rows drawn=${drawn()}`);
  expect(drawn()).toBe(0);
  const texts = [...host.querySelectorAll("li.cv-plan__item .cv-plan__text")].map((node) => node.textContent);
  expect(texts[20]).toBe("Step 30");
  expect(texts[30]).toBe("Step 20");
  // The step at work still spins and says its state.
  const working = host.querySelector('li.cv-plan__item[data-status="in_progress"]')!;
  expect(working.querySelector(".cv-plan__text")!.textContent).toBe("Step 11");
});
