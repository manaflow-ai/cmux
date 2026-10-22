// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag that starts in the empty margin beside the chat's column selects text, as a document's
// margins do (Leo 2026-10-21: "i want click and drag to highlight text even when im just clicking
// on the left or right of the main pane/out of the chat portion column"). Pressed beside the first
// message and dragged down into the third, the selection holds text from all three. As in a
// document, a press left of a line starts at its start and one right of it at its end. A plain click
// in the margin selects nothing and takes focus off the composer as a press on the background always
// has; a drag inside the column selects as it always did. On base the margin drag selected nothing.
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

  /// Presses at `from`, drags to `to` in six moves a painted frame apart (as a hand drags), lifts.
  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    for (let step = 1; step <= 6; step += 1) {
      await page.mouse.move(from.x + ((to.x - from.x) * step) / 6, from.y + ((to.y - from.y) * step) / 6);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.mouse.up();
  };

  for (const [name] of engines) {
    test(`${name}: a drag from the left margin beside message 1 down into message 3 selects all three`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      expect(first.left).toBeGreaterThan(100);
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: third.left + 300, y: third.bottom - 4 });
      const text = await selected(page);
      // From the start of the line beside the press, as a document's margin selects.
      expect(text.startsWith("Alpha keeper.")).toBe(true);
      expect(text).toContain("Bravo tide. The tide came in under the jetty");
      expect(text).toContain("Charlie gull.");
      await page.close();
    });

    test(`${name}: a drag that stays in the left margin selects whole lines up to the line beside the pointer`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: first.left / 2, y: third.bottom - 4 });
      const text = await selected(page);
      expect(text).toContain("Alpha keeper.");
      expect(text).toContain("lifted the moored boats one by one.");
      expect(text).not.toContain("Charlie");
      await page.close();
    });

    test(`${name}: a drag from the right margin beside message 3 up into message 1 selects from the end of that line`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      const x = (third.right + 1280 - 16) / 2;
      await drag(page, { x, y: third.bottom - 4 }, { x: first.left + 300, y: first.top + 4 });
      const text = await selected(page);
      expect(text).not.toContain("Alpha keeper.");
      expect(text).toContain("lantern glass.");
      expect(text).toContain("Bravo tide.");
      expect(text.trimEnd().endsWith("sweep across the water.")).toBe(true);
      await page.close();
    });

    test(`${name}: a click in the margin selects nothing and takes focus off the composer, as before`, async () => {
      const page = await open(name);
      // A field outside the transcript holds focus, as the composer does. Fixed, so it moves nothing.
      await page.evaluate(() => {
        const field = document.createElement("textarea");
        field.id = "composer-stand-in";
        Object.assign(field.style, { position: "fixed", left: "0", bottom: "0", width: "40px", height: "20px" });
        document.body.append(field);
        field.focus();
      });
      const first = await box(page, "m1");
      await page.mouse.click(first.left / 2, first.top + 4);
      await page.evaluate(() => window.cmuxPaintFrame());
      expect(await selected(page)).toBe("");
      // A press on the background leaves the composer (Leo 2026-10-20, composerFocus.ts), as on base.
      expect(await page.evaluate(() => document.activeElement === document.body)).toBe(true);
      await page.close();
    });

    test(`${name}: a click in the margin lets go of a selection in the transcript`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: first.left / 2, y: third.top + 4 });
      expect(await selected(page)).toContain("Bravo");
      await page.mouse.click(first.left / 2, third.top + 4);
      expect(await selected(page)).toBe("");
      await page.close();
    });

    test(`${name}: the selection follows the view as it scrolls under a still pointer`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 360 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const long = Array.from({ length: 12 }, (_, index) =>
        row(`l${index}`, "assistant", `Line ${index}. The keeper wrote the hour and the height of the tide.`),
      );
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        long,
      );
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let left = 10; left > 0; left--) await window.cmuxPaintFrame();
        scroller.scrollTop = 0;
        for (let left = 4; left > 0; left--) await window.cmuxPaintFrame();
      });
      const top = await box(page, "l0");
      const x = top.left / 2;
      await page.mouse.move(x, top.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, 300);
      await page.evaluate(() => window.cmuxPaintFrame());
      const before = await selected(page);
      // The wheel moves the view; the pointer does not move.
      await page.evaluate(async () => {
        document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop += 200;
        for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
      });
      const after = await selected(page);
      await page.mouse.up();
      expect(after.length).toBeGreaterThan(before.length);
      expect(after.startsWith("Line 0.")).toBe(true);
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
