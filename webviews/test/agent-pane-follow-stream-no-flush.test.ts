// cmux-web-test-timeout: 300
// A chat that follows its latest row while a reply streams forces no render of the whole transcript per chunk
// (Leo, 2026-11-22: "i think the interactive/visible parts of cmux are not prioritized enough, potentially").
//
// Each chunk's follow write moves the offset, and its scroll event reached the scroll pacer, whose frame
// callback rendered the transcript synchronously (`flushSync`) for that offset. A followed view draws its rows at
// the layout's end and reads no offset, so that render drew the same rows, once per chunk, ahead of the key the
// reader typed: with ten other chats streaming, key to paint p95 went from 236 ms to 129 ms without it
// (bench/composer-typing.bench.ts, L2).
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a light 600-row chat, the
// focused chat streaming at 60 chunks/s (`typingLoad`, the bench's L1), and the pacer's forced
// renders counted (perf.ts `renders`, `transcript:scroll-flush`).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-follow-stream-no-flush.test.ts", async () => {
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

  test("a followed chat streaming a reply forces no transcript render per chunk", async () => {
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
            w.__followStreamDeltas = receipt.deltas ?? 0;
          });
          return (w.__followStreamDeltas ?? 0) >= atLeast;
        },
        target,
        { timeout: 30_000 },
      );
    // Counts from the stream's first chunks: the seed's open and its first placement are not the stream's.
    await chunksReached(15);
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
    const from = (await page.evaluate(
      async () => ((await (window as any).cmuxAcpmuxDebug.typingLoad()) as { deltas: number }).deltas,
    )) as number;
    // 120 more chunks, each a follow write that used to force one render.
    await chunksReached(from + 120);
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    const load = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.typingLoad())) as Record<string, any>;
    const following = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll");
      return node ? node.scrollHeight - node.clientHeight - node.scrollTop : null;
    });
    await page.close();
    const flushes = renders["transcript:scroll-flush"] ?? 0;
    console.log(`FOLLOW-STREAM-FLUSH ${JSON.stringify({ flushes, deltas: load.deltas, following })}`);
    // The stream ran, and the view stayed at the latest row through it.
    expect(load.deltas).toBeGreaterThanOrEqual(from + 120);
    expect(following).not.toBeNull();
    expect(following!).toBeLessThan(4);
    // A handful at most (a row's own measure moving the end): never one per chunk (57 over the same 120 chunks before the fix).
    expect(flushes, "forced transcript renders while a followed chat streams").toBeLessThanOrEqual(5);
  });
});
