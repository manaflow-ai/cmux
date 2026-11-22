// l10n-allow-file: test fixtures, not shipped UI.
// The diff viewer follows the app's density (Lawrence, 2026-11-20: "Compact density looks the same as
// comfortable on the diff page"). The host writes the density on the page's root
// (DesignSettings.interfaceScaleScript: --cmux-density-scale and --cmux-density-text-scale) and every
// page's chrome follows it; the diff page's toolbar, file bars and files list drew at fixed sizes. The
// code keeps its size at every density, as the chat's text does (fontZoom.ts; Cmd-+/- sizes it).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("diff-density.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("diff-density: skipping (run `bunx playwright install chromium`)");
    describe.skip("diff density", () => test("chromium", () => {}));
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

  /** The viewer's chrome sizes with the host's density scale on the root (none: no host, 1). */
  async function measure(scale: number | null) {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html`);
    await page.locator(".file-header").first().waitFor();
    if (scale != null) {
      // As the host's scale script does (DesignSettings.interfaceScaleScript): the density on the root,
      // then the change event.
      await page.evaluate((value) => {
        const root = document.documentElement.style;
        root.setProperty("--cmux-density-scale", String(value));
        root.setProperty("--cmux-density-text-scale", String(value));
        window.dispatchEvent(new Event("cmux-ui-scale-change"));
      }, scale);
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    }
    const sizes = await page.waitForFunction(() => {
      const deep = (selector: string): Element | null => {
        const search = (root: Document | ShadowRoot): Element | null => {
          const hit = root.querySelector(selector);
          if (hit) return hit;
          for (const element of root.querySelectorAll("*")) {
            const inner = element.shadowRoot && search(element.shadowRoot);
            if (inner) return inner;
          }
          return null;
        };
        return search(document);
      };
      const row = deep("[data-item-path]");
      const code = deep("[data-line-index] [data-column-content], [data-line-index]");
      if (!row || !code) return null;
      const header = document.querySelector(".file-header")!;
      return {
        toolbar: document.querySelector("#toolbar")!.getBoundingClientRect().height,
        header: header.getBoundingClientRect().height,
        headerText: parseFloat(getComputedStyle(header).fontSize),
        row: row.getBoundingClientRect().height,
        code: parseFloat(getComputedStyle(code).fontSize),
      };
    });
    const value = (await sizes.jsonValue())!;
    await page.close();
    console.log(`diff-density at ${scale ?? "no host"}: ${JSON.stringify(value)}`);
    return value;
  }

  test("at Compact the toolbar, file bars and files list draw smaller, the code does not", async () => {
    const standard = await measure(null);
    const compact = await measure(28 / 30);
    expect(compact.toolbar).toBeLessThan(standard.toolbar);
    expect(compact.header).toBeLessThan(standard.header);
    expect(compact.headerText).toBeLessThan(standard.headerText);
    expect(compact.row).toBeLessThan(standard.row);
    expect(compact.code).toBe(standard.code);
  });

  test("at the default density the viewer draws as it does with no host", async () => {
    expect(await measure(1)).toEqual(await measure(null));
  });
});
