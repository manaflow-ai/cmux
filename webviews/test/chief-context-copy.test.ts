// cmux-web-test-timeout: 300
// The "Context from the Chief (89 lines)" line over a Chief subagent's first message: its Copy sits
// at the line's trailing end with a gap, and no button (that Copy, or the row's floating Copy that
// keyboard focus shows) is ever drawn over the label's text. A narrow pane truncates the label on
// one line instead (Lawrence 2026-10-20: the Copy covered "lines)"). Dark and light themes.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/chief-context-copy.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chief-context-copy.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`chief context copy: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("chief context copy", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (width: number, theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.chief-prompt", { variant: "context", frame: "component", width, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.chief-prompt", {
      browser: [...browsers.values()][0],
      params: { variant: "context" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing: no transition or animation left to run (a
   *  looping one never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (engine: string, width: number, theme: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(width, theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.locator(".cv-user__context summary").waitFor();
    return page;
  };

  for (const [engine] of engines)
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
      for (const width of [760, 420, 300])
        test(`${engine}, ${theme}, ${width}px: the context's Copy trails its label and covers no text`, async () => {
          const page = await open(engine, width, theme);
          // Keyboard focus on the row shows its action row's buttons too.
          await page.locator(".acpmux-row:has(.cv-user__context)").first().focus();
          // The Copy has faded in.
          await eased(page);
          const geometry = await page.evaluate(() => {
            const context = document.querySelector<HTMLElement>(".cv-user__context")!;
            const summary = context.querySelector("summary")!;
            const label = summary.querySelector<HTMLElement>(".cv-user__context-label");
            // The label's drawn text: a range over its text nodes, not its box, cut to the box. A
            // truncated label's range still spans the whole string past its ellipsis, where
            // overflow: hidden draws nothing.
            const range = document.createRange();
            range.selectNodeContents(label ?? summary);
            const glyphs = range.getBoundingClientRect();
            const box = (label ?? summary).getBoundingClientRect();
            const text = {
              left: Math.max(glyphs.left, box.left),
              right: Math.min(glyphs.right, box.right),
              top: glyphs.top,
              bottom: glyphs.bottom,
              height: glyphs.height,
            };
            const lineHeight = parseFloat(getComputedStyle(label ?? summary).lineHeight) || 18;
            const copy = context.querySelector<HTMLElement>(".cv-user__context-copy");
            const row = context.closest(".acpmux-row")!;
            const shown = (element: Element) => {
              const style = getComputedStyle(element);
              const box = element.getBoundingClientRect();
              return style.visibility !== "hidden" && Number(style.opacity) > 0.05 && box.width > 0 && box.height > 0;
            };
            const buttons = [...row.querySelectorAll("button")].filter(shown).map((button) => {
              const box = button.getBoundingClientRect();
              return {
                name: button.getAttribute("aria-label"),
                left: box.left,
                right: box.right,
                top: box.top,
                bottom: box.bottom,
              };
            });
            const copyBox = copy?.getBoundingClientRect();
            return {
              text: { left: text.left, right: text.right, top: text.top, bottom: text.bottom, height: text.height },
              lineHeight,
              buttons,
              copy: copyBox
                ? { left: copyBox.left, right: copyBox.right, top: copyBox.top, bottom: copyBox.bottom }
                : null,
              truncates: label ? getComputedStyle(label).textOverflow === "ellipsis" : false,
              // The cut above holds only while the label clips what runs past its box.
              clips: label ? getComputedStyle(label).overflowX === "hidden" : false,
            };
          });
          expect(geometry.copy, "the context line has its own Copy").not.toBeNull();
          const copy = geometry.copy!;
          expect(copy.left - geometry.text.right, "Copy trails the label with a gap").toBeGreaterThanOrEqual(4);
          expect(
            copy.top < geometry.text.bottom && copy.bottom > geometry.text.top,
            "Copy is on the label's line",
          ).toBe(true);
          for (const button of geometry.buttons) {
            const overlaps =
              button.left < geometry.text.right &&
              button.right > geometry.text.left &&
              button.top < geometry.text.bottom &&
              button.bottom > geometry.text.top;
            expect(overlaps, `${button.name} covers the label's text`).toBe(false);
          }
          expect(geometry.text.height, "the label stays on one line").toBeLessThanOrEqual(geometry.lineHeight * 1.5);
          expect(geometry.truncates, "a long label ends in an ellipsis").toBe(true);
          expect(geometry.clips, "the label clips its overflow, so nothing draws past its box").toBe(true);
          await page.close();
        });
});
