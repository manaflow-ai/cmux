// The chat trajectory's text is one size at Compact, Default and Spacious (user 2026-11-19: "chat trajectory size
// should be same at normal and compact and spacious densities"): the host's page scales (`--cmux-interface-scale`,
// `--cmux-density-text-scale`) change with the density and the chat's text scale (`--cmux-chat-text-scale`,
// Typography+PageDensity.swift) does not, so a tool row, a meta line and a caption keep their size. Text Size (a
// chat scale over 1) still grows them. Real Chromium on the pane's CSS (browser/chat-text-density.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-text-density-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/chat-text-density.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 600, height: 400 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/chat-text-density.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The host's scales for a density (DesignSettings.interfaceScaleScript), then each probe's drawn size. */
  async function sizes(scales: { interface: number; densityText: number; chat: number }) {
    return page.evaluate((s) => {
      const root = document.documentElement.style;
      root.setProperty("--cmux-interface-scale", String(s.interface));
      root.setProperty("--cmux-density-text-scale", String(s.densityText));
      root.setProperty("--cmux-chat-text-scale", String(s.chat));
      const size = (id: string) => getComputedStyle(document.querySelector(`[data-testid="${id}"]`)!).fontSize;
      return { tool: size("tool"), detail: size("detail"), caption: size("caption") };
    }, scales);
  }

  describe("chat trajectory text across densities", () => {
    test("Compact, Default and Spacious draw the same sizes", async () => {
      const atDefault = await sizes({ interface: 1, densityText: 1, chat: 1 });
      expect(await sizes({ interface: 1, densityText: 0.9, chat: 1 })).toEqual(atDefault);
      expect(await sizes({ interface: 1.2, densityText: 1.2, chat: 1 })).toEqual(atDefault);
      expect(atDefault).toEqual({ tool: "14px", detail: "12px", caption: "11px" });
    });

    test("Text Size still grows them", async () => {
      const grown = await sizes({ interface: 1.2, densityText: 1.2, chat: 1.2 });
      expect(grown.detail).toBe("14.4px");
      expect(grown.caption).toBe("13.2px");
    });
  });
});
