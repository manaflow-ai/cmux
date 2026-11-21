// l10n-allow-file: test fixture text, not shipped UI.
// A long opened run scrolls in its own box of 14 lines, faded where more is hidden, as the
// Codex app draws it (Lucas, 2026-11-11; runScroll.experiment.ts). The `inline` arm draws every line
// in the transcript's one scroll, as before (Leo, #26696).
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RunScroll } from "./RunScroll";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

async function render(): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <RunScroll>
        <p>calls</p>
      </RunScroll>,
    );
  });
  return container;
}

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
  delete scope.cmuxExperiments;
});

/// The box's sizes, as a 220px box over 500px of lines scrolled to `top`.
function place(box: HTMLElement, top: number) {
  Object.defineProperty(box, "scrollHeight", { configurable: true, value: 500 });
  Object.defineProperty(box, "clientHeight", { configurable: true, value: 220 });
  box.scrollTop = top;
  box.dispatchEvent(new dom!.window.Event("scroll"));
}

test("a long run fades only where more is hidden: under it at the top, over it at the end", async () => {
  const container = await render();
  const box = container.querySelector<HTMLElement>(".cv-run-scroll")!;
  expect(box.textContent).toBe("calls");
  await act(async () => place(box, 0));
  expect([box.hasAttribute("data-fade-top"), box.hasAttribute("data-fade-bottom")]).toEqual([false, true]);
  await act(async () => place(box, 100));
  expect([box.hasAttribute("data-fade-top"), box.hasAttribute("data-fade-bottom")]).toEqual([true, true]);
  await act(async () => place(box, 280));
  expect([box.hasAttribute("data-fade-top"), box.hasAttribute("data-fade-bottom")]).toEqual([true, false]);
});

test("the inline arm draws the lines with no box of their own", async () => {
  scope.cmuxExperiments = { "run-scroll": "inline" };
  const container = await render();
  expect(container.querySelector(".cv-run-scroll")).toBeNull();
  expect(container.textContent).toBe("calls");
});
