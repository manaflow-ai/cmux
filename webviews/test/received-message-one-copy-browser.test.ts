// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// Another agent's message has one Copy (leo-workspace design/chat-transcript.md: "Each message has
// one Copy control"; Leo, 2026-10-27: "why are there two copy-paste symbols? I mean, two copy
// symbols"). Closed, its line's hover row holds it; opened, the card's top-right corner does (Leo,
// 2026-10-29: "wouldnt it be a little copy symbol on the top right within this card?", #28057), and
// the line's hover row drew a second one beside the time. Real Chromium on the gallery's
// `agent-pane.incoming-message` entry, the pointer on the message's line as a person reads it. With
// FAST_CHECKS_OUT set it writes 2x light and dark stills of the opened message.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("received-message-one-copy-browser.test.ts", async () => {
  const ENTRY = "agent-pane.incoming-message";
  const LINE = ".cv-received .cv-disclosure__toggle";
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("received-message-one-copy: chromium cannot launch here; skipping");
    describe.skip("received message one copy", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { params: { variant: "opened" } });
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, colorScheme: "light" | "dark"): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({
      viewport: { width: 760, height: 520 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, colorScheme, width: 760, height: 520 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(LINE);
    return page;
  };

  /// The Copy buttons of the first received message, the line's hover row and its opened card.
  const copies = (page: Page) =>
    page.evaluate((line) => {
      const message = document.querySelector(line)!.closest(".cv-received")!;
      const names = [...message.querySelectorAll<HTMLButtonElement>("button[aria-label]")].map(
        (button) => button.getAttribute("aria-label") ?? "",
      );
      return {
        expanded: document.querySelector(line)!.getAttribute("aria-expanded"),
        copy: names.filter((name) => name === "Copy").length,
        corner: message.querySelectorAll(".cv-card-copy button").length,
      };
    }, LINE);

  for (const colorScheme of ["light", "dark"] as const) {
    test(`a closed message's line has one Copy (${colorScheme})`, async () => {
      const page = await open("long", colorScheme);
      try {
        await page.hover(LINE);
        expect(await copies(page)).toEqual({ expanded: "false", copy: 1, corner: 0 });
      } finally {
        await page.close();
      }
    });

    test(`an opened message has one Copy, the card's corner (${colorScheme})`, async () => {
      const page = await open("opened", colorScheme);
      try {
        await page.waitForSelector(`${LINE}[aria-expanded="true"]`);
        await page.waitForSelector(".cv-received__text");
        // The pointer on the line, where the hover row shows.
        await page.hover(LINE);
        // The still first, so a red run still shows what it drew.
        if (out) await page.screenshot({ path: path.join(out, `received-message-opened-${colorScheme}-chromium.png`) });
        expect(await copies(page)).toEqual({ expanded: "true", copy: 1, corner: 1 });
        // Closed again, the line's row has its Copy back.
        await page.click(LINE);
        await page.waitForSelector(`${LINE}[aria-expanded="false"]`);
        // Its panel (and the corner Copy in it) leaves once the close has played.
        await page.waitForFunction(
          (line) => !document.querySelector(line)!.closest(".cv-received")!.querySelector(".cv-card-copy"),
          LINE,
        );
        await page.hover(LINE);
        expect((await copies(page)).copy).toBe(1);
      } finally {
        await page.close();
      }
    });
  }
});
