// The Markdown table's Open and Copy controls share one centered line at the table's top-right
// corner, outside its cells, so they never cover a header's text or catch a click meant for a cell. This is a real gallery render so the check covers CSS geometry as well as the static
// TableBlock test. The hover screenshot is the zoomed gallery proof for Leo's alignment report.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-table-actions.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-table-actions: skipping (run `bunx playwright install chromium`)");
    describe.skip("table actions", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.table-block", { variant, width: 960 })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.table-block", { browser, params: { variant: "hover", width: 960 } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 960, height: 760 }, deviceScaleFactor: 2 });
    for (;;) {
      try {
        await page.goto(url(variant));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    const table = page.locator(".cv-table-block").first();
    await table.waitFor();
    await table.hover();
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".cv-table-tools")!).opacity === "1");
    return page;
  };

  const geometry = (page: Page) =>
    page.evaluate(() => {
      const block = document.querySelector<HTMLElement>(".cv-table-block")!;
      const tools = document.querySelector<HTMLElement>(".cv-table-tools")!;
      const buttons = [...tools.querySelectorAll<HTMLButtonElement>("button")];
      const rects = buttons.map((button) => button.getBoundingClientRect());
      const icons = buttons.map((button) => button.querySelector<SVGElement>("svg")!.getBoundingClientRect());
      const table = block.getBoundingClientRect();
      const box = (rect: DOMRect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
      const cells = [...block.querySelectorAll<HTMLElement>("th, td")].map((cell) => box(cell.getBoundingClientRect()));
      const column = block.parentElement!.getBoundingClientRect();
      return {
        tools: box(tools.getBoundingClientRect()),
        cells,
        column: { right: column.right },
        gap: parseFloat(getComputedStyle(tools).gap),
        table: { top: table.top, right: table.right },
        buttons: rects.map((rect) => ({
          top: rect.top,
          right: rect.right,
          width: rect.width,
          height: rect.height,
          center: rect.top + rect.height / 2,
        })),
        icons: icons.map((rect) => ({ width: rect.width, height: rect.height, center: rect.top + rect.height / 2 })),
      };
    });

  for (const variant of ["hover", "first-block"])
    test(`the ${variant} gallery state keeps table actions aligned`, async () => {
      const page = await open(variant);
      const measured = await geometry(page);
      expect(measured.buttons).toHaveLength(2);
      expect(measured.buttons.map((button) => [button.width, button.height])).toEqual([
        [24, 24],
        [24, 24],
      ]);
      expect(measured.icons.map((icon) => [icon.width, icon.height])).toEqual([
        [14, 14],
        [14, 14],
      ]);
      expect(Math.abs(measured.buttons[0]!.center - measured.buttons[1]!.center)).toBeLessThan(0.1);
      expect(Math.abs(measured.icons[0]!.center - measured.icons[1]!.center)).toBeLessThan(0.1);
      expect(Math.abs(measured.buttons[0]!.top - measured.table.top)).toBeLessThan(0.1);
      // Outside the cells: the pair starts at the table's right edge, inside the column, and
      // no cell's box meets it.
      expect(measured.tools.left).toBeGreaterThanOrEqual(measured.table.right - 0.1);
      expect(measured.tools.right).toBeLessThanOrEqual(measured.column.right + 0.1);
      const overlapping = measured.cells.filter(
        (cell) =>
          cell.left < measured.tools.right - 0.1 &&
          cell.right > measured.tools.left + 0.1 &&
          cell.top < measured.tools.bottom - 0.1 &&
          cell.bottom > measured.tools.top + 0.1,
      );
      expect(overlapping).toEqual([]);
      expect(measured.gap).toBe(4);
      if (variant === "hover") {
        const output = path.resolve(import.meta.dir, "../../artifacts/fleet/table-action-alignment-zoom.png");
        await mkdir(path.dirname(output), { recursive: true });
        await page.locator(".cv-table-block").first().screenshot({ path: output });
      }
      await page.close();
    });
});
