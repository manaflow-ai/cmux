// The Quick Composer draws the Chief Dock beside its chat while the `chief-dock` experiment is on,
// its default (#21194). A rebase right after #21194 (e124e93b3e17) dropped the App's wiring that
// hands the dock to QuickSurface, so the dock never appeared in the app; only the gallery, which
// renders ChiefDock directly, still showed it. The experiment's off arm keeps the single chat.
//
// The real agent pane (vite.config.acpmux-pane.mjs) as the Quick Composer (the handshake's
// `surface: "quick"`), with a stand-in host and the in-page mock transport. Chromium; CI fails the
// file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/quick-composer-chief-dock.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("quick-composer-chief-dock.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("quick-composer-chief-dock: skipping (run `bunx playwright install chromium`)");
    describe.skip("Quick Composer Chief Dock", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function quickComposer(experiments?: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 720, height: 520 } });
    await page.addInitScript((experiments) => {
      const w = window as unknown as Record<string, unknown>;
      if (experiments) w.cmuxExperiments = experiments;
      w.webkit = { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } };
      w.cmuxAcpmuxActions = {
        ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, surface: "quick" }),
      };
    }, experiments);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-shell[data-surface='quick'] .acpmux-composer-prompt").waitFor();
    return page;
  }

  test("the Quick Composer shows the Chief Dock by default", async () => {
    const page = await quickComposer();
    await page.locator(".acpmux-shell[data-surface='quick'] .acpmux-chief-dock").waitFor({ timeout: 10_000 });
    expect(await page.locator(".acpmux-chief-dock").count()).toBe(1);
    await page.close();
  });

  test("with the experiment off the Quick Composer is a single chat", async () => {
    const page = await quickComposer({ "chief-dock": "off" });
    await page.waitForTimeout(500);
    expect(await page.locator(".acpmux-chief-dock").count()).toBe(0);
    await page.close();
  });
});
