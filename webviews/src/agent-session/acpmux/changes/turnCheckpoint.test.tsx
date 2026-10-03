import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
class Inert {
  observe() {}
  unobserve() {}
  disconnect() {}
}
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: Inert,
  ResizeObserver: Inert,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { DiffPanel } = await import("../DiffPanel");
const { readTurnCheckpoint } = await import("./model");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 50 && !done(); tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};

test("a turn summary's checkpoints read as acpmux recorded them", () => {
  expect(readTurnCheckpoint({ status: "completed" })).toBeUndefined();
  expect(readTurnCheckpoint({ checkpointId: "ckpt_a", endCheckpointId: "ckpt_b" })).toEqual({
    from: "ckpt_a",
    to: "ckpt_b",
  });
  expect(readTurnCheckpoint({ checkpointId: "ckpt_a" })).toEqual({ from: "ckpt_a" });
  expect(readTurnCheckpoint({ checkpointId: null, checkpointError: "timed_out" })).toEqual({
    from: null,
    reason: "timed_out",
  });
  expect(readTurnCheckpoint({ checkpointId: null })).toEqual({ from: null });
});

test("a turn without a starting checkpoint says its changes are unavailable and asks nothing", async () => {
  const asked: string[] = [];
  const source = {
    diff: (scope: string) => (asked.push(scope), Promise.resolve({ files: [] })),
    checkpointDiff: (from: string) => (asked.push(from), Promise.resolve({ files: [] })),
  };
  await act(async () =>
    root.render(
      createElement(DiffPanel, {
        files: [],
        onClose: () => {},
        source,
        turnCheckpoint: { from: null, reason: "timed_out" },
      }),
    ),
  );
  const state = doc.querySelector('[data-state="unavailable"]');
  expect(state?.querySelector("strong")?.textContent).toBe("Changes unavailable for this turn");
  expect(asked).toEqual([]);
});

test("a turn with checkpoints reads its changes between them from the session host", async () => {
  const asked: [string, string | undefined][] = [];
  const source = {
    diff: () => Promise.reject(new Error("not this scope")),
    checkpointDiff: (from: string, to?: string) => {
      asked.push([from, to]);
      return Promise.resolve({
        root: "/repo",
        from,
        to,
        files: [{ path: "src/a.ts", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b\n" }],
        additions: 1,
        deletions: 0,
        total_files: 1,
        files_omitted: 0,
      });
    },
  };
  await act(async () =>
    root.render(
      createElement(DiffPanel, {
        files: [],
        onClose: () => {},
        source,
        turnCheckpoint: { from: "ckpt_a", to: "ckpt_b" },
      }),
    ),
  );
  await settle(
    () => doc.body.textContent?.includes("src/a.ts") === true || doc.body.textContent?.includes("a.ts") === true,
  );
  expect(asked).toEqual([["ckpt_a", "ckpt_b"]]);
  expect(doc.querySelector('[data-state="unavailable"]')).toBeNull();
  expect(doc.body.textContent).toContain("a.ts");
});
