// A closed thought is titled by its first line as a reader sees it: a `**Heading**` summary shows
// its words, not its asterisks, and the whole line is a hover away when the row cuts it short.
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

test("a thought's title drops Markdown marks and keeps its full text as a tooltip", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ThoughtRow } = await import("../src/agent-session/acpmux/conversation/ThoughtRow");
  const item = { id: "t1", kind: "thought", text: "**Planning the `retry` fix**\n\nCheck the backoff first." };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<ThoughtRow item={item as never} />));
  const title = dom.window.document.querySelector<HTMLElement>(".cv-thought__title")!;
  expect(title.textContent).toBe("Planning the retry fix");
  expect(title.title).toBe("Planning the retry fix");
  act(() => root.unmount());
});

test("a thought's title keeps identifiers that carry underscores or asterisks", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ThoughtRow } = await import("../src/agent-session/acpmux/conversation/ThoughtRow");
  const item = { id: "t2", kind: "thought", text: "Checking `run_swift_tests.sh` in src/foo_bar and a*b*c" };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<ThoughtRow item={item as never} />));
  const title = dom.window.document.querySelector<HTMLElement>(".cv-thought__title")!;
  expect(title.textContent).toBe("Checking run_swift_tests.sh in src/foo_bar and a*b*c");
  act(() => root.unmount());
});
