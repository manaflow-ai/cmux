// Real transcript and Session Info components; all displayed content is synthetic.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-glyph-alignment-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-glyph-alignment.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const theme of ["dark", "light"] as const)
    for (const height of [28, 40] as const) {
      test(`${theme} ${height}px: production glyphs share the text center line`, async () => {
        const page = await browser.newPage({
          viewport: { width: 760, height: 740 },
          deviceScaleFactor: 2,
        });
        try {
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}&height=${height}`,
          );
          await page.locator("[data-footer-row] .cv-user__time").waitFor();
          await page.evaluate(() => document.fonts.ready);
          const measurements = await page.evaluate(() => {
            const center = (el: Element) => {
              const r = el.getBoundingClientRect();
              return (r.top + r.bottom) / 2;
            };
            const measure = (scope: Element, label: string, glyphs: string) => {
              const text = scope.querySelector(label);
              if (!text) throw new Error(`Missing text: ${label}`);
              return [...scope.querySelectorAll(glyphs)].map((glyph) => {
                const r = glyph.getBoundingClientRect();
                return {
                  delta: Math.abs(center(glyph) - center(text)),
                  width: r.width,
                  height: r.height,
                };
              });
            };
            const rows = [...document.querySelectorAll<HTMLElement>("[data-glyph-row]")].map((scope) => {
              const kind = scope.dataset.glyphRow!;
              const selectors: Record<string, [string, string]> = {
                tool: [".cv-command__time", ".cv-command__ok, svg.cv-tool__chevron"],
                command: [".cv-command__time", ".cv-command__ok, svg.cv-tool__chevron"],
                worked: [".cv-worked__label", ".cv-worked__chevron"],
                thought: [".cv-thought__label", ".cv-tool__chevron"],
                plan: [".cv-plan__text", ".cv-plan__mark"],
                "session-info": [
                  ".acpmux-chat-inspector-section__title",
                  ".acpmux-chat-inspector-section__icon, .acpmux-chat-inspector-section__fold",
                ],
                read: ["[data-read-label]", ".cv-user__read svg"],
              };
              return { kind, glyphs: measure(scope, ...selectors[kind]!) };
            });
            const footer = measure(document.querySelector("[data-footer-row]")!, ".cv-user__time", ".cv-iconbtn svg");
            const versionFooter = measure(
              document.querySelector("[data-version-footer-row]")!,
              ".cv-user__time",
              ".cv-iconbtn svg",
            );
            const retry = (kind: string) =>
              getComputedStyle(document.querySelector(`[data-received-row="${kind}"] .cv-message-retry`)!).display;
            return {
              rows,
              footer,
              versionFooter,
              retryHidden: retry("nonretryable"),
              retryShown: retry("retryable"),
            };
          });
          console.log(`GLYPH_METRICS ${JSON.stringify({ theme, height, ...measurements })}`);
          if (process.env.CMUX_GLYPH_CAPTURES === "1") {
            const png = await page.screenshot();
            console.log(
              `GLYPH_CAPTURE ${JSON.stringify({ name: `${theme}-${height}.png`, base64: png.toString("base64") })}`,
            );
          }
          expect(errors).toEqual([]);
          expect(measurements.rows).toHaveLength(7);
          for (const row of measurements.rows) {
            expect(row.glyphs.length, row.kind).toBeGreaterThan(0);
            for (const glyph of row.glyphs) expect(glyph.delta, row.kind).toBeLessThanOrEqual(0.5);
          }
          expect(measurements.footer).toHaveLength(3);
          expect(measurements.versionFooter).toHaveLength(5);
          for (const glyph of [...measurements.footer, ...measurements.versionFooter]) {
            expect(glyph.delta, "sent footer").toBeLessThanOrEqual(0.5);
            expect(glyph.width, "footer glyph width").toBe(16);
            expect(glyph.height, "footer glyph height").toBe(16);
          }
          expect(measurements.retryHidden).toBe("none");
          expect(measurements.retryShown).toBe("flex");
        } finally {
          await page.close();
        }
      });
    }
});
