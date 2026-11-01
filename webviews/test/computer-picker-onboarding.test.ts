// Fresh-home discovery uses the real New Tab and chat composer, with Labs left off: the composer's
// environment picker is not behind Labs (Leo, 2026-10-30), and with only this Mac listed it offers
// Cloud (New Cloud Machine) in its list and Add Machine… and New Cloud Machine… in the control's
// right-click menu, from a started chat too (#27083). The list is This Mac and Cloud, one line each,
// with the setup actions on the right-click menu (#28999).
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
          const computer = page.locator('.acpmux-location-picker[data-kind="computer"] button').first();
          const log = () =>
            page.evaluate(() =>
              (window as unknown as { cmuxGalleryLog: { method: string; params?: { id?: string } }[] }).cmuxGalleryLog
                .filter((call) => call.method === "action.run")
                .map((call) => call.params?.id),
            );
          // The right-click menu holds the setup actions. The New Tab scene opens with the list open;
          // close it first so its popover does not cover the control.
          if ((await computer.getAttribute("aria-expanded"))?.includes("true")) {
            await page.keyboard.press("Escape");
            await page.waitForFunction(
              () =>
                document
                  .querySelector('.acpmux-location-picker[data-kind="computer"] button')
                  ?.getAttribute("aria-expanded") !== "true",
            );
          }
          await computer.click({ button: "right" });
          const more = page.getByRole("menu");
          const add = more.getByRole("menuitem", { name: /Add Machine…/ });
          const newCloud = more.getByRole("menuitem", { name: /New Cloud Machine…/ });
          await add.waitFor();
          const items = await more.getByRole("menuitem").allTextContents();
          expect(await add.count(), items.join(" | ")).toBe(1);
          expect(await newCloud.count(), items.join(" | ")).toBe(1);
          const artifacts = process.env.CMUX_COMPUTER_SETUP_ARTIFACTS;
          if (artifacts) {
            mkdirSync(artifacts, { recursive: true });
            await page.screenshot({ path: path.join(artifacts, `${entry}-${colorScheme}-more.png`) });
          }
          await add.click();
          await page.waitForFunction(() =>
            (
              window as unknown as { cmuxGalleryLog: { method: string; params?: { id?: string } }[] }
            ).cmuxGalleryLog.some((call) => call.method === "action.run" && call.params?.id === "device.add"),
          );
          // The list's Cloud row opens New Cloud Machine.
          if (!(await computer.getAttribute("aria-expanded"))?.includes("true")) await computer.click();
          const menu = page.locator(".acpmux-env-popover");
          const cloud = menu.getByRole("option", { name: /^Cloud/ });
          await cloud.waitFor();
          const names = await menu.getByRole("option").allTextContents();
          expect(await cloud.count(), names.join(" | ")).toBe(1);
          expect(await cloud.isVisible(), names.join(" | ")).toBe(true);
          if (artifacts) await page.screenshot({ path: path.join(artifacts, `${entry}-${colorScheme}.png`) });
          await cloud.click();
          await page
            .waitForFunction(
              () =>
                (
                  window as unknown as { cmuxGalleryLog: { method: string; params?: { id?: string } }[] }
                ).cmuxGalleryLog.some((call) => call.method === "action.run" && call.params?.id === "newCloudMachine"),
              null,
              { timeout: 10_000 },
            )
            .catch(async () => {
              throw new Error(`Cloud ran no newCloudMachine; actions: ${JSON.stringify(await log())}`);
            });
        } finally {
          await page.close();
        }
      });
    }
  }
});
