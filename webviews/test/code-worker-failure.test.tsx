// A bundled code card starts its worker eagerly, but a worker that fails after the card mounted
// must leave readable plain code. Exercise the real watchdog failure signal without starting a
// grammar or letting Pierre tokenize on this test's main thread.
import { afterAll, afterEach, beforeAll, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { WatchedWorker } from "../src/agent-session/acpmux/conversation/highlightWatchdog";

let creates = 0;
let renders = 0;
let cleanups = 0;
let poolWorks = true;
const pool = { isWorkingPool: () => poolWorks };
await mock.module("../src/agent-session/acpmux/conversation/highlightPool", () => ({
  paneHighlightPool: () => pool,
  onHighlightTimeout: () => () => {},
}));
await mock.module("@pierre/diffs", () => ({
  DIFFS_TAG_NAME: "diffs-container",
  registerCustomTheme: () => {},
  File: class {
    options: Record<string, unknown>;
    constructor(options: Record<string, unknown>) {
      creates += 1;
      this.options = options;
    }
    setOptions(options: Record<string, unknown>) {
      this.options = options;
    }
    setThemeType() {}
    render({ fileContainer }: { fileContainer: HTMLElement }) {
      renders += 1;
      const shadow = fileContainer.shadowRoot ?? fileContainer.attachShadow({ mode: "open" });
      shadow.innerHTML = "<div data-line>colored code</div>";
    }
    cleanUp() {
      cleanups += 1;
    }
  },
}));

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "location",
  "navigator",
  "HTMLElement",
  "customElements",
  "MutationObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.agent/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    requestAnimationFrame: (run: FrameRequestCallback) =>
      setTimeout(() => run(performance.now()), 0) as unknown as number,
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = document.querySelector<HTMLElement>("#root")!;
});
afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  delete document.documentElement.dataset.cmuxHighlightWorker;
  delete document.documentElement.dataset.agentMotion;
  creates = renders = cleanups = 0;
  poolWorks = true;
});
afterAll(() => {
  mock.restore();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
async function draw(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}
async function failWorker() {
  const worker = new EventTarget();
  const watched = new WatchedWorker(
    () => Object.assign(worker, { postMessage() {}, terminate() {} }) as unknown as Worker,
    {
      onStartFailure: () => {
        document.documentElement.dataset.cmuxHighlightWorker = "failed";
      },
    },
  );
  watched.postMessage({ type: "initialize", id: "setup" });
  await act(async () => worker.dispatchEvent(new Event("error")));
  watched.terminate();
}

test("a mounted highlighted card drops Pierre on worker failure and can recover on ready", async () => {
  const { HighlightedCode } = await import("../src/agent-session/acpmux/conversation/HighlightedCode");
  await draw(<HighlightedCode code="const first = 1;" lang="ts" />);
  expect(creates).toBe(1);
  expect(renders).toBe(1);
  await failWorker();
  expect(host.querySelector(".cv-codeblock--plain")).not.toBeNull();
  expect(host.querySelector("diffs-container")).toBeNull();
  expect(cleanups).toBe(1);
  await draw(<HighlightedCode code="const next = 2;" lang="ts" />);
  expect(renders).toBe(1);
  expect(host.textContent).toContain("const next = 2;");
  await act(async () => {
    document.documentElement.dataset.cmuxHighlightWorker = "ready";
  });
  expect(creates).toBe(2);
  expect(renders).toBe(2);
  await act(async () => root!.unmount());
  root = undefined;
  expect(cleanups).toBe(2);
  await act(async () => {
    document.documentElement.dataset.cmuxHighlightWorker = "failed";
  });
  expect(creates).toBe(2);
});

test("a streaming handoff stays readable when its eager worker fails after mount", async () => {
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { loadHighlightedCode } = await import("../src/agent-session/acpmux/conversation/CodeBlock");
  await loadHighlightedCode();
  document.documentElement.dataset.agentMotion = "off";
  await draw(<Markdown streaming>{"```ts\nconst value = 3;\n```\n\nStill arriving"}</Markdown>);
  expect(creates).toBe(1);
  await failWorker();
  expect(host.querySelector("diffs-container")).toBeNull();
  expect(host.textContent).toContain("const value = 3;");
  expect(cleanups).toBe(1);
  await draw(<Markdown>{"```ts\nconst value = 3;\n```\n\nStill arriving"}</Markdown>);
  expect(renders).toBe(1);
});

test("another worker's ready marker never reuses a failed pool", async () => {
  const { HighlightedCode } = await import("../src/agent-session/acpmux/conversation/HighlightedCode");
  await draw(<HighlightedCode code="const value = 4;" lang="ts" />);
  poolWorks = false;
  await failWorker();
  await act(async () => {
    document.documentElement.dataset.cmuxHighlightWorker = "ready";
  });
  expect(host.querySelector("diffs-container")).toBeNull();
  expect(renders).toBe(1);
});
