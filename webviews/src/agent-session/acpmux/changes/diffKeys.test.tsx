import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { stepTarget } from "./diffNavigation";

describe("stepTarget", () => {
  const tops = [0, 100, 200];
  test("steps to the first target below the line, or the last one above it", () => {
    expect([stepTarget(tops, 50, 1), stepTarget(tops, 150, -1)]).toEqual([1, 1]);
  });
  test("a target at the line is the current one, so a step moves past it", () => {
    expect([stepTarget(tops, 100, 1), stepTarget(tops, 100.5, -1)]).toEqual([2, 0]);
  });
  test("past the last target, or before the first, there is nowhere to go", () => {
    expect([stepTarget(tops, 200, 1), stepTarget(tops, 0, -1), stepTarget([], 0, 1)]).toEqual([
      undefined,
      undefined,
      undefined,
    ]);
  });
});

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IntersectionObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(names.map((key) => [key, globals[key]]));
const inert = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: inert,
  ResizeObserver: inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// @pierre/diffs and @pierre/trees reach for DOM classes by their global names.
// Another test file may have set its own; each is put back as it was afterwards.
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
const { CURRENT_CHANGE } = await import("./useDiffKeys");

/// jsdom does no layout. Each file section sits 1000px below the last; a diff row sits 20px
/// below the row before it, 100px into its section. The body scrolls a 600px viewport.
const VIEWPORT = 600;
const prototype = dom.window.Element.prototype;
const scrollTops = new WeakMap<Element, number>();
const isBody = (node: Element) => node.classList.contains("acpmux-diff-body");
const body = () => dom.window.document.querySelector(".acpmux-diff-body")!;
function position(node: Element): number {
  const sections = [...dom.window.document.querySelectorAll(".acpmux-diff-file")];
  const section = sections.indexOf(node);
  if (section !== -1) return section * 1000;
  const root = node.getRootNode();
  if (!(root instanceof dom.window.ShadowRoot)) return 0;
  const host = sections.findIndex((candidate) => candidate.contains(root.host));
  return host * 1000 + 100 + [...root.querySelectorAll("[data-line]")].indexOf(node) * 20;
}
prototype.getBoundingClientRect = function (this: Element) {
  const top = isBody(this) ? 0 : position(this) - (scrollTops.get(body()) ?? 0);
  return { top, bottom: top, left: 0, right: 0, width: 0, height: 0, x: 0, y: top, toJSON: () => ({}) };
};
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get(this: Element) {
    return isBody(this) ? VIEWPORT : 0;
  },
});
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: Element) {
    return scrollTops.get(this) ?? 0;
  },
  set(this: Element, value: number) {
    scrollTops.set(this, value);
  },
});
/// The files revealed, in order; revealing a file scrolls its header to the top.
const revealed: string[] = [];
dom.window.HTMLElement.prototype.scrollIntoView = function (this: HTMLElement) {
  revealed.push(this.dataset.path ?? "");
  scrollTops.set(body(), position(this));
};

/// Two files: a.ts changes twice with unchanged lines between, b.ts once.
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
          diffs: [
            { path: "/repo/a.ts", oldText: "a\nb\nc\nd\ne\nf\ng\n", newText: "A\nb\nc\nd\ne\nf\nG\n", line: 1 },
            { path: "/repo/b.ts", oldText: "one\ntwo\n", newText: "one\n2\n", line: 1 },
          ],
        },
      },
    ],
  },
]);

async function mount() {
  revealed.length = 0;
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  await act(async () => root.render(createElement(DiffPanel, { files, onClose: () => {} })));
  const painted = () =>
    [...document.querySelectorAll(".acpmux-diff-file diffs-container")].every(
      (container) => container.shadowRoot?.querySelector("[data-line]") != null,
    ) && document.querySelectorAll(".acpmux-diff-file diffs-container").length === 2;
  for (let tries = 0; tries < 100 && !painted(); tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  scrollTops.set(body(), 0);
  revealed.length = 0;
  const press = (key: string, target: Element = document.querySelector(".acpmux-diff-back")!) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
  const current = () =>
    [...document.querySelectorAll(".acpmux-diff-file diffs-container")].flatMap((container) =>
      [...container.shadowRoot!.querySelectorAll(`[${CURRENT_CHANGE}]`)].map((row) => position(row)),
    );
  return { document, press, current, unmount: () => act(async () => root.unmount()) };
}

describe("changes view keys", () => {
  test("j and k move between files as picking them in the tree does", async () => {
    const view = await mount();
    try {
      await view.press("j");
      await view.press("j");
      await view.press("k");
      await view.press("k");
      expect(revealed).toEqual(["/repo/b.ts", "/repo/a.ts"]);
    } finally {
      await view.unmount();
    }
  });

  test("n and p step through each run of changed lines, marking where they stop", async () => {
    const view = await mount();
    try {
      // The reading line is 30% down the 600px body, at 180px.
      const line = VIEWPORT * 0.3;
      const steps: { current: number[]; top: number }[] = [];
      const record = () => steps.push({ current: view.current(), top: scrollTops.get(body())! + line });
      await view.press("n");
      record();
      await view.press("n");
      record();
      await view.press("n");
      record();
      await view.press("p");
      record();
      // Each stop is one row, marked alone, and scrolled to the reading line.
      expect(steps.every((step) => step.current.length === 1 && step.current[0] === step.top)).toBe(true);
      const stops = steps.map((step) => step.current[0]!);
      // a.ts's two runs, then b.ts's, then back to a.ts's second.
      expect(stops[0]! < stops[1]! && stops[1]! < 1000 && stops[2]! > 1000 && stops[3] === stops[1]).toBe(true);
    } finally {
      await view.unmount();
    }
  });

  test("after the reader scrolls away, n starts from the first change in view", async () => {
    const view = await mount();
    try {
      await view.press("n");
      // The reader scrolls down to b.ts by hand.
      scrollTops.set(body(), 1050);
      await view.press("n");
      expect(view.current()).toEqual([1120]);
    } finally {
      await view.unmount();
    }
  });

  test("the keys type normally in a field, and leave modified keys alone", async () => {
    const view = await mount();
    try {
      const field = view.document.createElement("input");
      view.document.querySelector(".acpmux-diff-header")!.append(field);
      await view.press("j", field);
      await act(async () => {
        view.document
          .querySelector(".acpmux-diff-back")!
          .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "n", metaKey: true, bubbles: true }));
      });
      expect([revealed, view.current()]).toEqual([[], []]);
    } finally {
      await view.unmount();
    }
  });

  test("the keys are drawn in a footer while there are changes to read", async () => {
    const view = await mount();
    try {
      expect(view.document.querySelector(".acpmux-diff-keys")?.textContent).toBe("jkfiles·npchanges·escback");
    } finally {
      await view.unmount();
    }
  });
});
