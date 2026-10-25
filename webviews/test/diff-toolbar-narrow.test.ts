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

  // Beside the files sidebar (shown from 521 px) the source controls share the bar with the toolbar
  // pill: the base picker gives way (its head side first) so the jump-to-file chevron stays in its
  // cell and clear of the pill, and the picker's label stays inside its button.
  for (const width of [521, 540, 560, 600]) {
    test(`at ${width} px beside the files the source controls stay in their cell`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 600 } });
      await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html?picker`);
      await page.locator("#base-picker-button").waitFor();
      await page.locator("#jump-to-file-button").waitFor();
      const boxes = await page.evaluate(() => {
        const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
        const label = [...document.querySelectorAll("#base-picker-button .base-picker-label > *")]
          .map((element) => element.getBoundingClientRect())
          .filter((box) => box.width > 0);
        return {
          filesHidden: document.body.dataset.filesHidden,
          cell: rect("#toolbar .toolbar-left").right,
          jump: rect("#jump-to-file-button").right,
          pill: rect("#diff-pill").left,
          button: rect("#base-picker-button").right,
          label: Math.max(...label.map((box) => box.right)),
        };
      });
      await page.close();
      expect(boxes.filesHidden).toBe("false");
      expect(boxes.jump).toBeLessThanOrEqual(boxes.cell + 0.5);
      expect(boxes.jump).toBeLessThanOrEqual(boxes.pill);
      expect(boxes.label).toBeLessThanOrEqual(boxes.button + 0.5);
    });
  }

  // Narrower, with no files sidebar (beside a chat at about 400 px): the base picker keeps its label
  // inside its chip, and jump-to-file never draws over the picker (the cell clips it instead).
  for (const width of [400, 460]) {
    test(`at ${width} px the base picker's label stays in its chip, clear of jump-to-file`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 600 } });
      await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html?picker`);
      await page.locator("#base-picker-button").waitFor();
      // Jump-to-file comes once the patch's files are read, after the picker (DiffToolbar.tsx draws
      // nothing with no files); the cell may clip it here, so it need only be in the page.
      await page.locator("#jump-to-file-button").waitFor({ state: "attached" });
      const boxes = await page.evaluate(() => {
        const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
        const label = [...document.querySelectorAll("#base-picker-button .base-picker-label > *")]
          .map((element) => element.getBoundingClientRect())
          .filter((box) => box.width > 0);
        return {
          cell: rect("#toolbar .toolbar-left").right,
          jump: rect("#jump-to-file-button").left,
          button: rect("#base-picker-button").right,
          label: Math.max(...label.map((box) => box.right)),
        };
      });
      await page.close();
      expect(boxes.label).toBeLessThanOrEqual(boxes.button + 0.5);
      if (boxes.jump < boxes.cell) expect(boxes.jump).toBeGreaterThanOrEqual(boxes.button);
    });
  }

  // A long base branch ellipsizes inside the picker, so jump-to-file keeps its place in the cell
  // (beside the files sidebar and without it) instead of the full name pushing it out of sight.
  for (const width of [560, 600, 900]) {
    test(`at ${width} px a long base branch ellipsizes and jump-to-file stays in its cell`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 600 } });
      await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html?picker&long`);
      await page.locator("#base-picker-button").waitFor();
      await page.locator("#jump-to-file-button").waitFor();
      const boxes = await page.evaluate(() => {
        const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
        const ref = document.querySelector<HTMLElement>("#base-picker-button .base-picker-ref")!;
        return {
          cell: rect("#toolbar .toolbar-left").right,
          jump: rect("#jump-to-file-button"),
          button: rect("#base-picker-button").right,
          refShown: ref.clientWidth,
          refWants: ref.scrollWidth,
        };
      });
      await page.close();
      expect(boxes.jump.right).toBeLessThanOrEqual(boxes.cell + 0.5);
      expect(boxes.jump.left).toBeGreaterThanOrEqual(boxes.button - 0.5);
      if (width < 900) expect(boxes.refShown).toBeLessThan(boxes.refWants);
      expect(boxes.refShown).toBeGreaterThan(0);
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
