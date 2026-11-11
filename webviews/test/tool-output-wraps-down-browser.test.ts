// cmux-web-test-timeout: 300
// A tool call's output wraps down instead of running off the right edge. Leo, 2026-11-11, on an
// opened Shell card whose output line ran past the card: "shouldn't this be... not horizontally
// scrolled? as in, it goes down instead of to the right?" So a Shell card's output and a non-shell
// call's output, a 300-character unbroken line among them, have no horizontal scroll at rest
// (scrollWidth equals clientWidth) and their lines take more than one row; the text is the exact
// text, monospace. A `ps` table keeps its rows whole (Leo, 2026-11-04: "why isn't this just
// prettified by default?"), and Wrap lines still flips every output block.
//
// It renders `agent-pane.tool-output-wrap` (the shipped look) in Chromium and WebKit, light and dark.
// CI fails the file when an engine cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/tool-output-wraps-down-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { HUGE, LEO_LINE, UNBROKEN } from "../src/agent-session/acpmux/conversation/ToolOutputWrap.gallery";

await requireBrowserLane("tool-output-wraps-down-browser.test.ts", async () => {
  const ENTRY = "agent-pane.tool-output-wrap";
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, [ENTRY], { browser: browsers.get("chromium") });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, colorScheme: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 640, height: 900 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (;;) {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "by-shape", frame: "component", width: 640, colorScheme })}`,
      );
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.waitForFunction(() => document.querySelectorAll("[data-gallery-block] [data-wrap]").length === 5);
    return page;
  };

  /** The output body of block `name`: its scroll box, its wrap state, and its first line's rows. */
  const measure = (page: Page, name: string) =>
    page.evaluate((name) => {
      const body = document.querySelector<HTMLElement>(`[data-gallery-block="${name}"] [data-wrap]`)!;
      const line = body.querySelector<HTMLElement>(".cv-line")!;
      const style = getComputedStyle(line);
      const height = parseFloat(getComputedStyle(body).lineHeight);
      return {
        wrap: body.getAttribute("data-wrap"),
        scrollWidth: body.scrollWidth,
        clientWidth: body.clientWidth,
        rows: Math.round(line.getBoundingClientRect().height / height),
        text: line.textContent,
        mono: /mono|menlo|courier/i.test(style.fontFamily),
      };
    }, name);

  for (const engine of ["chromium", "webkit"])
    for (const colorScheme of ["light", "dark"]) {
      test(`${engine} ${colorScheme}: a call's long output line wraps down, with no sideways scroll`, async () => {
        const page = await open(engine, colorScheme);
        try {
          for (const [name, text] of [
            ["unbroken", UNBROKEN],
            ["leo", LEO_LINE],
          ] as const) {
            const shown = await measure(page, name);
            expect({ name, wrap: shown.wrap }).toEqual({ name, wrap: "true" });
            expect(shown.text).toBe(text);
            expect(shown.mono).toBe(true);
            // No horizontal scroll: the box is exactly as wide as what it holds.
            expect({ name, scroll: shown.scrollWidth }).toEqual({ name, scroll: shown.clientWidth });
            // The line goes down: 300 characters of 12px mono in a 640px pane take several rows.
            expect(shown.rows).toBeGreaterThan(1);
          }
          expect(UNBROKEN.length).toBe(300);
          // A non-shell call's output with a long path wraps the same way.
          const output = await measure(page, "output");
          expect(output.wrap).toBe("true");
          expect(output.scrollWidth).toBe(output.clientWidth);
          expect(output.rows).toBeGreaterThan(1);
          // One 10,000-character line, wrapped, is cut to eight rows with Show all, as a long output is
          // (Codex review of #41108): it never fills the transcript with hundreds of rows.
          const huge = await page.evaluate(() => {
            const body = document.querySelector<HTMLElement>('[data-gallery-block="huge"] .cv-shell__body')!;
            const row = parseFloat(getComputedStyle(body).lineHeight);
            return {
              preview: body.getAttribute("data-preview"),
              rows: body.clientHeight / row,
              scrollWidth: body.scrollWidth,
              clientWidth: body.clientWidth,
              more: Boolean(document.querySelector('[data-gallery-block="huge"] .cv-output-more')),
            };
          });
          expect(HUGE.length).toBeGreaterThanOrEqual(10_000);
          expect(huge.preview).toBe("cut");
          expect(huge.rows).toBeLessThanOrEqual(9);
          expect(huge.scrollWidth).toBe(huge.clientWidth);
          expect(huge.more).toBe(true);
          await page.locator('[data-gallery-block="huge"] .cv-output-more').click();
          await page.waitForFunction(
            () =>
              document.querySelector('[data-gallery-block="huge"] .cv-shell__body')?.getAttribute("data-preview") ===
              "all",
          );
          // Open, it still offers Show less.
          expect(await page.locator('[data-gallery-block="huge"] .cv-output-more').count()).toBe(1);
          // A table keeps each row whole, its columns aligned, and scrolls for what runs past.
          const table = await measure(page, "table");
          expect(table.wrap).toBe("false");
          expect(table.rows).toBe(1);
          // Wrap lines flips every output block: the long line now stays on one row and scrolls.
          await page.locator('[data-gallery-block="unbroken"] .cv-shell__wrap').click({ force: true });
          await page.waitForFunction(
            () =>
              document.querySelector('[data-gallery-block="unbroken"] [data-wrap]')?.getAttribute("data-wrap") ===
              "false",
          );
          const unwrapped = await measure(page, "unbroken");
          expect(unwrapped.rows).toBe(1);
          expect(unwrapped.scrollWidth).toBeGreaterThan(unwrapped.clientWidth);
        } finally {
          await page.close();
        }
      });
    }
});
