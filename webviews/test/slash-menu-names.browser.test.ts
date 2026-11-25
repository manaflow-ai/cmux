// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The composer's `/` list in a narrow chat pane (the real app, 2026-11-21: an agent chat beside
// Home, its composer about 370 px wide). A row is the command, its arguments, what it does and its
// source. The command and its arguments are what a person types, so they stay whole; what it does
// gives up its room first ("/customi… <chang…" with "Customize cmux by askin…" still shown was the
// wrong way round). Only a row too narrow for the command alone may cut it.
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("slash-menu-names.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.composer";
  const VARIANT = "slash-menu-full";
  const WIDTHS = [400, 340] as const;
  const LOOKS = [
    { name: "light", params: { colorScheme: "light" } },
    { name: "large", params: { colorScheme: "dark", interfaceScale: 1.25 } },
  ] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  }, 300_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("a narrow chat's / list keeps each command and its arguments whole", () => {
    for (const width of WIDTHS)
      for (const look of LOOKS)
        test(`${width} px ${look.name}`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: 640 } });
          try {
            const port = (vite!.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, reducedMotion: "true", ...look.params })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
              timeout: 90_000,
            });
            await page.waitForSelector("#acpmux-slash-menu [role=option]");
            // "/c": cmux's /customize <change> (a long name, an argument and a long description)
            // with the agent's own /c commands.
            await page.keyboard.type("c");
            await page.waitForFunction(() =>
              [...document.querySelectorAll("#acpmux-slash-menu [role=option]")].some((row) =>
                row.textContent?.includes("customize"),
              ),
            );
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            const found = await page.evaluate(() => {
              const cut = (element: HTMLElement | null) => !!element && element.scrollWidth > element.clientWidth + 0.5;
              return [...document.querySelectorAll<HTMLElement>("#acpmux-slash-menu [role=option]")].map((row) => {
                const name = row.querySelector<HTMLElement>(".acpmux-slash-name");
                const hint = row.querySelector<HTMLElement>(".acpmux-slash-hint");
                const description = row.querySelector<HTMLElement>(".acpmux-slash-description");
                return {
                  text: row.textContent,
                  nameCut: cut(name),
                  hintCut: cut(hint),
                  descriptionShown: description?.clientWidth ?? 0,
                };
              });
            });
            console.log(`slash-menu-names: ${width} ${look.name} ${JSON.stringify(found)}`);
            expect(found.some((row) => row.text?.includes("customize"))).toBe(true);
            expect(found.filter((row) => row.nameCut || row.hintCut).map((row) => row.text)).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
