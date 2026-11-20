// The plain-rows highlighter (WorkerRenderOptionsSync.tsx `drawPlainBeforeWorkers`) draws the
// highlight pool's plain rows while the pool has no highlighter of its own (@pierre/diffs 1.6 keeps
// it in a module, not on the pool, so handing the pool an instance no longer worked: rows waited
// for the pool's start-up). It draws them in the pool's own themes, which can differ from the
// viewer's options captured at first mount. A pool shut down while the instance was built keeps
// its own methods.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  await teardownDom(saved, { scope });
});
type Stats = { managerState: "waiting" | "initializing" | "initialized"; workersFailed: boolean };

/**
 * The parts of @pierre/diffs' WorkerPoolManager that drawPlainBeforeWorkers reads, still starting:
 * like the real pool before its shared highlighter loads, its plain-row methods draw nothing.
 */
function startingPool(theme: { dark: string; light: string }) {
  let notify: ((stats: Stats) => unknown) | null = null;
  const options = {
    theme,
    useTokenTransformer: false,
    tokenizeMaxLineLength: 1000,
    lineDiffType: "word-alt",
    maxLineDiffLength: 1000,
  };
  const pool = {
    stats: { managerState: "initializing", workersFailed: false } as Stats,
    ownDiffCalls: 0,
    isInitialized: () => pool.stats.managerState === "initialized",
    getPreferredHighlighter: () => "shiki-wasm",
    getDiffRenderOptions: () => ({ ...options }),
    getFileRenderOptions: () => ({ theme, useTokenTransformer: false, tokenizeMaxLineLength: 1000 }),
    getPlainDiffAST(..._args: unknown[]): unknown {
      pool.ownDiffCalls += 1;
      return undefined;
    },
    getPlainFileAST(..._args: unknown[]): unknown {
      return undefined;
    },
    getStats: () => pool.stats,
    subscribeToStatChanges: (callback: (stats: Stats) => unknown) => {
      notify = callback;
      callback(pool.stats);
      return () => {
        notify = null;
      };
    },
    broadcast: () => notify?.(pool.stats),
  };
  return pool;
}

const patch = [
  "diff --git a/a.ts b/a.ts",
  "--- a/a.ts",
  "+++ b/a.ts",
  "@@ -1,2 +1,2 @@",
  " const a = 1;",
  "-const b = 2;",
  "+const b = 3;",
  "",
].join("\n");

test("before the pool's highlighter loads, its plain rows draw in the pool's themes", async () => {
  const { processFile } = await import("@pierre/diffs");
  const { drawPlainBeforeWorkers } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const pool = startingPool({ dark: "github-dark", light: "github-light" });
  const ownDiff = pool.getPlainDiffAST;
  expect(await drawPlainBeforeWorkers(pool as never)).toBe("drawn");
  const diff = processFile(patch, { cacheKey: "plain-rows", isGitDiff: true });
  const result = pool.getPlainDiffAST(diff, 0, Infinity, true, 1) as {
    code: { deletionLines: unknown[]; additionLines: unknown[] };
    themeStyles: string;
  };
  // The pool's own method still runs first (it queues the pool's start-up).
  expect(pool.ownDiffCalls).toBe(1);
  expect(result.code.deletionLines.length).toBe(2);
  expect(result.code.additionLines.length).toBe(2);
  // Both of the pool's themes' colors, as the pool's own plain rows carry them.
  expect(result.themeStyles).toContain("dark:");
  expect(result.themeStyles).toContain("light:");
  // Once the pool is up, its own methods come back.
  pool.stats = { managerState: "initialized", workersFailed: false };
  pool.broadcast();
  expect(pool.getPlainDiffAST).toBe(ownDiff);
});

test("a pool shut down while the highlighter was built keeps its own methods", async () => {
  const { drawPlainBeforeWorkers } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const pool = startingPool({ dark: "github-dark", light: "github-light" });
  const ownDiff = pool.getPlainDiffAST;
  const outcome = drawPlainBeforeWorkers(pool as never);
  // What WorkerPoolManager.terminate() leaves: no instance, waiting, not failed.
  pool.stats = { managerState: "waiting", workersFailed: false };
  expect(await outcome).toBe("stopped");
  expect(pool.getPlainDiffAST).toBe(ownDiff);
});

test("a pool with no plain-row methods is unsupported", async () => {
  const { drawPlainBeforeWorkers } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const { getPlainDiffAST: _diff, ...pool } = startingPool({ dark: "github-dark", light: "github-light" });
  expect(await drawPlainBeforeWorkers(pool as never)).toBe("unsupported");
});

test("a code view draws its rows while plain rows can draw, then goes back to its own answer", async () => {
  const { drawPlainBeforeWorkers, letViewDrawBeforePool } = await import("../src/diff-viewer/WorkerRenderOptionsSync");
  const pool = startingPool({ dark: "github-dark", light: "github-light" });
  let poolUp = false;
  let ownCalls = 0;
  class View {
    isReady() {
      ownCalls += 1;
      return poolUp;
    }
    render() {}
  }
  const view = new View();
  // Before the plain-rows instance exists, the view keeps its own answer.
  expect(letViewDrawBeforePool(view as never, pool as never)).toBe(false);
  expect(await drawPlainBeforeWorkers(pool as never)).toBe("drawn");
  expect(letViewDrawBeforePool(view as never, pool as never)).toBe(true);
  expect(view.isReady()).toBe(true);
  // Its own check still runs (it starts the pool and draws again when the pool is up).
  expect(ownCalls).toBe(1);
  poolUp = true;
  pool.stats = { managerState: "initialized", workersFailed: false };
  pool.broadcast();
  expect(view.isReady()).toBe(true);
  // The gate stepped aside: the prototype's method answers again.
  expect(Object.prototype.hasOwnProperty.call(view, "isReady")).toBe(false);
  poolUp = false;
  expect(view.isReady()).toBe(false);
});
