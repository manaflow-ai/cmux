// The plain-rows highlighter (WorkerRenderOptionsSync.tsx `drawPlainBeforeWorkers`) is handed to
// the highlight pool, which draws plain rows with it in the pool's own themes. It used to load the
// themes of the viewer's options captured at first mount, which can differ from the pool's; it now
// loads the pool's. A pool shut down while the instance was built does not get it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    Node: window.Node,
    Element: window.Element,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Stats = { managerState: "waiting" | "initializing" | "initialized"; workersFailed: boolean };

/** The parts of @pierre/diffs' WorkerPoolManager that drawPlainBeforeWorkers reads, still starting. */
function startingPool(theme: { dark: string; light: string }) {
  const pool = {
    highlighter: undefined as { getLoadedThemes(): string[]; dispose(): void } | undefined,
    stats: { managerState: "initializing", workersFailed: false } as Stats,
    isInitialized: () => false,
    getDiffRenderOptions: () => ({
      theme,
      useTokenTransformer: false,
      tokenizeMaxLineLength: 1000,
      lineDiffType: "word-alt",
      maxLineDiffLength: 1000,
    }),
    getStats: () => pool.stats,
    subscribeToStatChanges: () => () => {},
  };
  return pool;
}

test("the plain-rows highlighter loads the pool's themes", async () => {
  const { drawPlainBeforeWorkers } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const pool = startingPool({ dark: "github-dark", light: "github-light" });
  expect(await drawPlainBeforeWorkers(pool as never)).toBe("drawn");
  expect(pool.highlighter?.getLoadedThemes().sort()).toEqual(["github-dark", "github-light"]);
  pool.highlighter?.dispose();
});

test("a pool shut down while the highlighter was built does not keep it", async () => {
  const { drawPlainBeforeWorkers } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const pool = startingPool({ dark: "github-dark", light: "github-light" });
  const outcome = drawPlainBeforeWorkers(pool as never);
  // What WorkerPoolManager.terminate() leaves: no instance, waiting, not failed.
  pool.stats = { managerState: "waiting", workersFailed: false };
  expect(await outcome).toBe("stopped");
  expect(pool.highlighter).toBeUndefined();
});
