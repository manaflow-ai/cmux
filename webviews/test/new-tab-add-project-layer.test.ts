// New Tab > project chip > New project opens the Add project dialog over the page. The shipped
// pane's page color is transparent (agent-session/shared/styles.css, so the window glass shows),
// and the dialog must still hide the composer under its search field. Since the liquid glass (Leo
// 2026-10-21: every popover is glass, never solid) it does that with the frost, not a solid fill.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-add-project-layer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-add-project-layer: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab add project layer", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the Add project dialog is frosted glass over the New Tab composer, never solid or bare", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "empty" })}`);
    // The shipped pane's page color (the gallery theme paints a solid one).
    await page.addStyleTag({ content: ":root { --agent-page-bg: transparent !important; }" });
    // The card's location strip (the agent composer's): Folder, then Add project. The first page waits on a
    // cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.locator('.acpmux-composer-context button[aria-label="Folder"]').click({ timeout: 90_000 });
    await page.getByRole("option", { name: "Add project" }).click();
    const dialog = page.locator(".acpmux-add-project-dialog");
    await dialog.waitFor({ state: "visible" });
    const material = await dialog.evaluate((element) => {
      const probe = document.createElement("canvas").getContext("2d")!;
      const style = getComputedStyle(element);
      // Start transparent, so a color the canvas rejects reads as see-through, never as solid black.
      probe.fillStyle = "transparent";
      probe.fillStyle = style.backgroundColor;
      probe.fillRect(0, 0, 1, 1);
      const alpha = probe.getImageData(0, 0, 1, 1).data[3]!;
      const backdrop = style.getPropertyValue("backdrop-filter") || style.getPropertyValue("-webkit-backdrop-filter");
      return { tinted: alpha > 0, opaque: alpha === 255, frosted: /blur\(/.test(backdrop) };
    });
    await page.close();
    expect(material).toEqual({ tinted: true, opaque: false, frosted: true });
  });
});
