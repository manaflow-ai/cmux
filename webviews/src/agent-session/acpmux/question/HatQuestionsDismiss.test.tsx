// The composer hat's × and Escape (Leo, 2026-11-11: "there's no close button :("): each puts the
// shown question away through `actions.dismiss`, the × holds its room in the head at rest (so a
// hover moves nothing), and a started chat's name keeps the head's line, its question under it.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HatQuestions, type HatQuestionActions } from "./HatQuestions";
import type { HatQuestion } from "./hatModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

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
});

const QUESTIONS: HatQuestion[] = [
  {
    id: "acpmux:perm-child",
    source: "child",
    sessionId: "child",
    who: "From claude-sr2-coord: coord-deputy left real product asks open",
    prompt: "[irreversible] cosmic-gray's uplink is still saturated; move the builds?",
    answers: [],
    typed: false,
  },
  {
    id: "perm-own",
    source: "own",
    prompt: "Which auth method should the API use?",
    answers: [{ id: "keys", label: "API keys" }],
    typed: true,
  },
];

async function render(dismissed: HatQuestion[]): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    requestAnimationFrame: (run: FrameRequestCallback) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const actions: HatQuestionActions = {
    answer: () => Promise.resolve(),
    reply: () => Promise.resolve(),
    type: () => undefined,
    showCard: () => undefined,
    open: () => undefined,
    dismiss: (question) => dismissed.push(question),
  };
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(<HatQuestions questions={QUESTIONS} actions={actions} look="band" />);
  });
  return container;
}

test("the × puts the shown question away, and is named for what it does", async () => {
  const dismissed: HatQuestion[] = [];
  const band = await render(dismissed);
  const close = band.querySelector<HTMLButtonElement>(".acpmux-hat-questions__head .acpmux-hat-questions__dismiss")!;
  expect(close).not.toBeNull();
  expect(close.getAttribute("aria-label")).toBe("Dismiss");
  expect(close.dataset.reveal).toBe("hover");
  await act(async () => close.click());
  expect(dismissed.map((question) => question.id)).toEqual(["acpmux:perm-child"]);
});

test("Escape with the focus in the band puts the shown question away", async () => {
  const dismissed: HatQuestion[] = [];
  const band = await render(dismissed);
  const open = band.querySelector<HTMLButtonElement>(".acpmux-hat-questions__quiet")!;
  await act(async () => {
    open.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(dismissed.map((question) => question.id)).toEqual(["acpmux:perm-child"]);
});

test("a started chat's name has the head's line, its question the line under it", async () => {
  const band = await render([]);
  const head = band.querySelector(".acpmux-hat-questions__head")!;
  expect(head.querySelector(".acpmux-hat-questions__who")?.textContent).toContain("claude-sr2-coord");
  expect(head.querySelector(".acpmux-hat-questions__prompt")).toBeNull();
  expect(
    band.querySelector(".acpmux-hat-questions__question[data-asker] > .acpmux-hat-questions__words")?.textContent,
  ).toContain("cosmic-gray");
  // The head's order: the mark, the name, the pager, then the ×, which is always laid out.
  const order = [...head.children].map((child) => child.className.split(" ")[0]);
  expect(order.at(-1)).toBe("ui-button");
  expect(order.at(-2)).toBe("acpmux-hat-questions__pager");
});
