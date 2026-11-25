// A key in the agent chat's prompt draws the composer, never the queued prompts above it, and lays
// nothing of them out (Leo, 2026-11-17: "man the difference typing on terminal vs gui is def
// noticeable rn"). The composer's text is its own state, so each key renders ComposerFrame; the
// queue took a new inline `onLeave` each time, was not memoised, and its layout effects ran after
// every render, each reading every row's box (fitList, the hold check, the refocus pass). With ten
// prompts queued, a key must render ComposerQueue 0 times and read no box inside its list.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { acpmuxPerf } from "../src/agent-session/acpmux/perf";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  acpmuxPerf.enabled = false;
  acpmuxPerf.resetRenders();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

const QUEUED = 10;
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
const queueList = () => host.querySelector<HTMLElement>("ol.acpmux-composer-queue");

test(`a key with ${QUEUED} prompts queued renders no queue row and reads no box in the queue`, async () => {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const sessionId = "queue-key";
  const snapshot = noChat([], {
    sessionId,
    isWorking: true,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    queue: Array.from({ length: QUEUED }, (_, index) => ({ id: `p-${index}`, prompt: `queued prompt ${index}` })),
  });
  const handle = createRef<ComposerHandle>();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        onQueueRemove={async () => true}
        onQueueChange={async () => true}
        onQueueCancelEdit={async () => true}
        handle={handle}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  await until(() => host.querySelectorAll(".acpmux-queued").length > 0, "the queue");
  await settle();
  const list = queueList();
  expect(list).not.toBeNull();

  // Every box read inside the queue's list (the list itself or a row), as the layout it forces.
  const reads: string[] = [];
  const proto = dom.window.Element.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: Element) {
    if (list!.contains(this)) reads.push(this.className);
    return original.call(this);
  };
  acpmuxPerf.enabled = true;
  acpmuxPerf.resetRenders();
  try {
    for (const letter of "abcde") {
      await act(async () => markdownField().insertTyped(letter));
      await settle();
    }
    await until(() => (host.querySelector('[role="combobox"]')?.textContent ?? "").includes("abcde"), "the keys");
    await settle();
  } finally {
    proto.getBoundingClientRect = original;
  }
  const renders = Object.fromEntries(acpmuxPerf.renders);
  // The composer draws for its text; the queue above it does not.
  expect(renders.composer ?? 0).toBeGreaterThan(0);
  expect({ queueRenders: renders["composer:queue"] ?? 0, queueBoxReads: reads.length }).toEqual({
    queueRenders: 0,
    queueBoxReads: 0,
  });
});
