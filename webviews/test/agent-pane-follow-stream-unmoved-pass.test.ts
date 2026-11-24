// cmux-web-test-timeout: 300
// A followed chat's streamed chunk that moves no row runs no placement pass (VirtualTranscript `unmovedPass`).
//
// Leo, 2026-11-19 (ask-4423f4ed20): the app is still slow everywhere. Typing while a reply streams, the composer's
// key waited behind every chunk's placement pass: the pass read the scroller's offset and the pinned line's top,
// a forced layout per chunk, then wrote the same offset back. A reply keeps its drawn height until its row's
// observer reports a new one (a new line), so most chunks move nothing; the observer's report places the rows
// with a pass of its own.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a light 200-row chat, the focused
// chat streaming at 60 chunks/s (`typingLoad`, the composer bench's L1). Counted over 120 chunks: the passes that
// ran and the ones skipped (perf.ts `renders`), and every size change of a row in the thread (a ResizeObserver in
// the page). A pass runs only for a size change, so the passes are at most those; most chunks are skipped; and the
// view stays at the latest row.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-follow-stream-unmoved-pass.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a streamed chunk that changes no row's height runs no placement pass", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(200, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.locator(".acpmux-composer-prompt").first().waitFor({ timeout: 30_000 });
    const started = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.typingLoad({ chunks_per_second: 60, tool_lines_per_second: 0, seconds: 20 }),
    )) as Record<string, any>;
    expect(started.error).toBeUndefined();
    // A synchronous predicate: waitForFunction takes a returned promise as truthy, so each poll starts the async
    // receipt read and judges the count the previous one stored.
    const chunksReached = (target: number) =>
      page.waitForFunction(
        (atLeast) => {
          const w = window as any;
          void w.cmuxAcpmuxDebug.typingLoad().then((receipt: { deltas?: number }) => {
            w.__unmovedDeltas = receipt.deltas ?? 0;
          });
          return (w.__unmovedDeltas ?? 0) >= atLeast;
        },
        target,
        { timeout: 30_000 },
      );
    // Counts from the stream's first chunks: the seed's open and its first placement are not the stream's.
    await chunksReached(15);
    // Every size change of a row in the thread, the rows mounted later too: each frame's batch counts once.
    await page.evaluate(() => {
      const w = window as any;
      const thread = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const seen = new WeakMap<Element, number>();
      w.__unmovedResizes = 0;
      const observer = new ResizeObserver((entries) => {
        let moved = false;
        for (const entry of entries) {
          const height = entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height;
          if (seen.has(entry.target) && Math.abs(seen.get(entry.target)! - height) >= 0.5) moved = true;
          seen.set(entry.target, height);
        }
        if (moved) w.__unmovedResizes += 1;
      });
      const watch = () => {
        for (const row of thread.querySelectorAll(".acpmux-row")) observer.observe(row);
      };
      watch();
      new MutationObserver(watch).observe(thread, { childList: true, subtree: true });
    });
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
    const from = (await page.evaluate(
      async () => ((await (window as any).cmuxAcpmuxDebug.typingLoad()) as { deltas: number }).deltas,
    )) as number;
    await chunksReached(from + 120);
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    const resizes = (await page.evaluate(() => (window as any).__unmovedResizes)) as number;
    const load = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad())) as Record<string, any>;
    const following = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll");
      return node ? node.scrollHeight - node.clientHeight - node.scrollTop : null;
    });
    await page.close();
    const passes = renders["transcript:anchor-pass"] ?? 0;
    const skipped = renders["transcript:anchor-skipped"] ?? 0;
    console.log(
      `FOLLOW-STREAM-UNMOVED ${JSON.stringify({ passes, skipped, resizes, deltas: load.deltas, following })}`,
    );
    expect(load.deltas).toBeGreaterThanOrEqual(from + 120);
    // The view stayed at the latest row through the stream.
    expect(following).not.toBeNull();
    expect(following!).toBeLessThan(4);
    // Most commits moved no row and ran no pass (none were skipped before the fix). A slow runner batches many
    // chunks into one commit, so the bound is a share of the commits, not a count of chunks.
    expect(skipped, "placement passes skipped for commits that moved no row").toBeGreaterThanOrEqual(
      Math.max(10, Math.floor(0.4 * (passes + skipped))),
    );
    // Every pass that ran had a row's size change behind it (its observer's report, or the chunk's commit that
    // the report's frame follows), with a little room for the page's own passes (the composer's, a mount).
    expect(passes, "placement passes against row size changes").toBeLessThanOrEqual(2 * resizes + 6);
  });
});
