// l10n-allow-file: test assertions on the viewer's English labels, not shipped UI.
// The diff viewer beside a chat keeps its scope readable (cx-ku7r1, dogfood run 2 hq #1893): the
// chat header's ± opens it about 400 px wide, and Commit and Push in the toolbar squeezed the
// scope chip to "Br". At that width the chip shows whole and Commit and Push stay on screen.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("diff-toolbar-narrow.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("diff-toolbar-narrow: skipping (run `bunx playwright install chromium`)");
    describe.skip("diff toolbar narrow", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/diff-toolbar-narrow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [400, 560]) {
    test(`at ${width} px the scope chip shows whole, with Commit and Push on screen`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 600 } });
      await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html`);
      const chip = page.locator("#source-menu");
      await chip.waitFor();
      await page.getByRole("button", { name: "Commit", exact: true }).waitFor();
      const fits = await page.evaluate(() => {
        const pill = document.querySelector("#source-menu")!.getBoundingClientRect();
        const cell = document.querySelector("#toolbar .toolbar-left")!.getBoundingClientRect();
        return { pill: pill.width, shown: Math.min(pill.right, cell.right) - pill.left };
      });
      expect(fits.shown).toBeGreaterThanOrEqual(fits.pill - 0.5);
      for (const name of ["Commit", /^(Push|Publish)/]) {
        const box = await page
          .getByRole("button", { name, exact: typeof name === "string" })
          .first()
          .boundingBox();
        expect(box && box.width > 0 && box.x >= 0 && box.x + box.width <= width).toBe(true);
      }
      await page.close();
    });
  }

  // POLISH.md: no capsule pills, small-radius rects; a circle stays a circle.
  test("the toolbar's controls are small-radius rects, not capsules", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html`);
    await page.locator("#source-menu").waitFor();
    await page.getByRole("button", { name: "Commit", exact: true }).waitFor();
    const capsules = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("#toolbar *, #diff-pill *")].flatMap((element) => {
        const { width, height } = element.getBoundingClientRect();
        const radius = parseFloat(getComputedStyle(element).borderTopLeftRadius);
        const capsule = height > 0 && Math.abs(width - height) > 1 && radius >= height / 2 - 0.5;
        return capsule ? [`${element.id ? `#${element.id}` : `.${element.classList[0]}`} ${width}x${height}`] : [];
      }),
    );
    expect(capsules).toEqual([]);
    await page.close();
  });
});
