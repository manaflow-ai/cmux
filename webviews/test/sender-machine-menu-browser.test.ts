// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// The machine after a sender on a received line is a menu (IncomingMessageCard.tsx MachineMenu):
// the chats listed on that machine and Copy machine name (Leo, 2026-11-03, on that line: "so
// what's this depicting? session name, then machine? hm i wonder if there's anything interesting
// we can click around wrt machines"). Real Chromium on the gallery (`agent-pane.remote-sender`
// `machine`): a click on the machine opens its menu, which lists studio-mac's live chats; its
// highlight is the machine's name alone, never the dot before it. With FAST_CHECKS_OUT set it
// writes 2x light and dark stills of the open menu.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("sender-machine-menu-browser.test.ts", async () => {
  const ENTRY = "agent-pane.remote-sender";
  const VARIANT = "machine";
  const MACHINE = 'button[data-menu="sender-machine"]';
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("sender-machine-menu: chromium cannot launch here; skipping");
    describe.skip("sender machine menu", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, ENTRY, { params: { variant: VARIANT } });
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (colorScheme: "light" | "dark"): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({
      viewport: { width: 760, height: 420 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, colorScheme, width: 760, height: 420 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(MACHINE);
    return page;
  };

  for (const colorScheme of ["light", "dark"] as const) {
    test(`the machine opens a menu of its chats; only its name lights (${colorScheme})`, async () => {
      const page = await open(colorScheme);
      try {
        const machine = page.locator(MACHINE).last();
        expect(await machine.textContent()).toBe("studio-mac");
        await machine.click();
        await page.waitForSelector('[role="menuitem"]');
        // The still first, so a red run still shows what it drew.
        if (out) await page.screenshot({ path: path.join(out, `sender-machine-menu-${colorScheme}.png`) });
        const items = await page.locator('[role="menuitem"]').allTextContents();
        expect(items.map((item) => item.trim())).toEqual([
          "codex-lane",
          "perf-diff-poll-events",
          "session-info",
          "Copy machine name",
        ]);
        // Lit while its menu is open: the name's tint, not the button's (which holds the dot too).
        const lit = await machine.evaluate((node) => ({
          button: getComputedStyle(node).backgroundColor,
          name: getComputedStyle(node.querySelector(".cv-received__host-name")!).backgroundColor,
        }));
        expect(lit.button).toBe("rgba(0, 0, 0, 0)");
        expect(lit.name).not.toBe("rgba(0, 0, 0, 0)");
      } finally {
        await page.close();
      }
    });
  }
});
