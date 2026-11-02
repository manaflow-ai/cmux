// The classic New Tab's stepped footer follows its pane, even in a wide window.
// Render the real NewTabPage and its model/access chips through the pane's mock transport.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-footer-fit.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const capture = process.env.CMUX_FOOTER_CAPTURE_DIR;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    if (capture) fs.mkdirSync(capture, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const plainFooter of [false, true]) {
    test(`${plainFooter ? "plain" : "stepped"} footer follows the classic New Tab content width`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1280, height: 700 } });
      try {
        await page.addInitScript(() => {
          const newTab = {
            kind: "agent",
            template: "classic",
            hotkeys: {},
            home: "/Users/you",
            projects: [],
            lastPicks: { global: { harness: "claude", model: "claude-opus-5-5" }, folders: [] },
          };
          localStorage.setItem("cmux.composer.look", "claude");
          Object.assign(window, {
            __cmuxNewTabContext: newTab,
            webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
            cmuxAcpmuxActions: {
              ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
            },
          });
        });
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/`);
        const root = page.locator(".acpmux-newtab");
        const footer = root.locator(".acpmux-composer-foot");
        await footer.locator(".acpmux-model .acpmux-picker-button").waitFor();
        await page.evaluate((plainFooter) => window.cmuxAcpmuxComposer?.({ plainFooter }), plainFooter);
        await page.evaluate(() => document.fonts.ready);

        // Keep the viewport wide. The same pane narrows then widens, as a split does.
        const measured: { model: string; fullVisible: boolean; plain: boolean }[] = [];
        for (const width of [440, 880]) {
          await root.evaluate((node, width) => {
            const shell = node.closest<HTMLElement>(".acpmux-shell")!;
            shell.style.width = `${width}px`;
            shell.style.flex = "none";
          }, width);
          // raf-read: the ResizeObserver applies row fit before the following painted frame.
          await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
          if (capture)
            await root.screenshot({ path: path.join(capture, `${plainFooter ? "plain" : "stepped"}-${width}.png`) });
          measured.push(
            await footer.evaluate((bar) => {
              const full = bar.querySelector('[data-fit-part="model"][data-fit-forms="full"]');
              if (!full) throw new Error("the real model chip must expose its full label");
              return {
                model: bar.getAttribute("data-fit-model") ?? "full",
                fullVisible: getComputedStyle(full).visibility !== "hidden",
                plain: bar.getAttribute("data-footer-look") === "plain",
              };
            }),
          );
        }
        expect(measured).toEqual([
          { model: plainFooter ? "full" : "family", fullVisible: plainFooter, plain: plainFooter },
          { model: "full", fullVisible: true, plain: plainFooter },
        ]);
        expect(await root.evaluate((node) => getComputedStyle(node).containerName)).toBe("composer");
      } finally {
        await page.close();
      }
    });
  }
});
