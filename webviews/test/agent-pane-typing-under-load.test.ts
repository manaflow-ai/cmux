// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns and the typed words, not shipped UI.
// Typing into the chat's composer stays instant while a reply streams on a saturated CPU
// (https://github.com/manaflow-ai/cmux/issues/48612: "typing lag in my agent chats ... it should not
// lag even if im at 100% cpu").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a seeded chat of
// 120 rows and a text-only turn streaming at full speed, on a CPU slowed sixfold (Chromium's CPU
// throttling: every task on the page's main thread takes six times as long, as on a machine whose
// cores the agents' builds hold). Forty keys are typed into the prompt at a fast typist's pace.
//
// Per key, it reads what the key cost the page's main thread and what it asked of other processes:
// - key to paint (perf.ts TypingSample: keydown to after the frame that draws it), p50/p95/max;
// - the React renders it caused outside the composer's own field (the pane, the transcript, the
//   composer's pickers and context), counted by acpmuxPerf;
// - the messages it sent to acpmux (draft writes, typing presence), from the mock daemon's socket.
//
// Its writes to acpmux coalesce while the person types: one per pause, not one per key. On the base
// (job of 2026-11-21, 6x slowdown, 41 keys): 41 `_acpmux/draft_set`, key to paint p95 425-461 ms,
// max 605-633 ms; with the fix: none during the burst, p95 299-373 ms, max 475-499 ms. Latency is
// reported, not asserted: a shared VM's timing varies too much to gate on.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

const CPU_SLOWDOWN = 6;
const KEYS = "the quick brown fox jumps over a lazy dog";
const KEY_GAP_MS = 60;

await requireBrowserLane("agent-pane-typing-under-load.test.ts", async () => {
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

  test("a key typed while a reply streams on a saturated CPU edits only the prompt", async () => {
    const page = await browser!.newPage({ viewport: { width: 1400, height: 820 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(120))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const prompt = page.locator('.acpmux-composer-prompt[contenteditable="true"], .acpmux-composer-prompt [contenteditable="true"]').first();
    await prompt.waitFor({ timeout: 30_000 });
    await prompt.click();

    // Every message the page sends acpmux, by method, and every text chunk the stream sends the page.
    await page.evaluate(async (url) => {
      const live = (await import(/* @vite-ignore */ url)).MockAcpmuxSocket.live as any;
      const w = window as any;
      w.__sent = {} as Record<string, number>;
      w.__chunks = 0;
      const send = live.send.bind(live);
      live.send = (raw: string) => {
        try {
          const method = JSON.parse(raw)?.method;
          if (method) w.__sent[method] = (w.__sent[method] ?? 0) + 1;
        } catch {
          // Not JSON: not a request.
        }
        return send(raw);
      };
      const emit = live.emit.bind(live);
      live.emit = (target: string, step: any, at?: number) => {
        if (step?.update?.sessionUpdate === "agent_message_chunk") w.__chunks += 1;
        return emit(target, step, at);
      };
    }, "/mock.ts");

    // The stream: a text-only turn, 24 characters every 12 ms, longer than the typing.
    await page.evaluate(() => {
      (window as any).__streamRun = (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 30,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 0,
        scroll_speed: 0,
      });
    });
    await page.waitForFunction(() => (window as any).__chunks > 10);
    // fixed-wait: the turn's start (its prompt row, the Stop button) settles before the keys.
    await page.waitForTimeout(600);

    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU_SLOWDOWN });
    const perf = "/perf.ts";
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.resetTyping());
    await page.evaluate(async (url) => (await import(/* @vite-ignore */ url)).acpmuxPerf.resetRenders(), perf);
    const chunksBefore = await page.evaluate(() => (window as any).__chunks as number);
    await page.evaluate(() => ((window as any).__sent = {}));

    await prompt.pressSequentially(KEYS, { delay: KEY_GAP_MS });

    const sent = (await page.evaluate(() => ({ ...(window as any).__sent }))) as Record<string, number>;
    const renders = (await page.evaluate(
      async (url) => Object.fromEntries((await import(/* @vite-ignore */ url)).acpmuxPerf.renders),
      perf,
    )) as Record<string, number>;
    const chunks = (await page.evaluate(() => (window as any).__chunks as number)) - chunksBefore;
    // The last key's frame is in before the stats are read.
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0))));
    const stats = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as any;
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    await page.close();

    const keys = KEYS.length;
    const outside = Object.entries(renders).filter(
      ([name]) => name === "pane" || name.startsWith("row:") || name.startsWith("content:") || name.startsWith("frame:"),
    );
    const streamedRows = new Set(
      outside.map(([name]) => name.replace(/^(row|content|frame):/, "")).filter((id) => id !== "pane"),
    );
    const report = {
      cpu_slowdown: CPU_SLOWDOWN,
      keys,
      chunks,
      typed: stats.composer_text,
      to_paint: stats.to_paint,
      to_work: stats.to_work,
      renders,
      streamed_rows: [...streamedRows],
      sent,
    };
    console.log(`TYPING-UNDER-LOAD ${JSON.stringify(report)}`);
    expect(stats.composer_text).toContain(KEYS);
    expect(stats.keys).toBeGreaterThanOrEqual(keys - 2);
    expect(chunks, "the reply streamed through the typing").toBeGreaterThan(20);
    // The keys asked acpmux for their draft once typing paused, not once per key (41 before).
    expect(sent["_acpmux/draft_set"] ?? 0, "draft writes to acpmux while typing").toBeLessThanOrEqual(1);
  });
});
