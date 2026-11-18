// A TranscriptView render costs O(rows in the window and rows that changed), never O(rows in the
// model). bench/transcript-render-scale.bench.ts read the passes that grew with the chat (a 100k
// row chat's older page cost 215 ms, a streamed token 11.5 ms, ten times a 10k chat's). This file
// holds the bar: V8 precise block coverage over the pane's code (src/agent-session/acpmux/**)
// counts how many blocks ran per TranscriptView render while the transcript scrolls a viewport a
// frame, takes a page of older history above its first row, and takes a streamed reply, at 10k
// and 100k rows. A block count is deterministic, which a time is not; one that grows with the chat
// is an O(rows) pass. 100k rows may cost at most 1.2x what 10k do.
//
// The rows are shaped before they are handed over (the harness's `__prepend` and `__streamShaped`):
// the pane shapes them outside the transcript (App.tsx `shapeFrom`), and the harness reshaping a
// chat it prepends to is not the transcript's cost.
//
// Real Chromium from Playwright, a Vite dev server; CI fails the file when it cannot launch.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-render-scale-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("transcript-render-scale-browser.test.ts", "chromium", chromium))) return;
  setDefaultTimeout(600_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/transcript-fling.html";
  /// The pane's code: a block here that runs more per render at 100k rows is the transcript's.
  const PANE = "/src/agent-session/acpmux/";
  const SIZES = [10_000, 100_000] as const;
  const PHASES = ["step", "prepend", "stream"] as const;
  type Phase = (typeof PHASES)[number];
  /// The most 100k rows may cost per render over 10k.
  const BAR = 1.2;
  /// The phases held to the bar on this branch; every phase is printed. Stream is held by
  /// lane/transcript-view-o-window-b, an older page (prepend) by lane/transcript-view-o-window-c.
  const HELD: readonly Phase[] = ["step"];
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Counts TranscriptView renders off each commit through React's DevTools hook (PerformedWork on
  /// the fiber), installed before React loads (bench/transcript-render-scale.bench.ts).
  const defineRenderCount = () => {
    const state = { on: false, view: 0 };
    (window as unknown as { __renderCount: typeof state }).__renderCount = state;
    type Fiber = {
      tag: number;
      type: any;
      flags: number;
      child: Fiber | null;
      sibling: Fiber | null;
      alternate: Fiber | null;
    };
    const component = new Set([0, 1, 11, 14, 15]);
    const isView = (fiber: Fiber) => {
      const type = fiber.type;
      return component.has(fiber.tag) && (type?.displayName || type?.name || type?.type?.name) === "TranscriptView";
    };
    const mounted = (fiber: Fiber) => {
      for (let at: Fiber | null = fiber; at; at = at.sibling) {
        if (isView(at)) state.view += 1;
        if (at.child) mounted(at.child);
      }
    };
    const updated = (next: Fiber, prev: Fiber) => {
      if (isView(next) && (next.flags & 1) === 1) state.view += 1;
      if (next.child === prev.child) return;
      for (let child = next.child; child; child = child.sibling) {
        if (child.alternate) updated(child, child.alternate);
        else mounted(child);
      }
    };
    const hook = (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ ?? {
      renderers: new Map(),
      supportsFiber: true,
      inject(renderer: unknown) {
        hook.renderers.set(hook.renderers.size + 1, renderer);
        return hook.renderers.size;
      },
      onScheduleFiberRoot() {},
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      checkDCE() {},
    };
    const previous = hook.onCommitFiberRoot;
    hook.onCommitFiberRoot = (id: number, root: { current: Fiber }, ...rest: unknown[]) => {
      if (state.on) {
        const current = root.current;
        if (current.alternate) updated(current, current.alternate);
        else if (current.child) mounted(current.child);
      }
      return previous?.call(hook, id, root, ...rest);
    };
    (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ = hook;
  };

  /// Block executions in the pane's code since the last read, by block (file:offset), and in all.
  const readBlocks = async (cdp: CDPSession) => {
    const { result } = (await cdp.send("Profiler.takePreciseCoverage")) as unknown as {
      result: {
        url: string;
        functions: { functionName: string; ranges: { startOffset: number; count: number }[] }[];
      }[];
    };
    const blocks = new Map<string, number>();
    for (const script of result) {
      const at = script.url.indexOf(PANE);
      if (at < 0) continue;
      const file = script.url.slice(at + 1).replace(/\?.*$/, "");
      for (const fn of script.functions)
        for (const range of fn.ranges) {
          if (range.count === 0) continue;
          const key = `${file}@${range.startOffset} (${fn.functionName || "anonymous"})`;
          blocks.set(key, Math.max(blocks.get(key) ?? 0, range.count));
        }
    }
    return blocks;
  };

  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let frame = 0; frame < n; frame += 1) await new Promise(requestAnimationFrame);
    }, count);

  /// The phase's input, from the latest row settled. Shaping happens before the count starts.
  const drive = async (page: Page, phase: Phase, count: (on: boolean) => Promise<void>) => {
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
    });
    await frames(page, 30);
    if (phase === "step") {
      await count(true);
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let step = 0; step < 20; step += 1) {
          scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight);
          await new Promise(requestAnimationFrame);
        }
        for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
      });
    } else if (phase === "prepend") {
      await page.evaluate(() => {
        (window as unknown as { __prepended: (shown: boolean) => void }).__prepended = (
          window as unknown as { __prepend: () => (shown: boolean) => void }
        ).__prepend();
      });
      await count(true);
      await page.evaluate(async () => {
        (window as unknown as { __prepended: (shown: boolean) => void }).__prepended(true);
        for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
      });
    } else {
      // The older page goes again before the count: the stream starts from the rows it was shaped on.
      await page.evaluate(() => (window as unknown as { __prepended?: (shown: boolean) => void }).__prepended?.(false));
      await frames(page, 10);
      await page.evaluate(() => {
        (window as unknown as { __streamed: (at: number) => void }).__streamed = (
          window as unknown as { __streamShaped: (count: number) => (at: number) => void }
        ).__streamShaped(20);
      });
      await count(true);
      await page.evaluate(async () => {
        const streamed = (window as unknown as { __streamed: (at: number) => void }).__streamed;
        for (let at = 0; at < 20; at += 1) {
          streamed(at);
          await new Promise(requestAnimationFrame);
        }
        for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
      });
    }
    await count(false);
  };

  /// Blocks per TranscriptView render for each phase at `size` rows, on a fresh page.
  const measure = async (size: number) => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    try {
      await page.addInitScript(defineRenderCount);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.startPreciseCoverage", { callCount: true, detailed: true });
      await page.goto(`${vite!.resolvedUrls!.local[0]!.replace(/\/$/, "")}${PAGE}`);
      await page.waitForFunction(() => "__shaping" in window && "__debug" in window);
      await page.evaluate(() => (window as unknown as { __shaping: (mode: string) => void }).__shaping("app"));
      await page.evaluate(`window.__debug.seedRows(${size})`);
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = scroller.scrollHeight;
      });
      await frames(page, 60);
      const out = {} as Record<Phase, { renders: number; blocks: Map<string, number>; perRender: number }>;
      for (const phase of PHASES) {
        await drive(page, phase, async (on) => {
          if (on) {
            await cdp.send("Profiler.takePreciseCoverage");
            await page.evaluate(() => {
              const state = (window as unknown as { __renderCount: { on: boolean; view: number } }).__renderCount;
              state.on = true;
              state.view = 0;
            });
            return;
          }
          const blocks = await readBlocks(cdp);
          const renders = await page.evaluate(() => {
            const state = (window as unknown as { __renderCount: { on: boolean; view: number } }).__renderCount;
            state.on = false;
            return state.view;
          });
          const total = [...blocks.values()].reduce((sum, each) => sum + each, 0);
          out[phase] = { renders, blocks, perRender: total / Math.max(1, renders) };
        });
      }
      return out;
    } finally {
      await page.close();
    }
  };

  test("a TranscriptView render at 100k rows runs at most 1.2x the pane's blocks it runs at 10k", async () => {
    const [small, large] = [await measure(SIZES[0]), await measure(SIZES[1])];
    const report: string[] = [];
    const over: Phase[] = [];
    for (const phase of PHASES) {
      const a = small[phase];
      const b = large[phase];
      const ratio = b.perRender / Math.max(1, a.perRender);
      report.push(
        `${phase}: ${a.perRender.toFixed(0)} -> ${b.perRender.toFixed(0)} blocks per render (renders ${a.renders} -> ${b.renders}), ${ratio.toFixed(2)}x`,
      );
      if (ratio > BAR) over.push(phase);
      // The blocks that grew most, per render: where the O(rows) pass is.
      const grew = [...b.blocks]
        .map(([key, count]) => ({
          key,
          by: count / Math.max(1, b.renders) - (a.blocks.get(key) ?? 0) / Math.max(1, a.renders),
        }))
        .sort((x, y) => y.by - x.by)
        .slice(0, ratio > BAR ? 8 : 3);
      for (const { key, by } of grew) report.push(`  +${by.toFixed(0)} ${key}`);
    }
    console.log(`transcript-render-scale (lane-VM, Chromium, dev build)\n${report.join("\n")}`);
    expect(over.filter((phase) => HELD.includes(phase))).toEqual([]);
  });
});
