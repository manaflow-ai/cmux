// The New Tab page's field follows the browser omnibar's pointer and hover rules (OmnibarPointer,
// cx-d0d.80; Lawrence 2026-10-13): the I-beam over the whole field row at rest and while editing,
// the pointing hand over its buttons (Leo 2026-10-21: every clickable thing shows the hand; it was
// the arrow), and no hover lift on the box: it is quiet, as Claude's and ChatGPT's composers are
// (Leo 2026-10-18).
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
    page.evaluate(() => {
      const style = getComputedStyle(document.querySelector(".nt-box")!);
      return `${style.backgroundColor} ${style.backgroundImage}`;
    });

  test("the I-beam over the whole field row at rest and while editing; the pointing hand over a button", async () => {
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
    // The first button is the enabled model chip; every enabled button shows the hand (Leo
    // 2026-10-21: "LOTS OF AREAS LIKE THAT SHOULD BE CHANGING MY CURSOR INDICATOR TO CLICKABLE").
    expect(got.cursor).toBe("pointer");
    await page.close();
  });

  test("the box is quiet: the same fill under the pointer, at rest and with the keyboard", async () => {
    const page = await open("no-preference");
    await page.mouse.move(5, 5);
    const rest = await fill(page);
    const box = (await page.locator(".nt-box").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height - 6);
    // The page sees the pointer over the box, and any hover ease has run out.
    await page.waitForFunction(() => document.querySelector(".nt-box")?.matches(":hover"));
    await eased(page);
    expect(await fill(page), "no hover lift (Leo 2026-10-18)").toBe(rest);
    await page.locator(".nt-field").focus();
    expect(await fill(page)).toBe(rest);
    await page.close();
  });
});
