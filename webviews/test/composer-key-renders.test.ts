// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns and typed test keys, not shipped UI.
// A key in the agent chat's composer draws the composer, its box and the prompt, which hold and draw
// the text, and nothing else: not a row, and not a part of the composer whose output a key leaves as
// it was (Leo, 2026-11-08, of a 100% CPU spike while dictating; chat-instant-under-load: a frame costs
// the rows on screen and what changed). Send, its glyph and its menu draw when the draft starts or
// empties, never on the keys between.
//
// On the base it was measured on, each key drew 13 components: the prompt's right-click menu, the button
// row's and Send's (three ContextMenus), the button row (ChromeArea), the attachment strip, the + menu,
// Send's menu, Send's glyph and its icon. Each got props made anew on every key: handlers that close over
// the draft (the + menu's, the prompt menu's rows, Send's menu's choice), a hook's object read whole
// (the Esc double press's), a list filtered again on every render (the strip's chips, the pending ones),
// Send's menu left uncompiled (a ref read during render) and the prompt drawn inside its menu, which
// then drew with it.
//
// The real pane (`?mock`), a chat of 300 heavy turns (`loadSeed`), then 30 keys typed into a draft,
// each counting every React component that rendered (support/fiberRenders.ts, read off each commit as
// React DevTools reads it). Real Chromium and WebKit; CI fails the file when one cannot launch.
// `COMPOSER_KEY_TOP=80` lists every component that rendered.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { installFiberRenders, startFiberRenders, stopFiberRenders } from "./support/fiberRenders";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("composer-key-renders.test.ts", async () => {
  /// Component renders a key may cost, at most. Measured over 30 keys on the lane VM: on the base 13.4 in
  /// Chromium and 13 in WebKit (ContextMenu 3.1 and 3); on the head that made these parts hold still 4 in
  /// both (ComposerFrame, ComposerBox, and the prompt's memo and MarkdownFieldImpl, 1 each; ContextMenu
  /// 0). Room for commits a slow runner splits in two.
  const BUDGET = 6;
  /// What a key leaves as it was draws on (almost) no key: each at most this many renders a key.
  const STILL_BUDGET = 0.1;
  const STILL = [
    "ContextMenu",
    "ChromeArea",
    "AttachmentStrip",
    "ComposerPlusMenu",
    "SendMenu",
    "SendSlotGlyph",
    "GlyphIcon",
  ];
  const KEYS = 30;
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  const perKey = (value: number) => Math.round((value / KEYS) * 100) / 100;

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`composer-key-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a key in the composer draws the composer and its prompt only", async () => {
        const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
        await installFiberRenders(page);
        await page.goto(`${base}/?mock`);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<
          string,
          any
        >;
        expect(seeded.error).toBeUndefined();
        // A draft first: Send enables on its first letter, which may draw it once.
        await page.locator(COMPOSER_EDITOR).click();
        await page.keyboard.type("warm");
        await page.waitForFunction(
          (editor) => document.querySelector(editor)?.textContent?.includes("warm"),
          COMPOSER_EDITOR,
        );
        await startFiberRenders(page);
        await page.keyboard.type("x".repeat(KEYS));
        await page.waitForFunction(
          ([editor, keys]) => (document.querySelector(editor)?.textContent?.match(/x/g)?.length ?? 0) >= keys,
          [COMPOSER_EDITOR, KEYS] as const,
        );
        await page.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        const fibers = await stopFiberRenders(page);
        await page.close();
        const counts = fibers.counts;
        const total = perKey(Object.values(counts).reduce((sum, value) => sum + value, 0));
        const top = Object.fromEntries(
          Object.entries(counts)
            .sort((a, b) => b[1] - a[1])
            .slice(0, Number(process.env.COMPOSER_KEY_TOP ?? 12))
            .map(([component, value]) => [component, perKey(value)]),
        );
        console.log(
          `COMPOSER-KEY ${JSON.stringify({ engine: name, keys: KEYS, commits: fibers.commits, per_key: total, top })}`,
        );
        // The keys landed and drew the prompt: a window that drew nothing would pass the budgets.
        expect(perKey(counts.MarkdownFieldImpl ?? 0), "the prompt's renders per key").toBeGreaterThanOrEqual(0.9);
        const still = Object.fromEntries(STILL.map((component) => [component, perKey(counts[component] ?? 0)]));
        for (const component of STILL)
          expect(still[component], `${component} renders per key`).toBeLessThanOrEqual(STILL_BUDGET);
        expect(total, "component renders per key").toBeLessThanOrEqual(BUDGET);
      });
    });
  }
});
