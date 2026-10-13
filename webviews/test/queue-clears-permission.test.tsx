// A queued prompt over a permission question (dogfood run, hq #1893): the queue lies over the
// transcript's foot by design, but it also covered the Tool permissions card's Allow and Deny
// buttons. The queue now publishes its height on the chat (--acpmux-queue-space), which the
// permission panel keeps clear, and takes it back when the queue empties.
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

test("a queued prompt reserves its height on the chat, and gives it back when the queue empties", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
  const t = translatorFor("en");
  const queued = [{ id: "q1", prompt: "Also update the comment above the retry loop" }];
  root = createRoot(main.querySelector<HTMLElement>("#root")!);
  await act(async () => root!.render(<ComposerQueue queue={queued as never} t={t} />));
  expect(main.style.getPropertyValue("--acpmux-queue-space")).toBe("52px");

  await act(async () => root!.render(<ComposerQueue queue={[]} t={t} />));
  expect(main.style.getPropertyValue("--acpmux-queue-space")).toBe("");
});
