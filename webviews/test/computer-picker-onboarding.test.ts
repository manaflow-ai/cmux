// Fresh-home discovery uses the real New Tab and chat composer, with Labs left off.
// The host-call assertions prove the menu dispatch; native card/sign-in integration is separate.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("computer-picker-onboarding.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const entries = ["agent-pane.new-tab", "agent-pane.composer-strip"] as const;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entries, { browser, params: { variant: "computer-first-setup" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const entry of entries) {
    for (const colorScheme of ["light", "dark"] as const) {
      test(`${entry} ${colorScheme}: first-computer setup dispatches the existing app actions`, async () => {
        const page = await browser!.newPage({ viewport: { width: 900, height: 650 }, colorScheme });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "computer-first-setup", colorScheme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const computer = page.locator('.acpmux-location-picker[data-kind="computer"] > button');
          if (!(await computer.getAttribute("aria-expanded"))?.includes("true")) await computer.click();
          const menu = page.locator('.acpmux-location-menu[aria-label="Computer"]');
          const add = menu.getByRole("button", { name: "Add a computer…", exact: true });
          const cloud = menu.getByRole("button", { name: /^New Cloud Machine…/ });
          await add.waitFor();
          expect(await add.isVisible()).toBe(true);
          expect(await cloud.isVisible()).toBe(true);
          expect(await page.locator(".acpmux-env-popover").count()).toBe(0);
          const artifacts = process.env.CMUX_COMPUTER_SETUP_ARTIFACTS;
          if (artifacts) {
            mkdirSync(artifacts, { recursive: true });
            await page.screenshot({ path: path.join(artifacts, `${entry}-${colorScheme}.png`) });
          }
          await add.click();
          await page.waitForFunction(() =>
            (
              window as unknown as { cmuxGalleryLog: { method: string; params?: { id?: string } }[] }
            ).cmuxGalleryLog.some((call) => call.method === "action.run" && call.params?.id === "device.add"),
          );
          await computer.click();
          await cloud.click();
          await page.waitForFunction(() =>
            (
              window as unknown as { cmuxGalleryLog: { method: string; params?: { id?: string } }[] }
            ).cmuxGalleryLog.some((call) => call.method === "action.run" && call.params?.id === "newCloudMachine"),
          );
        } finally {
          await page.close();
        }
      });
    }
  }
});
