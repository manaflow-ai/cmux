// The whole ask (G08; Leo, 2026-11-11, on a coordinator's [irreversible] deploy ask he could not
// read because its head and line were cut mid-word): the next-step card and the composer hat offer
// Show more only when part of the ask is cut, the click opens all of it in place, and the answers
// keep their order under the text. JSDOM has no layout, so the cut is stubbed through scrollHeight
// and scrollWidth on the parts that the CSS caps.
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NextStepCard } from "./NextStepCard";
import { nextStepAsk } from "./nextStepAsk";
import { HatQuestions, hasCutText, type HatQuestionActions } from "../question/HatQuestions";
import type { HatQuestion } from "../question/hatModel";

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

/// A DOM whose elements matching `cut` report more content than room (what a line clamp or an
/// ellipsis leaves), unless an ancestor carries `data-whole`.
function setup(cut: string) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  const { HTMLElement } = dom.window;
  const clipped = (element: Element) => element.matches(cut) && !element.closest("[data-whole]");
  Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get(this: Element) {
      return clipped(this) ? 80 : 20;
    },
  });
  Object.defineProperty(HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 20 });
  Object.defineProperty(HTMLElement.prototype, "scrollWidth", { configurable: true, get: () => 100 });
  Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 100 });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement,
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
  return dom.window.document.getElementById("root")!;
}

const LONG =
  "Done.\n\n[irreversible] Should I promote tonight's nightly to everyone now? It rewrites every saved chat and cannot be rolled back.";

async function renderCard(cut: string) {
  const container = setup(cut);
  const ask = nextStepAsk(LONG)!;
  await act(async () => {
    root = createRoot(container);
    root.render(<NextStepCard ask={ask} onAnswer={() => Promise.resolve()} />);
  });
  return container;
}

const order = (container: HTMLElement) =>
  Array.from(container.querySelectorAll(".acpmux-next-step > *")).map((element) => element.className);

test("a next-step ask that fits shows whole, with no Show more", async () => {
  const card = await renderCard(".nothing-is-cut");
  expect(card.querySelector(".acpmux-next-step__question")?.textContent).toBe(
    "Should I promote tonight's nightly to everyone now?",
  );
  expect(card.querySelector(".acpmux-next-step__more")).toBeNull();
});

test("a next-step ask past its cap offers Show more, which opens it in place above the answers", async () => {
  const card = await renderCard(".acpmux-next-step__question");
  const more = card.querySelector<HTMLButtonElement>(".acpmux-next-step__more")!;
  expect(more).not.toBeNull();
  expect(more.getAttribute("aria-expanded")).toBe("false");
  const before = order(card);
  expect(before).toEqual([
    "acpmux-question-bar acpmux-next-step__bar",
    "acpmux-next-step__text",
    "acpmux-next-step__more",
    "acpmux-next-step__answers",
    "acpmux-question-footer acpmux-next-step__other",
  ]);
  await act(async () => more.click());
  expect(card.querySelector(".acpmux-next-step__text")?.hasAttribute("data-whole")).toBe(true);
  expect(more.getAttribute("aria-expanded")).toBe("true");
  expect(order(card)).toEqual(before);
  const answers = Array.from(card.querySelectorAll(".acpmux-next-step__answer .acpmux-next-step__label")).map(
    (label) => label.textContent,
  );
  expect(answers).toEqual(["Yes", "Not now"]);
});

test("a cut tail alone offers Show more too", async () => {
  const card = await renderCard(".acpmux-next-step__detail");
  expect(card.querySelector(".acpmux-next-step__more")).not.toBeNull();
});

const DEPLOY: HatQuestion = {
  id: "acpmux:perm-deploy",
  source: "child",
  sessionId: "coord",
  who: "From claude-sr2-coord: coord-deputy needs a decision before the nightly promote window closes",
  about: "Production deploy",
  prompt: "[irreversible] Promote tonight's nightly now?",
  detail: "The canary group ran it for six hours with no crash reports.",
  answers: [{ id: "Promote now", label: "Promote now" }],
  typed: true,
};

async function renderHat(cut: string) {
  const container = setup(cut);
  const actions: HatQuestionActions = {
    answer: () => Promise.resolve(),
    reply: () => Promise.resolve(),
    type: () => undefined,
    showCard: () => undefined,
    open: () => undefined,
    dismiss: () => undefined,
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<HatQuestions questions={[DEPLOY]} actions={actions} look="band" />);
  });
  return container;
}

test("the hat offers More when who asks is cut, though the question fits, and More opens the whole ask", async () => {
  const band = await renderHat(".acpmux-hat-questions__who");
  const more = band.querySelector<HTMLButtonElement>(".acpmux-hat-questions__more")!;
  expect(more).not.toBeNull();
  await act(async () => more.click());
  expect(band.querySelector(".acpmux-hat-questions__question")?.hasAttribute("data-whole")).toBe(true);
  expect(band.querySelector(".acpmux-hat-questions__prompt")?.hasAttribute("data-whole")).toBe(true);
});

test("the hat offers More when only the line under the question is cut", async () => {
  const band = await renderHat(".acpmux-hat-questions__detail");
  expect(band.querySelector(".acpmux-hat-questions__more")).not.toBeNull();
});

test("the hat offers no More when nothing of the ask is cut", async () => {
  const band = await renderHat(".nothing-is-cut");
  expect(band.querySelector(".acpmux-hat-questions__more")).toBeNull();
  expect(hasCutText(band.querySelector<HTMLElement>(".acpmux-hat-questions__question")!)).toBe(false);
});

test("an opened hat shrinks and scrolls in a short pane so its answers are never cut off", async () => {
  const band = await renderHat(".acpmux-hat-questions__prompt");
  // The hat sits inside the test's container: look down for it (closest() looks up and found none,
  // so the old line read the container's own attribute, which never changes).
  const root = band.querySelector<HTMLElement>(".acpmux-hat-questions")!;
  expect(root).not.toBeNull();
  expect(root.hasAttribute("data-whole")).toBe(false);
  await act(async () => band.querySelector<HTMLElement>(".acpmux-hat-questions__more")!.click());
  expect(root.hasAttribute("data-whole")).toBe(true);
  const css = await Bun.file(new URL("../question/hatQuestions.css", import.meta.url)).text();
  const rule = css.match(/\.acpmux-hat-questions\[data-whole\]\s*\{([^}]*)\}/)?.[1] ?? "";
  expect(rule).toContain("flex: 0 1 auto");
  expect(rule).toContain("overflow-y: auto");
});
