import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "location",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IntersectionObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
  "Worker",
];
const saved = Object.fromEntries(names.map((key) => [key, globals[key]]));
const inert = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

class SlowWorker extends EventTarget {
  static all: SlowWorker[] = [];
  readonly messages: any[] = [];
  terminated = false;

  constructor() {
    super();
    SlowWorker.all.push(this);
  }

  postMessage(message: unknown) {
    this.messages.push(message);
    const request = message as { type?: string; id?: string };
    if (request.type === "initialize") {
      queueMicrotask(() =>
        this.dispatchEvent(
          new MessageEvent("message", { data: { type: "success", id: request.id, requestType: "initialize" } }),
        ),
      );
    }
  }

  terminate() {
    this.terminated = true;
  }

  finishDiffs() {
    for (const message of this.messages) {
      if (message.type !== "diff") continue;
      this.dispatchEvent(
        new MessageEvent("message", {
          data: { type: "success", id: message.id, requestType: "diff", result: {}, options: {} },
        }),
      );
    }
  }
}

Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  location: dom.window.location,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: inert,
  ResizeObserver: inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
  Worker: SlowWorker,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter((key) =>
  /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key),
);
const savedClasses = new Map(domClasses.map((key) => [key, Object.getOwnPropertyDescriptor(globals, key)]));
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];

afterAll(() => {
  Object.assign(globals, saved);
  for (const [key, descriptor] of savedClasses) {
    if (descriptor) Object.defineProperty(globals, key, descriptor);
    else delete globals[key];
  }
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../DiffPanel");
const { turnFiles } = await import("../diff");
const { EditDiff } = await import("../conversation/EditDiff");

const files = turnFiles([
  {
    id: "activity-1",
    version: 1,
    at: 1,
    kind: "activity",
    items: [
      {
        kind: "tool",
        text: "Edit",
        tool: {
          id: "t1",
          title: "Edit",
          kind: "edit",
          status: "completed",
          diffs: [{ path: "/repo/a.ts", oldText: "const a = 1\n", newText: "const a = 2\n", line: 1 }],
        },
      },
    ],
  },
]);

describe("agent diff worker rendering", () => {
  test("paints plain lines while the worker is still highlighting", async () => {
    SlowWorker.all = [];
    const root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () =>
      root.render(
        createElement(
          "div",
          null,
          createElement(DiffPanel, { files, onClose: () => {} }),
          createElement(EditDiff, { file: files[0]! }),
        ),
      ),
    );
    for (
      let tries = 0;
      tries < 100 && !SlowWorker.all.some((worker) => worker.messages.some((m) => m.type === "diff"));
      tries += 1
    )
      await act(() => new Promise((resolve) => setTimeout(resolve, 5)));

    expect(SlowWorker.all.some((worker) => worker.messages.some((m) => m.type === "diff"))).toBe(true);
    expect(
      new Set(
        SlowWorker.all
          .flatMap((worker) => worker.messages)
          .filter((message) => message.type === "initialize")
          .map((message) => message.renderOptions.lineDiffType),
      ),
    ).toEqual(new Set(["none", "word-alt"]));
    expect(
      SlowWorker.all
        .flatMap((worker) => worker.messages)
        .filter((message) => message.type === "initialize")
        .every((message) =>
          message.resolvedLanguages?.some((language: { name: string }) => language.name === "typescript"),
        ),
    ).toBe(true);
    expect(dom.window.document.querySelectorAll("diffs-container")).toHaveLength(2);
    expect(
      [...dom.window.document.querySelectorAll("diffs-container")].every(
        (container) => container.shadowRoot?.querySelector("[data-line]") != null,
      ),
    ).toBe(true);
    // A delayed worker response proves this component did not fall back to Pierre's synchronous
    // highlighter: the first paint is still present while no worker has returned colored tokens.
    expect(
      [...dom.window.document.querySelectorAll("diffs-container")].every(
        (container) => container.shadowRoot?.querySelector("[data-token]") == null,
      ),
    ).toBe(true);
    await act(async () => root.unmount());
    for (const worker of SlowWorker.all) worker.finishDiffs();
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  });
});
