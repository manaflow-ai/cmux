// l10n-allow-file: probe diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Temporary probe (removed before landing): captures the reply thumbnail at rest and on hover.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("zz-reply-thumbs-probe-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.reply-thumbs";
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT || "/tmp/probe";
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "wide-strip" } });
    await mkdir(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  const floating = () =>
    [...document.querySelectorAll("body *")]
      .filter((node) => {
        const style = getComputedStyle(node);
        return (style.position === "fixed" || style.position === "absolute") && node.getBoundingClientRect().width > 60;
      })
      .map((node) => {
        const box = node.getBoundingClientRect();
        return `${node.tagName}.${String((node as HTMLElement).className).slice(0, 90)} ${Math.round(box.x)},${Math.round(box.y)} ${Math.round(box.width)}x${Math.round(box.height)}`;
      });
  for (const variant of ["wide-strip", "tall-phone", "shapes"])
    for (const colorScheme of ["dark", "light"] as const)
      test(`${variant} ${colorScheme}`, async () => {
        const page = await browser!.newPage({ viewport: { width: 760, height: 720 }, colorScheme, deviceScaleFactor: 2 });
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame(ENTRY, { variant, colorScheme, width: 760, height: 720 }));
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        await page.waitForTimeout(600);
        const name = `${variant}-${colorScheme}`;
        await page.screenshot({ path: path.join(out, `${name}-rest.png`) });
        const before = await page.evaluate(floating);
        const thumb = page.locator(".cv-thumb").first();
        console.log(name, "thumb", JSON.stringify(await thumb.boundingBox()), await thumb.evaluate((n) => n.outerHTML.slice(0, 300)));
        if (variant !== "wide-strip") return void (await page.close());
        await thumb.hover();
        await page.waitForTimeout(1500);
        console.log(name, "after thumb hover", JSON.stringify((await page.evaluate(floating)).filter((x) => !before.includes(x))));
        await page.screenshot({ path: path.join(out, `${name}-hover-thumb.png`) });
        await page.mouse.move(5, 5);
        await page.waitForTimeout(500);
        const chip = page.locator(".cv-li, li").locator("a, .cv-chip, button").first();
        console.log(name, "chip", await chip.evaluate((n) => n.outerHTML.slice(0, 200)));
        await chip.hover();
        await page.waitForTimeout(1500);
        console.log(name, "after chip hover", JSON.stringify((await page.evaluate(floating)).filter((x) => !before.includes(x))));
        await page.screenshot({ path: path.join(out, `${name}-hover-chip.png`) });
        await page.close();
      });
});
