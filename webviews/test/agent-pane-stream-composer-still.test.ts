// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// While a reply streams, the composer and Session Info stay still: no React render and no style or
// layout work in either, per streamed chunk (Leo, 2026-11-07: "I feel like the composer and the
// session info thing, like that's still doing these kind of flicker re-renders when you are
// streaming in text.").
//
// Neither React nor the pane's state redrew them: each chunk re-renders only its row
// (agent-pane-stream-renders.test.ts). The browser did. A transcript ancestor that was a `:has()`
// subject over its whole subtree (`html:has(.acpmux-shell[data-tab-row])`,
// `.acpmux-main:has(.acpmux-asks-stack)`, `.acpmux-stage:has(.acpmux-find)`, ...) is checked again for
// every node a chunk inserts into the transcript, and the engine's one `:has()` descendant
// invalidation set then restyles every element under it that some `X:has(...) Y` rule names: the
// composer's box, its field, its icons and its foot, once per chunk.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with Session Info
// open, a seeded chat, and one text-only turn streamed at full speed (`loadRun`). A Chromium trace with
// invalidation tracking runs over the middle of the stream (after the turn's start, before its end),
// and counts every style recalc and layout invalidation of an element inside the composer or Session
// Info, beside the React renders of both over the same window.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-stream-composer-still.test.ts", async () => {
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

  // With the header's own row, and with the header's tools in the pane's tab row (the app's default
  // look, header/tabRow.ts), whose root mark was an `html:has()`.
  for (const tabRow of [false, true])
    test(`a streamed chunk restyles and re-renders neither the composer nor Session Info${tabRow ? ", in the tab row" : ""}`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1400, height: 820 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/?mock`);
      await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
      if (tabRow) {
        await page.evaluate(async () => {
          const url = "/header/tabRow.ts";
          const module = await import(/* @vite-ignore */ url);
          module.setTabRow({ height: 40, trailingInset: 12 });
        });
        await page.waitForFunction(() => document.querySelector("section.acpmux-shell")?.hasAttribute("data-tab-row"));
      }
      const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(120))) as Record<string, any>;
      expect(seeded.error).toBeUndefined();
      // Session Info on, as the header state carries it, and its enter slide over.
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
      const toggle = page.locator("button.acpmux-session-info-toggle").first();
      await toggle.waitFor({ timeout: 10_000 });
      if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
      await page.waitForFunction(
        () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
      );
      await page.waitForFunction(
        () => document.querySelector("aside.acpmux-session-info")!.getAnimations({ subtree: true }).length === 0,
      );

      // Each text chunk the mock daemon sends, counted as it goes out.
      await page.evaluate(async (url) => {
        const live = (await import(/* @vite-ignore */ url)).MockAcpmuxSocket.live as any;
        const emit = live.emit.bind(live);
        (window as any).__chunks = 0;
        live.emit = (target: string, step: any, at?: number) => {
          if (step?.update?.sessionUpdate === "agent_message_chunk") (window as any).__chunks += 1;
          return emit(target, step, at);
        };
      }, "/mock.ts");
      const chunksSent = () => page.evaluate(() => (window as any).__chunks as number);
      // The stream: a text-only turn, 24 characters every 12 ms for 5 s, followed at the bottom.
      await page.evaluate(() => {
        (window as any).__streamRun = (window as any).cmuxAcpmuxDebug.loadRun({
          seconds: 5,
          chunk_chars: 24,
          chunk_ms: 12,
          tool_every: 0,
          scroll_speed: 0,
        });
      });
      // The window opens once the reply streams and the turn's structural changes (its prompt, its
      // start, the Stop button) are in.
      await page.waitForFunction(() => (window as any).__chunks > 10);
      // fixed-wait: the turn's start settles before the window opens.
      await page.waitForTimeout(600);

      const cdp = await page.context().newCDPSession(page);
      await cdp.send("DOM.getDocument", { depth: -1 });
      const events: any[] = [];
      cdp.on("Tracing.dataCollected", (event: any) => events.push(...event.value));
      const traced = new Promise((resolve) => cdp.once("Tracing.tracingComplete", resolve));
      // The pane's own modules, at the paths the page loaded them from (the dev server's root is the pane's folder).
      const perf = "/perf.ts";
      await page.evaluate(async (url) => (await import(/* @vite-ignore */ url)).acpmuxPerf.resetRenders(), perf);
      const before = await chunksSent();
      await cdp.send("Tracing.start", {
        categories: "devtools.timeline,disabled-by-default-devtools.timeline.invalidationTracking",
        transferMode: "ReportEvents",
      });
      // fixed-wait: the window is a timed slice of the stream; its chunks are what is measured.
      await page.waitForTimeout(2_000);
      await cdp.send("Tracing.end");
      const after = await chunksSent();
      const renders = (await page.evaluate(
        async (url) => Object.fromEntries((await import(/* @vite-ignore */ url)).acpmuxPerf.renders),
        perf,
      )) as Record<string, number>;
      await traced;

      // Each element a style recalc or layout invalidation touched, by the part of the pane it is in.
      const touched = new Map<number, number>();
      for (const event of events) {
        if (event.name !== "StyleRecalcInvalidationTracking" && event.name !== "LayoutInvalidationTracking") continue;
        const id = event.args?.data?.nodeId;
        if (id) touched.set(id, (touched.get(id) ?? 0) + 1);
      }
      // Paints over the window, for the report: Chromium records the page's one paint layer whole, so these
      // follow the transcript's frames, not the composer or Session Info.
      const paints = events.filter((event) => event.name === "Paint").length;
      const still = { composer: 0, sessionInfo: 0 };
      const where: Record<string, number> = {};
      for (const [backendNodeId, count] of touched) {
        let part: string | undefined;
        try {
          const { object } = (await cdp.send("DOM.resolveNode", { backendNodeId })) as any;
          const result = (await cdp.send("Runtime.callFunctionOn", {
            objectId: object.objectId,
            functionDeclaration: `function () {
            const element = this.nodeType === 1 ? this : this.parentElement;
            if (!element) return undefined;
            const part = element.closest("aside.acpmux-session-info") ? "sessionInfo"
              : element.closest("form.acpmux-composer") ? "composer" : undefined;
            return part && part + " " + element.tagName.toLowerCase() + "." + (element.getAttribute("class") ?? "");
          }`,
            returnByValue: true,
          })) as any;
          part = result.result.value;
        } catch {
          // A node the stream removed since: a transcript row's, never the composer's or Session Info's.
        }
        if (!part) continue;
        const [name, ...element] = part.split(" ");
        still[name as keyof typeof still] += count;
        where[element.join(" ")] = (where[element.join(" ")] ?? 0) + count;
      }
      const streamed = await page.evaluate(() => (window as any).__streamRun);
      await page.close();
      const chunks = after - before;
      const report = {
        chunks,
        deltas: streamed.deltas,
        composerStyleOrLayout: still.composer,
        sessionInfoStyleOrLayout: still.sessionInfo,
        composerRenders: renders.composer ?? 0,
        sessionInfoRenders: (renders["session-info:panel"] ?? 0) + (renders["session-info:sections"] ?? 0),
        paneRenders: renders.pane ?? 0,
        paints,
        busiest: Object.entries(where)
          .sort((a, b) => b[1] - a[1])
          .slice(0, 8),
      };
      console.log(`STREAM-COMPOSER-STILL ${JSON.stringify({ tabRow, ...report })}`);
      // The window saw the stream.
      expect(chunks).toBeGreaterThan(50);
      expect(report.composerRenders, "composer renders over the streamed chunks").toBe(0);
      expect(report.sessionInfoRenders, "Session Info renders over the streamed chunks").toBe(0);
      expect(report.composerStyleOrLayout, "composer style recalcs and layout invalidations").toBe(0);
      expect(report.sessionInfoStyleOrLayout, "Session Info style recalcs and layout invalidations").toBe(0);
    });
});
