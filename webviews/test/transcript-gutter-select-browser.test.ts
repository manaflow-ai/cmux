// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag that starts in the empty margin beside the chat's column selects text, as a document's
// margins do (Leo 2026-10-21: "i want click and drag to highlight text even when im just clicking
// on the left or right of the main pane/out of the chat portion column"). Pressed beside the first
// message and dragged down beside the third, the selection holds text from all three; a plain click
// in the margin selects nothing and leaves focus where it was; a drag inside the column selects as
// it always did. On base the margin drag selected nothing.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-gutter-select-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-gutter-select: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("gutter select", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  let at = 0;
  const row = (id: string, kind: string, text: string) => ({ id, kind, text, version: 1, at: (at += 1_000) });
  // Three answers, each a paragraph a few lines long, so the column's text has lines beside the press.
  const rows = [
    row(
      "m1",
      "assistant",
      "Alpha keeper. The keeper climbed to the gallery and wiped the salt from the lantern glass.",
    ),
    row("m2", "assistant", "Bravo tide. The tide came in under the jetty and lifted the moored boats one by one."),
    row("m3", "assistant", "Charlie gull. A gull settled on the rail and watched the light sweep across the water."),
  ];

  const open = async (name: string): Promise<Page> => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.evaluate(async () => {
      for (let left = 10; left > 0; left--) await window.cmuxPaintFrame();
    });
    return page;
  };
  /// The client box of message `id`'s text, and the column's left and right edges.
  const box = (page: Page, id: string) =>
    page.evaluate((rowId) => {
      const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${rowId}"]`)!;
      const text = node.querySelector<HTMLElement>(".cv-md") ?? node;
      const rect = text.getBoundingClientRect();
      const column = node.getBoundingClientRect();
      return { top: rect.top, bottom: rect.bottom, left: column.left, right: column.right };
    }, id);
  const selected = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");

  for (const [name] of engines) {
    test(`${name}: a drag from the left margin beside message 1 down to message 3 selects all three`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      expect(first.left).toBeGreaterThan(100);
      const x = first.left / 2;
      await page.mouse.move(x, first.top + 4);
      await page.mouse.down();
      // Several moves, as a hand drags; the selection follows on the frames between them.
      for (let step = 1; step <= 6; step += 1) {
        await page.mouse.move(x, first.top + 4 + ((third.bottom - 4 - first.top - 4) * step) / 6);
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await page.mouse.up();
      const text = await selected(page);
      expect(text).toContain("Alpha");
      expect(text).toContain("Bravo tide");
      expect(text).toContain("Charlie");
      await page.close();
    });

    test(`${name}: a drag from the right margin up selects from the line beside it`, async () => {
      const page = await open(name);
      const second = await box(page, "m2");
      const first = await box(page, "m1");
      const x = (second.right + 1280 - 16) / 2;
      await page.mouse.move(x, second.bottom - 4);
      await page.mouse.down();
      await page.mouse.move(x, second.bottom - 20);
      await page.mouse.move(x, first.top + 4);
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.mouse.up();
      const text = await selected(page);
      expect(text).toContain("Alpha");
      expect(text).toContain("Bravo");
      expect(text).not.toContain("Charlie");
      await page.close();
    });

    test(`${name}: a click in the margin selects nothing and keeps focus where it was`, async () => {
      const page = await open(name);
      // A field outside the transcript holds focus, as the composer does.
      await page.evaluate(() => {
        const field = document.createElement("textarea");
        field.id = "composer-stand-in";
        document.body.append(field);
        field.focus();
      });
      const first = await box(page, "m1");
      await page.mouse.click(first.left / 2, first.top + 4);
      await page.evaluate(() => window.cmuxPaintFrame());
      expect(await selected(page)).toBe("");
      expect(await page.evaluate(() => document.activeElement?.id)).toBe("composer-stand-in");
      await page.close();
    });

    test(`${name}: a drag inside the column still selects as before`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const second = await box(page, "m2");
      await page.mouse.move(first.left + 4, first.top + 4);
      await page.mouse.down();
      await page.mouse.move(first.left + 40, first.top + 10);
      await page.mouse.move(first.left + 200, second.top + 4);
      await page.mouse.up();
      const text = await selected(page);
      expect(text).toContain("keeper");
      expect(text).toContain("Bravo");
      await page.close();
    });
  }
});
