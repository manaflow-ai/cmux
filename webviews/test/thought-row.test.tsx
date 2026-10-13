// A thought shows in full on its row (Leo 2026-10-13): every line of it, wrapped, after a muted
// "Thought". Nothing to open and no tooltip: a one-line title had hidden the rest in one.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

test("a thought shows its whole text, with nothing to open and no tooltip", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ThoughtRow } = await import("../src/agent-session/acpmux/conversation/ThoughtRow");
  const text = "**Planning the `retry` fix**\n\nCheck the backoff first, then the 429 path.";
  const item = { id: "t1", kind: "thought", text };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<ThoughtRow item={item as never} />));
  const row = dom.window.document.querySelector<HTMLElement>(".cv-thought")!;
  expect(row.textContent).toContain("Check the backoff first, then the 429 path.");
  expect(row.querySelector(".cv-thought__text")?.textContent).toBe(text);
  expect(row.closest("button") ?? row.querySelector("button")).toBeNull();
  expect(row.querySelector("[title]")).toBeNull();
  expect(row.hasAttribute("aria-expanded")).toBe(false);
  act(() => root.unmount());
});
