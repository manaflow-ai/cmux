// Whole-window stills of the tools turn's end, frame by frame, in Chromium and WebKit, for review
// (send-stream-motion.test.ts reads that frame where the rows paint; this shows it). Run with
// CMUX_TURN_END_STILLS=<dir>: each engine writes PNGs of the three frames before the frame the turn
// ends in, that frame, and the six after, plus stills.json with every row in view per frame and the
// most any of them moved since the frame before. Skipped otherwise: it asserts nothing.
//
// The page (browser/send-stream-motion.harness.tsx, `?clock=frames&rows=1`) draws only when this
// script advances it: from the reply's last segment on, its frame callbacks wait for `__advance`,
// and every Web Animation is held and moved on by one 120 Hz slot per frame, so each still is that
// frame as a display would show it however long the screenshot takes. Leo, 2026-11-07: "the jumps
// are jarring. We want to minimize the jumps".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Read = { phase?: string; thread: number; rows: { id: string; top: number; opacity: number }[]; ended: boolean };
type Still = Read & { png: Buffer; movedPx: number };

await requireBrowserLane("turn-end-stills.test.ts", async () => {
  setDefaultTimeout(240_000);
  const OUT = process.env.CMUX_TURN_END_STILLS;
  const PAGE = "/test/browser/send-stream-motion.html";

  /// Installed before the page's own scripts: frame callbacks wait for `__advance` once gated.
  function gate() {
    const w = window as unknown as Record<string, unknown>;
    const realRaf = window.requestAnimationFrame.bind(window);
    const realCancel = window.cancelAnimationFrame.bind(window);
    let gated = false;
    let next = -1;
    const queued = new Map<number, FrameRequestCallback>();
    window.requestAnimationFrame = (callback) => {
      if (!gated) return realRaf(callback);
      const id = next--;
      queued.set(id, callback);
      return id;
    };
    window.cancelAnimationFrame = (id) => (id < 0 ? void queued.delete(id) : realCancel(id));
    /// Holds every animation. One that started in the frame just drawn is held at its start, as a
    /// display draws its first frame at the time the frame began (it ran on the wall clock meanwhile:
    /// a commit's idle hops and a slow host's frame, enough to draw an 80 ms glide most of the way).
    const seen = new WeakSet<Animation>();
    const hold = () => {
      for (const animation of document.getAnimations()) {
        if (animation.playState === "running") {
          if (!seen.has(animation) && gated) animation.currentTime = 0;
          animation.pause();
        }
        seen.add(animation);
      }
    };
    w.__gate = () => {
      gated = true;
      hold();
    };
    w.__advance = () =>
      new Promise<void>((resolve) => {
        for (const animation of document.getAnimations())
          if (animation.playState === "paused") animation.currentTime = Number(animation.currentTime ?? 0) + 1000 / 120;
        const callbacks = [...queued.values()];
        queued.clear();
        realRaf((time) => {
          for (const callback of callbacks) callback(time);
          const idle = (w.__frameIdle as (() => Promise<void>) | undefined)?.() ?? Promise.resolve();
          void idle.then(() =>
            realRaf(() => {
              hold();
              resolve();
            }),
          );
        });
      });
    w.__release = () => {
      gated = false;
      for (const callback of queued.values()) realRaf(callback);
      queued.clear();
      for (const animation of document.getAnimations()) if (animation.playState === "paused") animation.play();
    };
    w.__onStep = (name: string) => {
      w.__phase = name;
      if (name === "segment") (w.__gate as () => void)();
    };
  }

  /// The rows in view now: id, where each paints, its opacity; and whether the turn's footer is in.
  function read(): Read {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const view = scroller.getBoundingClientRect();
    const rows: { id: string; top: number; opacity: number }[] = [];
    for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
      const box = row.getBoundingClientRect();
      if (box.height === 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
      rows.push({ id: row.dataset.rowId!, top: box.top, opacity: Number.parseFloat(getComputedStyle(row).opacity) });
    }
    const thread = document.querySelector<HTMLElement>(".acpmux-thread")!.getBoundingClientRect().top;
    const phase = (window as unknown as { __phase?: string }).__phase;
    return { phase, thread, rows, ended: rows.some((row) => row.id === "live-end") };
  }

  const skip = !OUT;
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  beforeAll(async () => {
    if (skip) return;
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-turn-end-stills"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][])
    test.skipIf(skip)(`${name}: stills of the tools turn's end`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const browser = await engine.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 760, height: 900 } });
        await page.addInitScript(gate);
        await page.goto(`http://127.0.0.1:${port}${PAGE}?clock=frames&rows=1`);
        await page.waitForFunction(() => "__sendStream" in window);
        await page.getByText("History answer 6.").waitFor();
        const run = page.evaluate(() =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream
            .run({ scenario: "tools" })
            .then(() => true),
        );
        await page.waitForFunction(() => (window as unknown as { __phase?: string }).__phase === "segment");
        const before: Still[] = [];
        const after: Still[] = [];
        let last: Read | undefined;
        for (let frame = 0; frame < 600 && after.length < 7; frame += 1) {
          await page.evaluate(() => (window as unknown as { __advance: () => Promise<void> }).__advance());
          const now = await page.evaluate(read);
          const was = new Map((last?.rows ?? []).map((row) => [row.id, row.top]));
          let movedPx = 0;
          for (const row of now.rows) {
            const top = was.get(row.id);
            if (top !== undefined) movedPx = Math.max(movedPx, Math.abs(row.top - top));
          }
          last = now;
          const ended = now.ended || after.length > 0;
          const still = { ...now, movedPx, png: await page.screenshot() };
          if (ended) after.push(still);
          else {
            before.push(still);
            if (before.length > 3) before.shift();
          }
        }
        await page.evaluate(() => (window as unknown as { __release: () => void }).__release());
        await run;
        expect(after.length).toBeGreaterThan(0);
        const dir = path.join(OUT!, name);
        mkdirSync(dir, { recursive: true });
        const stills = [...before, ...after];
        const report = stills.map((still, index) => {
          const label =
            index < before.length
              ? `before-${before.length - index}`
              : index === before.length
                ? "end"
                : `after-${index - before.length}`;
          writeFileSync(path.join(dir, `${String(index).padStart(2, "0")}-${label}.png`), still.png);
          const footer = still.rows.find((row) => row.id === "live-end");
          return {
            label,
            phase: still.phase,
            threadTop: Math.round(still.thread * 100) / 100,
            movedPx: Math.round(still.movedPx * 100) / 100,
            footerOpacity: footer ? Math.round(footer.opacity * 100) / 100 : undefined,
            footerTop: footer ? Math.round(footer.top * 100) / 100 : undefined,
            rows: still.rows.map((row) => ({ id: row.id, top: Math.round(row.top * 100) / 100 })),
          };
        });
        writeFileSync(path.join(dir, "stills.json"), JSON.stringify(report, null, 2));
        console.log(
          `turn-end-stills ${name}: ${report.map((still) => `${still.label} thread ${still.threadTop} moved ${still.movedPx} footer ${still.footerOpacity ?? "-"}@${still.footerTop ?? "-"}`).join(" | ")}`,
        );
      } finally {
        await browser.close();
      }
    });
});
