// Reduce Motion keeps popup fades (POLISH: calm motion, no flash; plans/cmux-next/motion.md rule 7).
// Menus faded and scaled in only under `no-preference`, and the pages' shared stylesheet cut every
// animation and transition to 0.01ms under `reduce`, so a menu, tooltip or sheet appeared and left
// in one frame there. Under Reduce Motion a menu now fades in at its size, on every page.
// This opens the shared menu in the gallery, with the pages' shared stylesheet, under emulated Reduce Motion.
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

  test("under Reduce Motion a menu fades in at its size", async () => {
    const page = await browser!.newPage({ viewport: { width: 560, height: 420 }, reducedMotion: "reduce" });
    try {
      await page.goto(url());
      await ready(page);
      // Every page (settings, history, the editor) loads the shared desktop stylesheet.
      await page.addStyleTag({ content: desktopCss });
      await page.getByRole("button", { name: "Open demo menu" }).click();
      const popup = page.locator(".ui-popup").first();
      await popup.waitFor();
      const motion = await popup.evaluate((element) => {
        const style = getComputedStyle(element);
        const name = style.animationName;
        const frames = [...document.styleSheets]
          .flatMap((sheet) => [...sheet.cssRules])
          .find((rule): rule is CSSKeyframesRule => rule instanceof CSSKeyframesRule && rule.name === name);
        const properties = frames ? [...frames.cssRules].flatMap((frame) => [...(frame as CSSKeyframeRule).style]) : [];
        return { duration: parseFloat(style.animationDuration) * 1000, properties: [...new Set(properties)].sort() };
      });
      expect(motion.duration).toBeGreaterThanOrEqual(100);
      expect(motion.properties).toEqual(["opacity"]);
    } finally {
      await page.close();
    }
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
        // The open settles: its fade-in has run to the end.
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
        // Both fades start as the dialog opens; a transition that never runs leaves the wait to time out.
        await page
          .waitForFunction(() => new Set((window as unknown as { faded: string[] }).faded).size === 2, undefined, {
            timeout: 5_000,
          })
          .catch(() => {});
        expect(await faded()).toEqual(["backdrop", "dialog"]);
        await forget();
        await page.keyboard.press("Escape");
        await page.locator(".ui-dialog").waitFor({ state: "detached" });
        expect(await faded()).toEqual(["backdrop", "dialog"]);
      } finally {
        await page.close();
      }
    });
  }
});
