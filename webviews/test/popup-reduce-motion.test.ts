// Reduce Motion keeps popup close fades (POLISH: calm motion, no flash; plans/cmux-next/motion.md
// rule 7). The pages' shared stylesheet cut every animation and transition to 0.01ms under
// `reduce`, so a menu, tooltip or sheet left in one frame there. A menu opens in one frame in every
// motion setting (Leo 2026-10-24: "No fade in ever for any of these"; test/popover-instant-open.test.ts)
// and fades as it closes. This opens the shared menu in the gallery, with the pages' shared
// stylesheet, under emulated Reduce Motion.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popup-reduce-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("popup-reduce-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("popup reduce motion", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const desktopCss = readFileSync(path.join(webviews, "src/pages/shared/desktop.css"), "utf8");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (reduced = true, entry = "ui.menu") =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { reducedMotion: reduced ? 1 : undefined })}`;

  async function ready(page: Page) {
    for (;;) {
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        return;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["ui.menu", "ui.dialog"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const reduced of [false, true]) {
    test(`a menu fades out when it closes${reduced ? " under Reduce Motion" : ""}`, async () => {
      // POLISH audit batch 2 (cx-2grmt): a closed menu vanished in one frame.
      const page = await browser!.newPage({
        viewport: { width: 560, height: 420 },
        reducedMotion: reduced ? "reduce" : "no-preference",
      });
      try {
        await page.goto(url(reduced));
        await ready(page);
        await page.addStyleTag({ content: desktopCss });
        await page.getByRole("button", { name: "Open demo menu" }).click();
        const popup = page.locator(".ui-popup").first();
        await popup.waitFor();
        // The open settles: nothing it started is still running.
        await popup.evaluate((element) => Promise.all(element.getAnimations({ subtree: true }).map((a) => a.finished)));
        await page.evaluate(() => {
          const faded: string[] = [];
          (window as unknown as { faded: string[] }).faded = faded;
          const record = (event: Event) => {
            const target = event.target as Element;
            if (!target.classList?.contains("ui-popup")) return;
            if (event instanceof TransitionEvent && event.propertyName !== "opacity") return;
            faded.push(event.type);
          };
          document.addEventListener("transitionrun", record, true);
          document.addEventListener("animationstart", record, true);
        });
        await page.keyboard.press("Escape");
        await popup.waitFor({ state: "detached" });
        const faded = await page.evaluate(() => (window as unknown as { faded: string[] }).faded);
        expect(faded.length).toBeGreaterThan(0);
      } finally {
        await page.close();
      }
    });
  }

  for (const reduced of [false, true]) {
    test(`a dialog and its backdrop fade in and out${reduced ? " under Reduce Motion" : ""}`, async () => {
      // POLISH audit batch 3 (cx-2grmt): a page's dialog and its backdrop appeared and left in one
      // frame, so the page darkened at once.
      const page = await browser!.newPage({
        viewport: { width: 560, height: 360 },
        reducedMotion: reduced ? "reduce" : "no-preference",
      });
      try {
        await page.goto(url(reduced, "ui.dialog"));
        await ready(page);
        await page.addStyleTag({ content: desktopCss });
        await page.evaluate(() => {
          const faded: string[] = [];
          (window as unknown as { faded: string[] }).faded = faded;
          document.addEventListener(
            "transitionrun",
            (event) => {
              const target = event.target as Element;
              // Alert polish: the dialog also grows in and shrinks out (scale), as the native one,
              // except under Reduce Motion, where it only fades.
              if (event.propertyName === "scale" && target.classList?.contains("ui-dialog")) faded.push("dialog-scale");
              if (event.propertyName !== "opacity") return;
              if (target.classList?.contains("ui-dialog")) faded.push("dialog");
              if (target.classList?.contains("ui-backdrop")) faded.push("backdrop");
            },
            true,
          );
        });
        const faded = () => page.evaluate(() => [...new Set((window as unknown as { faded: string[] }).faded)].sort());
        const forget = () => page.evaluate(() => ((window as unknown as { faded: string[] }).faded.length = 0));
        await page.getByRole("button", { name: "Open demo dialog" }).click();
        await page.locator(".ui-dialog").waitFor();
        // Both fades (and the scale, with motion) start as the dialog opens; a transition that never
        // runs leaves the wait to time out.
        const expected = reduced ? ["backdrop", "dialog"] : ["backdrop", "dialog", "dialog-scale"];
        await page
          .waitForFunction(
            (count) => new Set((window as unknown as { faded: string[] }).faded).size === count,
            expected.length,
            { timeout: 5_000 },
          )
          .catch(() => {});
        expect(await faded()).toEqual(expected);
        await forget();
        await page.keyboard.press("Escape");
        await page.locator(".ui-dialog").waitFor({ state: "detached" });
        expect(await faded()).toEqual(expected);
      } finally {
        await page.close();
      }
    });
  }
});
