// l10n-allow-file: typed test keys, not shipped UI.
// A keystroke in the agent chat's prompt draws the composer and the parts that read its text, and
// nothing else, however long the chat (CMUX-571; Leo: "improve performance (chat, everything
// related)"; Leo, 2026-11-12: long chats must have "no perceivable difference"). Not the pane root,
// the transcript or a row; and not the chips under the box that do not read the text: the model
// picker (it read the composer's prompt-focus function, a new one on each composer render, from
// context) and the + menu (its handlers came inline, new on each render).
//
// The real pane (`?mock`) from vite.config.acpmux-pane.mjs, React Compiler on, as it ships; a chat of
// 1,500 rows (`cmuxAcpmuxDebug.loadSeed`), then real keys in Chromium, counted by `acpmuxPerf.render`.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-keystroke-renders-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-keystroke-renders-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-keystroke-renders-browser", "chromium", chromium))) return;
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const KEYS = 12;
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    const { createServer } = await import("vite");
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

  test("a key in a long chat draws neither the transcript, a row, the model picker nor the + menu", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }))) as {
      rows?: number;
      error?: string;
    };
    expect(seeded.error).toBeUndefined();
    expect(seeded.rows ?? 0).toBeGreaterThan(1000);
    const prompt = page.locator(PROMPT).first();
    await prompt.waitFor({ timeout: 30_000 });
    await prompt.click();
    // The first keys load the composer's lazy parts (emoji data, the mention index).
    for (const key of "warm") await page.keyboard.press(key);
    await page.waitForTimeout(400);
    for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
    await page.waitForTimeout(400);
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
    for (const key of "abcdefghijkl".slice(0, KEYS)) {
      await page.keyboard.press(key);
      await page.waitForTimeout(40);
    }
    await page.waitForTimeout(400);
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    await page.close();
    const counted = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    // The composer itself draws once a key: the text is its state.
    expect(renders.composer ?? 0).toBeGreaterThanOrEqual(KEYS);
    // The pane may draw once over the run (a clock tick), never once a key.
    expect(renders.pane ?? 0).toBeLessThanOrEqual(1);
    expect({
      transcript: renders.transcript ?? 0,
      rows: counted("row:") + counted("content:") + counted("frame:"),
      model: renders["composer:model"] ?? 0,
      plus: renders["composer:plus"] ?? 0,
    }).toEqual({ transcript: 0, rows: 0, model: 0, plus: 0 });
  });
});
