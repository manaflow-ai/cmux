// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// A message from another session carries no pin and no hover Copy, no "Open chat" and no "Read after
// this step"; its sender's name on the left is what opens that session (Leo, 2026-10-30: "all these
// weird button stuff from messages from other sessions... weird to be able to pin them etc and an
// entire stupid unstyled open chat button when you should just be abel to click on their names").
// Real Chromium on the gallery, the pointer on the message's line as a person reads it: a waiting
// message in its opened group (`agent-pane.hover-fade` `received`) and a delivered one
// (`agent-pane.incoming-message` `sender-hover`). With FAST_CHECKS_OUT set it writes 2x light and
// dark stills of each.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("other-session-message-actions-browser.test.ts", async () => {
  const LINE = ".cv-received > .cv-disclosure__line";
  const STATES = [
    { name: "waiting", entry: "agent-pane.hover-fade", variant: "received" },
    { name: "delivered", entry: "agent-pane.incoming-message", variant: "sender-hover" },
  ] as const;
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("other-session-message-actions: chromium cannot launch here; skipping");
    describe.skip("other session message actions", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, STATES[0].entry, { params: { variant: STATES[0].variant } });
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, colorScheme: "light" | "dark"): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({
      viewport: { width: 760, height: 420 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme, width: 760, height: 420 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(LINE);
    return page;
  };

  for (const state of STATES) {
    for (const colorScheme of ["light", "dark"] as const) {
      test(`${state.name}: no pin, no hover Copy, no Open chat; the name opens the chat (${colorScheme})`, async () => {
        const page = await open(state.entry, state.variant, colorScheme);
        try {
          const line = page.locator(LINE).last();
          await line.hover({ position: { x: 360, y: 8 } });
          await page.waitForFunction(
            (selector) => {
              const hover = [...document.querySelectorAll(selector)].at(-1)?.querySelector(".cv-received__hover");
              return hover !== null && hover !== undefined && getComputedStyle(hover).opacity === "1";
            },
            LINE,
            { timeout: 5_000 },
          );
          // The still first, so a red run still shows what it drew.
          if (out)
            await page.screenshot({
              path: path.join(out, `other-session-${state.name}-${colorScheme}.png`),
            });
          const found = await line.evaluate((node) => {
            const hover = node.querySelector(".cv-received__hover")!;
            return {
              pin: hover.querySelectorAll(".cv-message-pin").length,
              copy: hover.querySelectorAll('button[aria-label="Copy"]').length,
              name: node.querySelectorAll("button.cv-received__from--open").length,
              text: node.closest(".cv-received")!.textContent ?? "",
            };
          });
          expect(found.pin).toBe(0);
          expect(found.copy).toBe(0);
          expect(found.name).toBe(1);
          expect(found.text).not.toMatch(/Open chat|Read after this/);
        } finally {
          await page.close();
        }
      });
    }
  }
});
