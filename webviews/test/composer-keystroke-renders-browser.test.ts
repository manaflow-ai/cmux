// l10n-allow-file: typed test keys, not shipped UI.
// A keystroke in the agent chat's prompt draws the prompt box and the parts that read its text, and
// nothing else, however long the chat (CMUX-571; Leo: "improve performance (chat, everything
// related)"; Leo, 2026-11-12: long chats must have "no perceivable difference"). Not the pane root,
// the transcript or a row; and not the model picker under the box, which does not read the text
// (it read the composer's prompt-focus function, a new one on each composer render, from context),
// and not the + menu (ComposerFrame, which the React Compiler leaves as written, built its rows and
// handlers anew on each render).
//
// The real pane (`?mock`) built by vite.config.acpmux-pane.mjs as it ships (production React, React
// Compiler on; the dev server's development build never drew the picker on a key, fix or not); a chat of
// 1,500 rows (`cmuxAcpmuxDebug.loadSeed`), then real keys in Chromium, counted by `acpmuxPerf.render`.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-keystroke-renders-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import fs from "node:fs";
import os from "node:os";

await requireBrowserLane("composer-keystroke-renders-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-keystroke-renders-browser", "chromium", chromium))) return;
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const KEYS = 12;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-keystroke-renders-"));
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

  test("a key in a long chat draws neither the transcript, a row, the model picker nor the + menu", async () => {
    const port = statics!.port!;
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
    const shows = (text: string) =>
      page.waitForFunction(
        ([selector, want]) => {
          const text = (document.querySelector(selector!)?.textContent ?? "").trim();
          // An empty prompt may still draw its placeholder.
          return want === "" ? !text.includes("warm") : text === want;
        },
        [PROMPT, text] as const,
      );
    // Two frames after the last change: every render the key started has committed.
    const settled = () =>
      page.evaluate(
        () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))),
      );
    for (const key of "warm") await page.keyboard.press(key);
    await shows("warm");
    for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
    await shows("");
    await settled();
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
    const typed = "abcdefghijkl".slice(0, KEYS);
    for (let i = 0; i < typed.length; i += 1) {
      await page.keyboard.press(typed[i]!);
      await shows(typed.slice(0, i + 1));
    }
    await settled();
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    await page.close();
    const counted = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    // The prompt box draws once a key: it reads the text from the prompt's store (composer/promptText.ts).
    // The composer around it does not: the text is no longer its state (Leo: "we need typing in the gui to be
    // fast too and smootha nd stuff"). It may draw once over the run (a facts change: the prompt went non-empty).
    expect(renders["composer:box"] ?? 0).toBeGreaterThanOrEqual(KEYS);
    expect(renders.composer ?? 0).toBeLessThanOrEqual(2);
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
