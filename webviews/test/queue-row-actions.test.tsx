// A queued prompt's row shows Steer, Delete and More (ChatGPT's order) in both arms of the
// `hover-actions` experiment (Leo, 2026-10-20); they are on its right-click menu and its keys
// (Return, Delete) too.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let main: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM(
    "<!doctype html><div class=acpmux-main><div class=acpmux-composer-box id=root></div></div>",
  );
  // JSDOM lays nothing out: the queue is 52px tall, and an observed element reports its size once.
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 52 });
  Object.assign(window, {
    ResizeObserver: class {
      constructor(private readonly report: () => void) {}
      observe() {
        this.report();
      }
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  main = window.document.querySelector<HTMLElement>(".acpmux-main")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a queued row shows Steer, Delete and More in both arms, and keeps its keys", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const t = translatorFor("en");
  const queued = [{ id: "q1", prompt: "Also update the comment above the retry loop" }];
  const draw = () =>
    act(async () =>
      root!.render(
        <ComposerQueue queue={queued as never} t={t} onRemove={async () => true} onChange={async () => true} />,
      ),
    );
  // The row's actions; its text is a button too (it opens the prompt whole), not an action.
  const labels = () =>
    [...main.querySelectorAll(".acpmux-queued .acpmux-queued-action")].map((button) =>
      button.getAttribute("aria-label"),
    );
  root = createRoot(main.querySelector<HTMLElement>("#root")!);
  await draw();
  expect(labels()).toEqual([t("composer.queueSteer"), t("composer.queueDelete"), t("composer.queueActions")]);
  const row = main.querySelector(".acpmux-queued")!;
  expect(row.getAttribute("aria-keyshortcuts")).toContain("Enter");
  expect(row.getAttribute("aria-keyshortcuts")).toContain("Delete");

  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "hover-actions": "all" };
  try {
    await act(async () => root!.unmount());
    root = createRoot(main.querySelector<HTMLElement>("#root")!);
    await draw();
    expect(labels()).toEqual([t("composer.queueSteer"), t("composer.queueDelete"), t("composer.queueActions")]);
  } finally {
    delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  }
});
