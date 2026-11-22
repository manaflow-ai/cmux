// The hat's questions band mounts again on every chat switch (App.tsx keys it by the chat's id). Its
// "settled" mark (no easing before the band's first frame) is set on the band itself, never as
// state: a state set from the frame callback rendered the band again inside the switch's first
// frame, before it painted (bench/settled-page.bench.ts chat_switch). A band drawn later, once its
// questions arrive, is settled from its first commit.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act, Profiler } from "react";
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
    id: "perm-own",
    source: "own",
    prompt: "Which auth method should the API use?",
    answers: [{ id: "keys", label: "API keys" }],
    typed: true,
  },
];

const actions: HatQuestionActions = {
  answer: () => Promise.resolve(),
  reply: () => Promise.resolve(),
  type: () => undefined,
  showCard: () => undefined,
  open: () => undefined,
  dismiss: () => undefined,
};

/** Frame callbacks run only when `frame()` is called, as a browser runs them before its next paint. */
function setup() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  const callbacks = new Map<number, FrameRequestCallback>();
  let next = 0;
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
    requestAnimationFrame: (run: FrameRequestCallback) => {
      next += 1;
      callbacks.set(next, run);
      return next;
    },
    cancelAnimationFrame: (id: number) => callbacks.delete(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const frame = async () => {
    const due = [...callbacks.values()];
    callbacks.clear();
    await act(async () => {
      for (const run of due) run(0);
    });
  };
  const commits: string[] = [];
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  const draw = (questions: HatQuestion[]) =>
    act(async () => {
      root!.render(
        <Profiler id="hat" onRender={(_id, phase) => commits.push(phase)}>
          <HatQuestions questions={questions} actions={actions} look="band" />
        </Profiler>,
      );
    });
  return { container, frame, commits, draw };
}

test("a band mounted with its questions renders once through its first frame, and is settled after it", async () => {
  const { container, frame, commits, draw } = setup();
  await draw(QUESTIONS);
  const band = container.querySelector<HTMLElement>(".acpmux-hat-questions")!;
  expect(band).not.toBeNull();
  expect(band.hasAttribute("data-settled")).toBe(false);
  await frame();
  expect(band.hasAttribute("data-settled")).toBe(true);
  expect(commits).toEqual(["mount"]);
});

test("a band with no questions renders nothing more through its first frame", async () => {
  const { container, frame, commits, draw } = setup();
  await draw([]);
  await frame();
  expect(container.querySelector(".acpmux-hat-questions")).toBeNull();
  expect(commits).toEqual(["mount"]);
});

test("questions arriving after the first frame draw a band that is settled from its first commit", async () => {
  const { container, frame, draw } = setup();
  await draw([]);
  await frame();
  await draw(QUESTIONS);
  const band = container.querySelector<HTMLElement>(".acpmux-hat-questions")!;
  expect(band).not.toBeNull();
  expect(band.hasAttribute("data-settled")).toBe(true);
});
