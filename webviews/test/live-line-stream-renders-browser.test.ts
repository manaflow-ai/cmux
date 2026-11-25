// l10n-allow-file: test fixture, not shipped UI.
// The running turn's live line ("Writing", "Thinking 12s", the call in flight) draws when what it
// shows changes: its words, its place (the reply above it grew a line), or its clock once a second.
// Not once per streamed chunk or tool output line, which only tell it the turn is still heard from
// (Leo, 2026-11-16: "typing under load is not good enough"; under load its frame drew 490 times in
// one heavy typing run).
//
// The real pane (`?mock`) built by vite.config.acpmux-pane.mjs as it ships, a 300-row chat
// (`cmuxAcpmuxDebug.loadSeed`), then a streamed reply (`loadRun`) and a ticking command (`loadTick`),
// counted by `acpmuxPerf.render`.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/live-line-stream-renders-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("live-line-stream-renders-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("live-line-stream-renders-browser", "chromium", chromium))) return;
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "live-line-stream-renders-"));
  const SECONDS = 4;
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });

  const openChat = async (): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.goto(`http://127.0.0.1:${statics!.port!}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(100, { light: true }))) as {
      error?: string;
    };
    expect(seeded.error).toBeUndefined();
    return page;
  };
  const lineRenders = (renders: Record<string, number>) => ({
    frame: renders["row:thinking-live"] ?? 0,
    content: renders["content:thinking-live"] ?? 0,
  });

  test("a streamed reply draws the live line when it moves or its clock ticks, not once a chunk", async () => {
    const page = await openChat();
    // Each change of the line's place as committed: the reply above it grows a line and pushes it
    // down, which its frame draws (its `top`). Every committed `top`, not one per painted frame: a
    // reply's row draws alone (streamingRow.ts), and its new line reaches the transcript through the
    // row observer, which places the rows before paint and again until they hold, so two places can
    // land in one task before the frame paints (a +1px settle after a line). Each is a draw of the
    // line's frame for its place, never for a chunk.
    await page.evaluate(() => {
      const probe = { moves: 0, top: undefined as string | undefined, observer: undefined as unknown };
      (window as any).__lineMoves = probe;
      const topOf = (style: string | null) => /(?:^|;)\s*top:\s*([^;]+)/.exec(style ?? "")?.[1];
      const observer = new MutationObserver((records) => {
        records.forEach((record, index) => {
          const line = record.target as HTMLElement;
          if (line.dataset?.rowId !== "thinking-live") return;
          // What this mutation set: the next one's old value on the same node, or the node's now.
          const later = records.slice(index + 1).find((next) => next.target === line);
          const top = topOf(later ? later.oldValue : line.getAttribute("style"));
          if (top !== undefined && probe.top !== undefined && top !== probe.top) probe.moves += 1;
          if (top !== undefined) probe.top = top;
        });
      });
      observer.observe(document.body, {
        subtree: true,
        attributes: true,
        attributeFilter: ["style"],
        attributeOldValue: true,
      });
      probe.observer = observer;
    });
    const run = (await page.evaluate(
      (seconds) => (window as any).cmuxAcpmuxDebug.loadRun({ seconds, chunk_ms: 16, tool_every: 0, scroll_speed: 0 }),
      SECONDS,
    )) as { renders?: Record<string, number>; seconds?: number; error?: string };
    const moves = (await page.evaluate(() => {
      const probe = (window as any).__lineMoves;
      probe.observer.disconnect();
      return probe.moves;
    })) as number;
    await page.close();
    expect(run.error).toBeUndefined();
    const drawn = lineRenders(run.renders ?? {});
    console.log(`live line under a streamed reply: ${JSON.stringify({ ...drawn, moves })} in ${run.seconds}s`);
    // About 250 chunks. The line mounts, says "Writing", moves as the reply grows a line, and its
    // clock may tick each second; the chunks themselves draw nothing.
    expect(moves).toBeGreaterThan(0);
    expect(drawn.frame).toBeLessThanOrEqual(moves + SECONDS * 2 + 4);
    // Nor its content: a chunk the reply's row draws without the transcript reaches the line through
    // the transcript's pulse (VirtualTranscript `lineDrawnNow`), never as a newer row to draw.
    expect(drawn.content).toBeLessThanOrEqual(moves + SECONDS * 2 + 4);
  });

  test("a command's output lines draw the live line about once a second, not once a line", async () => {
    const page = await openChat();
    const run = (await page.evaluate(
      (seconds) => (window as any).cmuxAcpmuxDebug.loadTick({ seconds, tick_ms: 16, sidebar_ms: 0, scroll_speed: 0 }),
      SECONDS,
    )) as { renders?: Record<string, number>; seconds?: number; error?: string };
    await page.close();
    expect(run.error).toBeUndefined();
    const drawn = lineRenders(run.renders ?? {});
    console.log(`live line under a ticking command: ${JSON.stringify(drawn)} in ${run.seconds}s`);
    expect(drawn.frame).toBeLessThanOrEqual(SECONDS * 2 + 4);
  });
});
