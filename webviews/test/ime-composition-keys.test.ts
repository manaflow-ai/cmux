// cmux-web-test-timeout: 240
// IME-KEYS (cx-dd5b4) in real engines (headless Chromium and WebKit from Playwright), on a real
// page: the History page's dev entry (/history/?mock, the in-memory mock provider).
//
// While an input method composes, the engine still sends keydown for the keys the IME uses:
// Escape cancels the composition, ArrowDown moves in the candidate list, Return commits. The
// History search field acts on those keys (Escape clears the search, ArrowDown moves the list
// selection, Return opens the selected entry), so a Japanese or Chinese user lost the search text
// when cancelling a conversion. A composition key must reach the input method only; the same keys
// outside composition keep working.
//
// The keys are dispatched the way the engines send them: `isComposing: true` with keyCode 229
// during composition (Chromium, WebKit), and keyCode 229 with `isComposing: false` for the key
// that ends a composition after `compositionend` (WebKit's order).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("ime-composition-keys.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const installed: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      installed.push(engine);
    } catch {
      console.warn(`ime-composition-keys: skipping ${engine[0]} (run \`bunx playwright install chromium webkit\`)`);
    }
  }

  let server: ChildProcess | null = null;
  let base = "";

  beforeAll(async () => {
    if (installed.length === 0) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
    });
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/history/?mock");
  }, 240_000);

  afterAll(() => {
    stopDevServer(server);
  });

  /** Dispatches a keydown on the focused element as the engine does for an IME key. */
  async function imeKey(page: Page, key: string, isComposing: boolean) {
    return page.evaluate(
      ({ key, isComposing }) => {
        const target = document.activeElement ?? document.body;
        const event = new KeyboardEvent("keydown", {
          key,
          code: key,
          keyCode: 229,
          isComposing,
          bubbles: true,
          cancelable: true,
        });
        // Some engines ignore keyCode in the init dictionary.
        if (event.keyCode !== 229) Object.defineProperty(event, "keyCode", { get: () => 229 });
        target.dispatchEvent(event);
        return event.defaultPrevented;
      },
      { key, isComposing },
    );
  }

  const selectedRow = (page: Page) =>
    page.evaluate(
      () => document.querySelector(".history-row[aria-selected='true'] .history-row-title")?.textContent ?? null,
    );

  for (const [name, engine] of installed) {
    describe(`IME composition keys (${name})`, () => {
      let browser: Browser;
      let page: Page;

      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
        page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
        await installPaintedFrames(page);
        await page.goto(`${base}/history/?mock`);
        await page.waitForSelector(".history-search");
        await page.waitForSelector(".history-row");
      });

      afterAll(async () => {
        await browser?.close();
      });

      test("Escape that cancels a composition keeps the search text; a plain Escape clears it", async () => {
        await page.focus(".history-search");
        await page.keyboard.type("re");
        await page.waitForFunction(
          () => (document.querySelector(".history-search") as HTMLInputElement).value === "re",
        );

        // Chromium and WebKit during composition.
        expect(await imeKey(page, "Escape", true)).toBe(false);
        // WebKit: the key that ends the composition, after compositionend.
        expect(await imeKey(page, "Escape", false)).toBe(false);
        // The page has handled both keys and drawn what they did.
        await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
        expect(await page.$eval(".history-search", (field) => (field as HTMLInputElement).value)).toBe("re");

        await page.keyboard.press("Escape");
        await page.waitForFunction(() => (document.querySelector(".history-search") as HTMLInputElement).value === "");
      });

      test("ArrowDown in the candidate list leaves the list selection; a plain ArrowDown moves it", async () => {
        await page.focus(".history-search");
        const before = await selectedRow(page);
        await imeKey(page, "ArrowDown", true);
        await imeKey(page, "ArrowDown", false);
        await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
        expect(await selectedRow(page)).toBe(before);

        await page.keyboard.press("ArrowDown");
        await page.waitForFunction((was) => {
          const now =
            document.querySelector(".history-row[aria-selected='true'] .history-row-title")?.textContent ?? null;
          return now !== was;
        }, before);
      });

      test("the layer is installed before page code (one layer for every page)", async () => {
        expect(await page.evaluate(() => document.documentElement.hasAttribute("data-cmux-ime-keys"))).toBe(true);
      });
    });
  }
});
