// cmux-web-test-timeout: 300
// New Tab's shell glyph and placeholder share relative vertical spacing as content text scales.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-input-scale.test.ts", async () => {
  setDefaultTimeout(300_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", {
      browser,
      params: { variant: "minimal-default", theme: "Apple System Colors" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["Apple System Colors Light", "Apple System Colors"])
    test(`${theme}: input and plus geometry follow small/default/large content scales`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height: 560 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const scales = [
        { name: "small", fontSize: 12 },
        { name: "default", fontSize: 0 },
        { name: "large", fontSize: 18 },
      ] as const;
      const results = [] as {
        name: (typeof scales)[number]["name"];
        fontSize: number;
        glyphFontSize: number;
        fieldPad: number;
        glyphTop: number;
        plusCenter: number;
        lineHeight: number;
        inputHeight: number;
        fieldHeight: number;
        inputBottom: number;
        plusBottom: number;
        textDrop: number;
      }[];
      for (const scale of scales) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", {
            variant: "template-cards",
            theme,
            fontSize: scale.fontSize,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        // Cards has no idle prefix; enter shell mode through the real editor before measuring it.
        await page.locator(".nt-field").click();
        await page.keyboard.type("!pwd");
        await page.locator(".nt-shell-glyph").waitFor();
        results.push(
          await page.locator(".nt-input").evaluate((row, name) => {
            const field = row.querySelector<HTMLElement>(".nt-field")!;
            const glyph = row.querySelector<HTMLElement>(".nt-input-glyph")!;
            const plus = row.querySelector<HTMLElement>(".nt-split-plus .acpmux-picker-button")!;
            const fieldStyle = getComputedStyle(field);
            const glyphStyle = getComputedStyle(glyph);
            const inputRect = row.getBoundingClientRect();
            const fieldRect = field.getBoundingClientRect();
            const glyphRect = glyph.getBoundingClientRect();
            const plusRect = plus.getBoundingClientRect();
            const px = (value: string) => Number.parseFloat(value);
            return {
              name: name as (typeof scales)[number]["name"],
              fontSize: px(fieldStyle.fontSize),
              glyphFontSize: px(glyphStyle.fontSize),
              fieldPad: px(fieldStyle.paddingTop),
              // The text drops this far under the row's padding so its ink centers on + (newtab/screen.css).
              textDrop: px(fieldStyle.paddingTop) - px(fieldStyle.paddingBottom),
              glyphTop: glyphRect.top - inputRect.top,
              plusCenter: (plusRect.top + plusRect.bottom) / 2 - inputRect.top,
              lineHeight: px(fieldStyle.lineHeight),
              inputHeight: inputRect.height,
              fieldHeight: fieldRect.height,
              inputBottom: inputRect.bottom,
              plusBottom: plusRect.bottom,
            };
          }, scale.name),
        );
      }
      const [small, normal, large] = results;
      for (const result of results) {
        expect(result.glyphTop).toBeCloseTo(result.fieldPad, 1);
        expect(result.glyphFontSize).toBeCloseTo(result.fontSize, 1);
        expect(result.plusCenter).toBeCloseTo(result.fieldPad - result.textDrop / 2 + result.lineHeight / 2, 1);
        expect(result.plusBottom).toBeLessThanOrEqual(result.inputBottom + 0.5);
        expect(result.fieldHeight).toBeGreaterThanOrEqual(
          result.lineHeight + 2 * (result.fieldPad - result.textDrop / 2) - 1,
        );
      }
      expect(small.fontSize).toBeCloseTo(12, 1);
      expect(normal.fontSize).toBeCloseTo(14, 1);
      expect(large.fontSize).toBeCloseTo(18, 1);
      expect(small.fieldPad).toBeLessThan(normal.fieldPad);
      expect(normal.fieldPad).toBeLessThan(large.fieldPad);
      expect(small.inputHeight).toBeLessThan(normal.inputHeight);
      expect(normal.inputHeight).toBeLessThan(large.inputHeight);
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", {
          variant: "template-cards",
          theme,
          fontSize: 0,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.screenshot({ path: `/tmp/newtab-input-scale-${theme.includes("Light") ? "light" : "dark"}.png` });
      await page.close();
    });
});
