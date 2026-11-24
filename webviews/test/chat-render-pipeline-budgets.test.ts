// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// The chat render pipeline's budgets (cmuxterm-hq docs/design/chat-render-pipeline.md, its "Checks" section). Leo,
// 2026-11-16: "The rendering wants to recalculating stuff when the agent chat stream is going/ends, but text comes in
// pretty quickly, and stuff shifts at the bottom pretty frequently, and then there's a big wave of stuff that gets
// redrawn". The doc gives each stage of a streamed reply a scope: a streamed token restyles its own row (and the tail
// under it), never the list; the stream's end settles the tail, never the list; a typed key forces no style or layout
// pass from script. This file holds the code to those scopes in Chromium, from a trace of the real pane:
//
//   stream    a 700-turn chat streams a reply (`loadRun`, no scrolling, no tool calls). Every style pass
//             (UpdateLayoutTree) restyles at most ROW_SCOPE elements, and none restyles more than LIST_FRACTION of
//             the elements under the scroller (the mounted rows and their frame): that is "the list".
//   settle    the 1 s after the stream ends (the mock marks `acpmux-load-stream-end`): the same, at TAIL_SCOPE.
//   typing    30 keys typed into the composer while a reply streams. In the key's own tasks (each task that dispatched a
//             key or input event), script forces at most FORCED_PER_KEY style or
//             layout passes per key (a pass whose trace event carries a JS stack), not counting the test's own
//             driver (loadDebug.ts reads the scroller every frame to time it).
//
// It found, on feat-cmux-next 49d40100083: the scroll origin (conversation/scrollCoordinates.ts
// `retainScrollOrigin`) written as an inherited custom property on the scroller restyled every mounted element,
// 1,500-1,970 per write, several times a streamed token, and the read after it forced the layout at once.
// CHAT_RENDER_MEASURE=1 prints the numbers and asserts nothing (to calibrate the budgets on a runner).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import {
  FORCED_PER_KEY,
  HARNESS,
  LIST_FRACTION,
  MEASURE,
  PROMPT,
  ROW_SCOPE,
  TAIL_SCOPE,
  TRANSCRIPT,
  TRANSCRIPT_FORCED_PER_KEY,
  keyTaskRanges,
  markAt,
  passes,
  summary,
  trace,
  type Pass,
} from "./support/chatRenderTrace";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-render-pipeline-budgets.test.ts", async () => {
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

  async function openChat() {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(700))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
    const scrollElements = await page.evaluate(() => document.querySelectorAll(".acpmux-scroll *").length);
    return { page, scrollElements };
  }

  function transcriptSites(forced: Pass[]) {
    const bySite = new Map<string, number>();
    for (const p of forced) {
      const site = `${p.kind} ${p.stack!.split(" < ").slice(0, 2).join(" < ")}`;
      bySite.set(site, (bySite.get(site) ?? 0) + 1);
    }
    return [...bySite].sort((a, b) => b[1] - a[1]).slice(0, 6);
  }

  describe("chat render pipeline budgets (chromium)", () => {
    test("a streamed token restyles its row, the stream's end its tail, never the list", async () => {
      const { page, scrollElements } = await openChat();
      let run: Record<string, any> = {};
      const events = await trace(browser!, page, async () => {
        run = (await page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadRun({
            seconds: 3,
            chunk_chars: 24,
            chunk_ms: 16,
            tool_every: 0,
            scroll_speed: 0,
          }),
        )) as Record<string, any>;
        // fixed-wait: the settle window is the measured interval, the second after the stream's end.
        await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 1000)));
      });
      await page.close();
      expect(run.error).toBeUndefined();
      const all = passes(events);
      const end = markAt(events, "acpmux-load-stream-end");
      expect(end).toBeDefined();
      const stream = summary(
        all.filter((p) => p.ts < end!),
        scrollElements,
      );
      const settle = summary(
        all.filter((p) => p.ts >= end! && p.ts < end! + 1_000_000),
        scrollElements,
      );
      const deltas = Number(run.deltas ?? 0);
      const report = {
        scrollElements,
        deltas,
        stream: { ...stream, elementsPerDelta: deltas ? Math.round(stream.elements / deltas) : null },
        settle,
      };
      console.log(`CHAT-RENDER-BUDGETS stream ${JSON.stringify(report)}`);
      console.log(
        `CHAT-RENDER-SUMMARY stream p95=${stream.p95} max=${stream.max} share=${stream.listShare} perDelta=${report.stream.elementsPerDelta} settleMax=${settle.max} settleShare=${settle.listShare}`,
      );
      if (MEASURE) return;
      expect(deltas).toBeGreaterThan(20);
      expect(
        stream.p95,
        `p95 elements per style pass while streaming (${stream.biggest.join("; ")})`,
      ).toBeLessThanOrEqual(ROW_SCOPE);
      expect(
        stream.listShare,
        `largest restyle while streaming, share of the transcript (${stream.biggest.join("; ")})`,
      ).toBeLessThan(LIST_FRACTION);
      expect(settle.max, `largest restyle as the stream settles (${settle.biggest.join("; ")})`).toBeLessThanOrEqual(
        TAIL_SCOPE,
      );
      expect(settle.listShare, `largest restyle as the stream settles, share of the transcript`).toBeLessThan(
        LIST_FRACTION,
      );
    });

    test("a key typed while a reply streams forces at most the measured style or layout from script", async () => {
      const { page, scrollElements } = await openChat();
      await page.locator(PROMPT).first().click();
      const KEYS = 30;
      const events = await trace(browser!, page, async () => {
        const streaming = page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 4, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
        );
        // fixed-wait: the keys go in at a fast typist's pace, after the stream has started.
        await page.waitForTimeout(300);
        for (let i = 0; i < KEYS; i += 1) {
          await page.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]!);
          // fixed-wait: the gap between keys is the measured pace.
          await page.waitForTimeout(60);
        }
        await streaming;
      });
      await page.close();
      const all = passes(events);
      const forcedAll = all.filter((p) => p.stack && !HARNESS.test(p.stack));
      // The key's own tasks: each main-thread task (toplevel RunTask) that dispatched a key or input event. A forced
      // pass in one of them is a pass the key waited on; the stream's own forced passes run in other tasks and are
      // reported (streamForced), not budgeted here.
      const keyTasks = keyTaskRanges(events);
      const inKey = (p: Pass) => keyTasks.some(([start, end]) => p.ts >= start && p.ts <= end);
      const forced = forcedAll.filter(inKey);
      const bySite = new Map<string, number>();
      for (const p of forced) {
        const site = `${p.kind} ${p.stack!.split(" < ").slice(0, 2).join(" < ")}`;
        bySite.set(site, (bySite.get(site) ?? 0) + 1);
      }
      const transcriptForced = forced.filter((p) => TRANSCRIPT.test(p.stack!));
      const keydowns = events.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown").length;
      const report = {
        scrollElements,
        keys: KEYS,
        keydowns,
        keyTasks: keyTasks.length,
        forced: forced.length,
        forcedPerKey: Math.round((forced.length / KEYS) * 100) / 100,
        forcedElements: forced.reduce((sum, p) => sum + (p.kind === "style" ? p.elements : 0), 0),
        sites: [...bySite].sort((a, b) => b[1] - a[1]).slice(0, 8),
        streamForced: forcedAll.length - forced.length,
        transcriptForced: transcriptForced.length,
        transcriptPerKey: Math.round((transcriptForced.length / KEYS) * 100) / 100,
        transcriptSites: transcriptSites(transcriptForced),
        typing: summary(all, scrollElements),
      };
      console.log(`CHAT-RENDER-BUDGETS typing ${JSON.stringify(report)}`);
      console.log(
        `CHAT-RENDER-SUMMARY typing forcedPerKey=${report.forcedPerKey} transcriptPerKey=${report.transcriptPerKey} share=${report.typing.listShare}`,
      );
      if (MEASURE) return;
      expect(keydowns).toBeGreaterThanOrEqual(KEYS);
      expect(keyTasks.length).toBeGreaterThanOrEqual(KEYS);
      expect(
        report.forcedPerKey,
        `forced style/layout passes per key, by site: ${JSON.stringify(report.sites)}`,
      ).toBeLessThanOrEqual(FORCED_PER_KEY);
      expect(
        report.transcriptPerKey,
        `transcript code forced style or layout in a key's task, by site: ${JSON.stringify(report.transcriptSites)}`,
      ).toBeLessThanOrEqual(TRANSCRIPT_FORCED_PER_KEY);
      expect(
        report.typing.listShare,
        `largest restyle while typing under a stream (${report.typing.biggest.join("; ")})`,
      ).toBeLessThan(LIST_FRACTION);
    });
  });
});
