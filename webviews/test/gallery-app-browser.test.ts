// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The whole app page (src/gallery/app.html). Leo, 2026-11-04: "I want the mock web view of the app
// to be legit like 'oh we can see the whole unified piece and it doesn't lag ... my computer/browser
// when I open it'". The page draws one window (sidebar, tab strips, panes) around ONE live stage and
// loads ONE gallery entry file, where the shell starts every entry file's load (about 2,300 modules,
// test/support/galleryFrame.ts). Real Chromium on the gallery dev server; CI fails the file when
// Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-app-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
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
    // The stage's modules transform once, so the page's own load is what the test times.
    await warmGalleryFrame(vite, "app.window", { browser, params: { variant: "new-tab" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(query: string) {
    const page = await browser!.newPage({ viewport: { width: 1280, height: 860 } });
    const errors: string[] = [];
    const entryFiles = new Set<string>();
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("request", (request) => {
      const file = /\/src\/[^?]*\.gallery\.tsx?/.exec(new URL(request.url()).pathname)?.[0];
      if (file) entryFiles.add(file);
    });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(`${base}/gallery/app.html?${query}`);
    await page.waitForFunction(
      () => !document.querySelector(".app-status")?.textContent?.startsWith("Loading"),
      undefined,
      {
        timeout: 120_000,
      },
    );
    return { page, errors, entryFiles };
  }

  describe("gallery whole app", () => {
    test("a chat scene: sidebar, tab strips and one live pane; one entry file loads", async () => {
      const { page, errors, entryFiles } = await open("scene=chat-session-info&layout=agent-right&window=pro14");
      try {
        const seen = await page.evaluate(() => ({
          rows: document.querySelectorAll(".app-row").length,
          active: [...document.querySelectorAll(".app-row[data-active] .app-row-title")].map(
            (node) => node.textContent,
          ),
          panes: document.querySelectorAll(".app-pane").length,
          stages: document.querySelectorAll("iframe").length,
          tabs: [...document.querySelectorAll(".app-tab")].map((node) => node.textContent),
          window: (() => {
            const style = (document.querySelector(".app-window") as HTMLElement).style;
            return [style.width, style.height];
          })(),
        }));
        expect(seen.rows).toBeGreaterThan(1);
        expect(seen.active).toEqual(["Add retries to the fetch helper"]);
        expect(seen.panes).toBe(2);
        expect(seen.stages).toBe(1);
        expect(seen.tabs).toEqual(["zsh", "Add retries to the fetch helper"]);
        expect(seen.window).toEqual(["1512px", "982px"]);
        // The live pane rendered the real agent pane at its pane's size.
        const stage = page.frameLocator("iframe.app-stage");
        await stage.locator(".acpmux-composer, .acpmux-picker-button").first().waitFor({ timeout: 60_000 });
        expect([...entryFiles].map((file) => file.replace(/^.*\/src\//, "src/"))).toEqual([
          "src/gallery/scenes/AppWindow.gallery.ts",
        ]);
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });

    test("the controls change the window in place and keep the query", async () => {
      const { page, errors } = await open("scene=new-tab");
      try {
        await page.getByLabel("Window").selectOption("air13");
        await page.getByLabel("Panes").selectOption("one");
        await page.getByLabel("Appearance").selectOption("light");
        const seen = await page.evaluate(() => ({
          search: location.search,
          scheme: document.documentElement.dataset.scheme,
          panes: document.querySelectorAll(".app-pane").length,
          active: document.querySelectorAll(".app-row[data-active]").length,
          tab: document.querySelector(".app-tab")?.textContent,
        }));
        expect(seen.search).toContain("window=air13");
        expect(seen.search).toContain("layout=one");
        expect(seen.scheme).toBe("light");
        expect(seen.panes).toBe(1);
        expect(seen.active).toBe(0);
        expect(seen.tab).toBe("New Tab");
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
  });
});
