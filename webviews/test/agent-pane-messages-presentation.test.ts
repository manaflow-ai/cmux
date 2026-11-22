import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-messages-presentation.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.messages-presentation";
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "transcript" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function pick(page: Page, name: string) {
    await page.getByRole("button", { name: "Chat actions" }).click();
    await page.getByRole("menuitem", { name: "Transcript view", exact: true }).click();
    const choice = page.getByRole("menuitemradio", { name, exact: true });
    await choice.focus();
    await page.keyboard.press("Enter");
    await page.getByRole("menu").first().waitFor({ state: "detached" });
  }

  test("keyboard toggle hides work, keeps all replies as opposite-side bubbles, persists, and restores Verbose", async () => {
    const page = await browser.newPage({ viewport: { width: 900, height: 800 } });
    try {
      await page.goto(url("transcript"));
      await page.locator(".acpmux-composer").waitFor();
      await pick(page, "Verbose");
      await page.locator(".cv-tools").first().waitFor();
      await pick(page, "Messages");
      await page.locator(".cv-assistant-bubble").first().waitFor();
      expect(await page.locator(".cv-assistant-bubble").count()).toBe(2);
      expect(await page.locator(".cv-tools, .cv-thought, .cv-worked, .acpmux-turnSummary").count()).toBe(0);
      const agent = await page.locator(".cv-assistant-bubble").first().boundingBox();
      const user = await page.locator(".acpmux-user .cv-user__bubble").boundingBox();
      expect(agent!.x).toBeLessThan(user!.x);
      await page.reload();
      await page.locator(".cv-assistant-bubble").first().waitFor();
      await pick(page, "Transcript");
      await page.locator(".cv-tools").first().waitFor();
      expect(await page.locator(".cv-assistant-bubble").count()).toBe(0);
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Transcript view", exact: true }).click();
      expect(await page.getByRole("menuitemradio", { name: "Verbose", exact: true }).getAttribute("aria-checked")).toBe(
        "true",
      );
    } finally {
      await page.close();
    }
  });

  for (const [variant, selector] of [
    ["pending-question", ".acpmux-question"],
    ["pending-permission", ".acpmux-permission-ask"],
  ] as const)
    test(`Messages keeps ${variant} and its answer controls visible`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 800 } });
      try {
        await page.goto(url(variant));
        await page.locator(".cv-assistant-bubble").first().waitFor();
        await page.locator(selector).waitFor();
        expect(await page.locator(`${selector} button`).count()).toBeGreaterThan(0);
        expect(await page.locator(".cv-tools, .cv-thought, .cv-worked").count()).toBe(0);
      } finally {
        await page.close();
      }
    });
});
