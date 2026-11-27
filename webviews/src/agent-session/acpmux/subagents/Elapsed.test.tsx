import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { subscribePageSecond } from "../../../ui/pageClock";
import type { Subagent } from "./subagent";
import { SubagentElapsed } from "./Elapsed";
import { settleReact } from "../../../../test/support/domTeardown";

const STARTED = Date.UTC(2026, 10, 27, 18, 0, 0);
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const realNow = Date.now;
let now = STARTED;
let dom: JSDOM | undefined;
let root: Root | undefined;

const agent = (state: string): Subagent => ({
  id: "agent-1",
  parent: null,
  name: "Clock",
  state,
  startedAt: STARTED,
});

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const nextSecond = () =>
  new Promise<void>((resolve) => {
    let calls = 0;
    const stop = subscribePageSecond(() => {
      if (++calls < 2) return;
      queueMicrotask(stop);
      resolve();
    });
  });

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
  Date.now = realNow;
});

test("a running subagent clock updates its leaf without re-rendering the row parent", async () => {
  now = STARTED + 2_000;
  Date.now = () => now;
  let parentRenders = 0;
  function Parent() {
    parentRenders += 1;
    return (
      <div data-parent>
        <SubagentElapsed agent={agent("running")} clock="test-clock" />
      </div>
    );
  }

  const container = await render(<Parent />);
  expect(container.querySelector(".test-clock")?.textContent).toBe("2s");
  expect(parentRenders).toBe(1);

  now += 1_000;
  await act(nextSecond);
  expect(container.querySelector(".test-clock")?.textContent).toBe("3s");
  expect(parentRenders).toBe(1);
});

test("a subagent that ended without a measurable span keeps the unknown time blank", async () => {
  now = STARTED + 1_000;
  Date.now = () => now;
  const container = await render(
    <SubagentElapsed agent={{ ...agent("completed"), endedAt: STARTED }} clock="test-clock" />,
  );
  expect(container.querySelector(".test-clock")).toBeNull();
});
