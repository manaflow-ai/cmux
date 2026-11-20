// New Tab's composer on a new workspace (Leo 2026-10-22: "also idk what's going on with these new
// workspace deletions but it's really slow and it's missing a LOT... and it's also 2 lines tall for
// some reason..."; then "no, it really is deletion not dictation").
//
// 1. The empty box is one line tall: on Minimal (the default) with Claude Code's split, the mode,
//    model and effort sit in the quiet row under the box, and the mic and Send end the field's row.
//    The box's height is its field row's, one line of text plus its insets; no second button row.
// 2. Deleting keeps up: a burst of Backspace presses on a long draft, sent as fast as Playwright
//    sends keys, deletes exactly as many characters, in the New Tab field and the chat composer.
//    The ms per key is logged (the before/after figure for the PR).
//
// Real Chromium and WebKit from Playwright on the gallery stage. Locally:
// CMUX_BROWSER_TESTS=1 bun test test/new-tab-empty-one-line.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-empty-one-line.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-empty-one-line: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab empty one line", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "minimal-default" } });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, entry: string, variant: string, field: string) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(stageURL(entry, variant, 760));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(field).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };
  const painted = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());

  for (const [engine] of engines) {
    test(`${engine}: the empty New Tab composer on Minimal is one line tall`, async () => {
      const page = await open(engine, "agent-pane.new-tab", "minimal-default", ".nt-field");
      await painted(page);
      const sizes = await page.evaluate(() => {
        const box = document.querySelector<HTMLElement>(".nt-box")!;
        const row = document.querySelector<HTMLElement>(".nt-input")!;
        // MarkdownField keeps the New Tab insets on its `.nt-field` wrapper and the line height on
        // its editable (`.acpmux-md`), as the textarea carried both; its value is read through the
        // field's handle.
        const field = document.querySelector(".nt-field") as HTMLElement & {
          acpmuxMarkdownField?: { value(): string };
        };
        const inset = getComputedStyle(field);
        const text = getComputedStyle(field.querySelector<HTMLElement>(".acpmux-md")!);
        return {
          value: field.acpmuxMarkdownField?.value(),
          split: document.querySelector(".nt-foot") !== null,
          box: box.getBoundingClientRect().height,
          row: row.getBoundingClientRect().height,
          oneLine: parseFloat(text.lineHeight) + parseFloat(inset.paddingTop) + parseFloat(inset.paddingBottom),
          send: !!row.querySelector(".nt-send"),
        };
      });
      await page.close();
      console.log(
        `new-tab-empty-one-line ${engine}: box ${sizes.box}px, row ${sizes.row}px, one line ${sizes.oneLine}px`,
      );
      expect(sizes.value).toBe("");
      // The fixture is the split this checks: its chips are in the quiet row under the box.
      expect(sizes.split).toBe(true);
      // Send ends the field's row, and the box is that one row.
      expect(sizes.send).toBe(true);
      expect(Math.abs(sizes.box - sizes.row)).toBeLessThanOrEqual(1);
      expect(Math.abs(sizes.row - sizes.oneLine)).toBeLessThanOrEqual(1);
    });

    for (const surface of [
      // The New Tab field is MarkdownField: its editable, as the chat composer's (the wrapper's text
      // also holds the placeholder).
      {
        name: "the New Tab field",
        entry: "agent-pane.new-tab",
        variant: "minimal-default",
        field: ".nt-field .acpmux-md",
      },
      { name: "the chat composer", entry: "agent-pane.composer", variant: "idle", field: ".acpmux-md" },
    ]) {
      test(`${engine}: a burst of Backspace in ${surface.name} deletes every key`, async () => {
        const page = await open(engine, surface.entry, surface.variant, surface.field);
        await page.click(surface.field);
        await page.keyboard.press("ControlOrMeta+A");
        await page.keyboard.press("Backspace");
        const draft = "delete me quickly please ".repeat(12).trim();
        await page.keyboard.insertText(draft);
        await painted(page);
        const length = () =>
          page.evaluate((selector) => {
            const node = document.querySelector<HTMLElement>(selector)!;
            return (node instanceof HTMLTextAreaElement ? node.value : (node.textContent ?? "")).length;
          }, surface.field);
        const before = await length();
        const presses = 80;
        const started = performance.now();
        for (let index = 0; index < presses; index++) await page.keyboard.press("Backspace");
        await painted(page);
        const perKey = (performance.now() - started) / presses;
        const after = await length();
        await page.close();
        console.log(
          `new-tab-delete-burst ${engine} ${surface.name}: ${perKey.toFixed(2)} ms/key, ${before - after}/${presses} deleted`,
        );
        expect(before).toBe(draft.length);
        expect(before - after).toBe(presses);
        // Keep this measurement in the receipt; host scheduling and Playwright overhead make a
        // wall-clock ceiling nondeterministic. The behavioral assertion above is the gate.
        expect(perKey).toBeGreaterThan(0);
      });
    }
  }
});
