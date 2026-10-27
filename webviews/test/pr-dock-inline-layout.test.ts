// l10n-allow-file: synthetic gallery fixture and test labels, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { chromium, type Browser } from "playwright";
import { createServer, type ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("pr-dock-inline-layout.test.ts", () => {
  setDefaultTimeout(120_000);
  const captures = process.env.CMUX_PR_DOCK_CAPTURE ?? path.resolve(import.meta.dir, "../artifacts/pr-dock");
  let browser: Browser;
  let vite: ViteDevServer;
  beforeAll(async () => {
    mkdirSync(captures, { recursive: true });
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.pr-dock", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    execFileSync("tar", ["-czf", `${captures}.tgz`, "-C", captures, "."]);
  });

  for (const width of [760, 320])
    test(`${width}px: PR pills share the action row and overflow never moves the transcript`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 420 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "compact-count", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const dock = page.locator(".acpmux-pr-dock");
        await dock.waitFor();
        await page.screenshot({
          type: "jpeg",
          quality: 75,
          path: `${captures}/closed-${width}.jpg`,
        });
        expect(await dock.evaluate((node) => !!node.closest(".cv-turn-actions"))).toBe(true);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeGreaterThan(0);
        expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBeLessThanOrEqual(2);
        expect(await dock.locator(".acpmux-pr-dock__dismiss").count()).toBe(0);
        const geometry = () =>
          page.evaluate(() =>
            [...document.querySelectorAll(".acpmux-row, .acpmux-composer")].map((node) => {
              const box = node.getBoundingClientRect();
              return { y: box.y, height: box.height };
            }),
          );
        const before = await geometry();
        const more = dock.locator(".acpmux-pr-dock__more");
        await more.click();
        await page.locator(".acpmux-pr-dock__popover").waitFor();
        expect(await geometry()).toEqual(before);
        expect(await page.locator(".acpmux-pr-dock__popover .acpmux-pr-dock__bar").count()).toBe(
          4 - (await dock.locator(".acpmux-pr-dock__bar").count()),
        );
        await page.screenshot({
          type: "jpeg",
          quality: 75,
          path: `${captures}/open-${width}.jpg`,
        });
        await page.keyboard.press("Escape");
        expect(await more.getAttribute("aria-expanded")).toBe("false");
        await page.waitForFunction(() => document.activeElement?.matches(".acpmux-pr-dock__more"));
        expect(await geometry()).toEqual(before);
      } finally {
        await page.close();
      }
    });
  for (const variant of [
    "no-footer",
    "received",
    "one-first",
    "tight",
    "code-tail",
    "table-tail",
    "math-tail",
    "rule-tail",
    "diagram-tail",
    "notes-tail",
  ])
    for (const width of [760, 320])
      test(`${variant} at ${width}px keeps content and pills within the message`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 660 } });
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant, width })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-pr-dock").waitFor();
          expect(await page.locator(".acpmux-pr-dock").count()).toBe(1);
          await page.screenshot({
            type: "jpeg",
            quality: 75,
            path: `${captures}/${variant}-${width}.jpg`,
          });
          const boxes = await page.locator(".acpmux-pr-dock").evaluate((node) => {
            const row = node.closest(".acpmux-row")!.getBoundingClientRect();
            return [...node.querySelectorAll("a,button")].map((child) => {
              const rect = child.getBoundingClientRect();
              return { left: rect.left >= row.left, right: rect.right <= row.right + 1 };
            });
          });
          for (const box of boxes) expect(box).toEqual({ left: true, right: true });
          if (variant === "notes-tail") {
            expect(await page.locator(".cv-footnote").last().locator(".acpmux-pr-dock").count()).toBe(1);
          }
          if (variant === "no-footer") {
            const widths = await page.locator(".acpmux-assistant").evaluate((node) => {
              const md = node.querySelector(".cv-md")!;
              return {
                body: md.getBoundingClientRect().width,
                paragraph: md.querySelector(".cv-p")!.getBoundingClientRect().width,
                code: md.querySelector(".cv-codeblock")!.getBoundingClientRect().width,
              };
            });
            expect(widths.paragraph).toBe(widths.body);
            expect(widths.code).toBe(widths.body);
          }
        } finally {
          await page.close();
        }
      });
});
