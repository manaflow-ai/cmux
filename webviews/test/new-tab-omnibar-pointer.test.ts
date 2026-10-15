// The New Tab page's field follows the browser omnibar's pointer and hover rules (OmnibarPointer,
// cx-d0d.80; Lawrence 2026-10-13): the I-beam over the whole field row at rest and while editing,
// the arrow over its buttons, a hover lift on the box that eases in and out with the hover token,
// none while the field has the keyboard, and no easing under Reduce Motion.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-omnibar-pointer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-omnibar-pointer: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab omnibar pointer", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/new-tab-picker.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(reducedMotion: "reduce" | "no-preference"): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 }, reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html`);
    await page.locator(".nt-field").waitFor();
    // The app draws the page inside the pane's shell, which defines the composer's color tokens.
    await page.evaluate(() => document.getElementById("root")!.classList.add("acpmux-shell"));
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    return page;
  }

  /** The cursor CSS gives the element under a point, and that element's class. */
  function cursorAt(page: Page, x: number, y: number) {
    return page.evaluate(
      ([px, py]) => {
        const node = document.elementFromPoint(px!, py!) as HTMLElement | null;
        return { cursor: node ? getComputedStyle(node).cursor : "none", node: node?.className ?? "" };
      },
      [x, y],
    );
  }

  const fill = (page: Page) =>
    page.evaluate(() => getComputedStyle(document.querySelector(".nt-box")!).backgroundImage);
  const lift = (page: Page) =>
    page.evaluate(() => getComputedStyle(document.querySelector(".nt-box")!).getPropertyValue("--nt-box-lift").trim());

  test("the I-beam over the whole field row at rest and while editing; the arrow over a button", async () => {
    const page = await open("no-preference");
    const row = (await page.locator(".nt-input").boundingBox())!;
    const field = (await page.locator(".nt-field").boundingBox())!;
    const points = {
      "the field": [field.x + field.width / 2, field.y + field.height / 2],
      "the row's leading padding": [row.x + 4, row.y + row.height / 2],
      "the row above the text": [field.x + field.width / 2, row.y + 2],
    } as const;
    for (const editing of [false, true]) {
      for (const [name, [x, y]] of Object.entries(points)) {
        const got = await cursorAt(page, x, y);
        console.log(`new-tab-omnibar-pointer ${editing ? "editing" : "rest"} ${name}:`, JSON.stringify(got));
        expect(got.cursor).toBe("text");
      }
      // A press beside the text focuses the field (wherever the I-beam shows, a click focuses).
      await page.mouse.click(row.x + 4, row.y + row.height / 2);
      expect(await page.evaluate(() => document.activeElement?.classList.contains("nt-field"))).toBe(true);
    }
    const button = page.locator(".nt-box button").first();
    const box = (await button.boundingBox())!;
    const got = await cursorAt(page, box.x + box.width / 2, box.y + box.height / 2);
    console.log("new-tab-omnibar-pointer button:", JSON.stringify(got));
    expect(got.cursor).toBe("default");
    await page.close();
  });

  test("the box lifts on hover with an eased fill, not while it has the keyboard", async () => {
    const page = await open("no-preference");
    const duration = await page.evaluate(() => getComputedStyle(document.querySelector(".nt-box")!).transitionDuration);
    console.log("new-tab-omnibar-pointer transition:", duration);
    expect(duration).not.toBe("0s");
    await page.mouse.move(5, 5);
    const rest = await fill(page);
    expect(rest).not.toBe("none");
    const box = (await page.locator(".nt-box").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height - 6);
    await page.waitForFunction(
      () => getComputedStyle(document.querySelector(".nt-box")!).getPropertyValue("--nt-box-lift").trim() === "100%",
    );
    const hovered = await fill(page);
    console.log("new-tab-omnibar-pointer fill rest/hover:", rest, "|", hovered);
    expect(hovered).not.toBe(rest);
    await page.locator(".nt-field").focus();
    await page.waitForFunction(
      () => getComputedStyle(document.querySelector(".nt-box")!).getPropertyValue("--nt-box-lift").trim() === "0%",
    );
    expect(await fill(page)).toBe(rest);
    await page.close();
  });

  test("under Reduce Motion the fill changes at once", async () => {
    const page = await open("reduce");
    expect(await fill(page)).not.toBe("none");
    const duration = await page.evaluate(() => getComputedStyle(document.querySelector(".nt-box")!).transitionDuration);
    // desktop.css cuts every transition to 0.01 ms under Reduce Motion.
    expect(parseFloat(duration)).toBeLessThan(0.001);
    const box = (await page.locator(".nt-box").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height - 6);
    expect(await lift(page)).toBe("100%");
    await page.close();
  });
});
