// cmux-web-test-timeout: 300
// l10n-allow-file: probe.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thought-click-targets-browser.test.ts", async () => {
  const ENTRY = "agent-pane.thought-shapes";
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const SHAPES = ["short", "long", "lead-run", "between-calls", "working-settled"];
  for (const variant of SHAPES)
    test(`probe ${variant}`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      for (;;) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.thought-shapes", { variant, frame: "component", width: 900 })}`,
        );
        try {
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      await page.waitForTimeout(1200);
      const worked = page.locator("button.cv-worked.is-toggle").last();
      if ((await worked.count()) && (await worked.getAttribute("aria-expanded")) !== "true") {
        await worked.click();
        await page.waitForTimeout(500);
      }
      const run = page.locator(".cv-tools > .cv-tool.is-toggle").first();
      if ((await run.count()) && (await run.getAttribute("aria-expanded")) !== "true") {
        await run.click();
        await page.waitForTimeout(500);
      }
      const total = await page.locator("button.cv-thought").count();
      const failures: string[] = [];
      let probes = 0;
      for (let n = 0; n < total; n += 1) {
        const button = page.locator("button.cv-thought").nth(n);
        const row = await button.locator("xpath=..").boundingBox();
        const first = (await button.boundingBox())!;
        // A thought is one line: a click anywhere along it, glyph to the row's end, toggles it.
        const xs: [string, number][] = [
          ["icon", first.x + 8],
          ["mid", first.x + first.width / 2],
          ["past-words", Math.min(first.x + first.width + 40, row!.x + row!.width - 2)],
          ["row-end", row!.x + row!.width - 2],
        ];
        for (const [name, x] of xs) {
          const b = (await button.boundingBox())!;
          const before = await button.getAttribute("aria-expanded");
          await page.mouse.click(x, b.y + Math.min(8, b.height / 2));
          await page.waitForTimeout(350);
          const after = await button.getAttribute("aria-expanded");
          probes += 1;
          if (after === before)
            failures.push(
              `${variant} #${n} @${name} (${Math.round(x - row!.x)}/${Math.round(row!.width)}): stayed ${before}`,
            );
          else {
            await page.mouse.click(first.x + 8, (await button.boundingBox())!.y + 8);
            await page.waitForTimeout(350);
          }
        }
      }
      console.log(
        `SWEEP ${variant}: ${total} thought buttons, ${probes} clicks, ${failures.length} swallowed\n  ${failures.join("\n  ")}`,
      );
      expect(total).toBeGreaterThan(0);
      expect(failures).toEqual([]);
    });
});
