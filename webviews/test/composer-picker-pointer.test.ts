// cmux-web-test-timeout: 300
// Real browser default focus is essential here: synthetic mousedown cannot prove it stays on the trigger.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { createServer, type ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-picker-pointer.test.ts", async () => {
  setDefaultTimeout(120_000);
  let vite: ViteDevServer;
  const browsers = new Map<string, Browser>();
  const entry = "agent-pane.picker-pointer";
  const captureDir = process.env.CMUX_PICKER_CAPTURE_DIR;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const)
      browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, entry, {
      browser: browsers.get("chromium"),
      params: { variant: "closed" },
    });
    if (captureDir) await mkdir(captureDir, { recursive: true });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"]) {
    for (const button of ["right", "middle", "left"] as const) {
      test(`${engine}: ${button} press preserves picker focus and selects only with the primary button`, async () => {
        const page = await browsers.get(engine)!.newPage({ viewport: { width: 520, height: 400 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "closed", frame: "component", width: 520, theme: "Catppuccin Mocha" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const trigger = page.getByRole("combobox", { name: "Actions" });
          await trigger.click();
          await page.getByRole("option", { name: "Mention file" }).click({ button });
          // Capture before the assertions so the same harness records the broken base as well.
          if (captureDir)
            await page.screenshot({ path: path.join(captureDir, `${engine}-${button}.png`) });
          const receipt = page.getByTestId("picker-receipt");
          expect(await receipt.textContent()).toBe(
            button === "left" ? "Selected: mention" : "No action selected",
          );
          expect(await trigger.getAttribute("aria-expanded")).toBe(
            button === "left" ? "false" : "true",
          );
          expect(await trigger.evaluate((node) => node === document.activeElement)).toBe(true);
          if (button !== "left") {
            // Do not refocus: the rejected press must leave the existing keyboard path usable.
            await page.keyboard.press("Home");
            await page.keyboard.press("ArrowDown");
            await page.keyboard.press("Enter");
            expect(await receipt.textContent()).toBe("Selected: mention");
            expect(await trigger.getAttribute("aria-expanded")).toBe("false");
          }
          // Real keyup/click sequencing: Space picks once and does not reopen the menu.
          await trigger.focus();
          await page.keyboard.press("ArrowDown");
          await page.keyboard.press("Space");
          expect(await receipt.textContent()).toBe("Selected: mention, attach");
          expect(await trigger.getAttribute("aria-expanded")).toBe("false");
        } finally {
          await page.close();
        }
      });
    }
  }
});
