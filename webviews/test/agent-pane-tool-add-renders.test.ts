// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A tool call that lands in a running turn draws its own row, and the rows already on screen stay as
// they were: none of them draws its content again. Leo, 2026-11-19, watching a busy coordinator chat:
// "why stuff redraw often?". Most of a coordinator's events are tool calls and their results, not
// streamed text, and each one drew every row on screen again.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a light seeded chat,
// a turn already running with two calls in it, then ten more calls, each its call and 60 ms later its
// result (`cmuxAcpmuxDebug.loadTools`). Each row's content counts its commits (`content:<id>`,
// VirtualTranscript.tsx RowContent) through `cmuxAcpmuxDebug.renders()`.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-add-renders.test.ts", async () => {
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

  const CALLS = 10;

  test("a tool call added to a running turn draws no row already on screen again", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 820 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(120, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const loadTools = (count: number, keepOpen: boolean) =>
      page.evaluate(
        ([n, open]) => (window as any).cmuxAcpmuxDebug.loadTools({ count: n, gap_ms: 60, keep_open: open }),
        [count, keepOpen] as const,
      ) as Promise<Record<string, any>>;
    expect((await loadTools(2, true)).error).toBeUndefined();
    await page.waitForTimeout(800); // fixed-wait: the turn's start and first calls have drawn and settled.
    const before = (await page.evaluate(() => {
      (window as any).cmuxAcpmuxDebug.renders();
      return [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row[data-row-id]")].map(
        (row) => row.dataset.rowId!,
      );
    })) as string[];
    await loadTools(CALLS, true);
    await page.waitForTimeout(300); // fixed-wait: the last result's commit lands.
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    await loadTools(0, false);
    await page.close();
    // The rows on screen before the calls, but the live line under the turn (it names the running call)
    // and the turn's last row (the next call joins under it).
    const settled = before.slice(0, -2);
    const redrawn = Object.fromEntries(
      settled.map((id) => [id, renders[`content:${id}`] ?? 0] as const).filter(([, count]) => count > 0),
    );
    const report = { mounted: before.length, settled: settled.length, redrawn };
    console.log(`TOOL-ADD-RENDERS ${JSON.stringify(report)}`);
    expect(settled.length).toBeGreaterThan(5);
    expect(redrawn, "rows already on screen that drew again over ten added tool calls").toEqual({});
  });
});
