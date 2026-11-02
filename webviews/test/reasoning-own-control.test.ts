// The model button is the composer's one model control (Leo 2026-10-20: "Opus 5.5  Medium", no
// separate Reasoning dropdown). Earlier (P0 #8) Reasoning was its own chip beside the model; now the
// effort is named inside the model button, and its levels are in that button's menu: the running
// model's side dropdown beside its row where the caller picks model and effort together (#27948),
// else its Effort row.
// Effort must stay reachable and live before the session reports its options (P0 #8's point): the
// menu lists real levels with one checked, never a picture.
//
// At the boundary a person meets, in real Chromium: a pointer press at the model button's centre
// (so whatever is on top takes it) at 760, 400 and 300 px, on the New Tab page, a new chat and a
// live chat. No other control is named Effort or Reasoning, and the button never says "Reasoning".
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reasoning-own-control.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reasoning-own-control: skipping (run `bunx playwright install chromium`)");
    describe.skip("reasoning own control", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "new-chat-reasoning" } });
    await warmGalleryFrame(vite, ["agent-pane.new-tab", "agent-pane.composer-row"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: width + 40, height: 640 } });
    await page.goto(url(entry, variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-chips .acpmux-model .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Presses the pointer at the centre of `selector`'s box: whatever is on top there takes it. */
  const pressCentre = async (page: Page, selector: string) => {
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error(`${selector} has no box`);
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  };

  // `inline`: the caller picks model and effort together (New Tab and a live chat), so the running
  // model's effort is a side dropdown beside its row (#27948) and the menu has no Effort row. A new
  // chat's composer keeps the Effort row.
  const cases: [string, string, string, boolean][] = [
    ["New Tab", "agent-pane.new-tab", "reasoning-chip", true],
    ["new chat", "agent-pane.composer", "new-chat-reasoning", false],
    ["live chat", "agent-pane.composer-row", "claude-auto", true],
  ];
  for (const [where, entry, variant, inline] of cases)
    for (const width of [760, 400, 300]) {
      test(`${where} at ${width} px: one model button names the effort; no separate Reasoning control`, async () => {
        const page = await open(entry, variant, width);
        expect(await page.locator(".acpmux-effort, .acpmux-effort-menu, .acpmux-fast").count()).toBe(0);
        expect(await page.getByRole("button", { name: /^(Effort|Reasoning)$/ }).count()).toBe(0);
        expect(await page.getByRole("button", { name: "Model", exact: true }).count()).toBe(1);
        const face = await page.locator(".acpmux-chips .acpmux-model .acpmux-picker-button").innerText();
        expect(face).not.toContain("Reasoning");
        // The effort is drawn inside the button, after the model's name.
        expect(await page.locator(".acpmux-chips .acpmux-model .acpmux-model-detail").count()).toBeGreaterThan(0);
        await page.close();
      });

      test(`${where} at ${width} px: the model button opens its menu, whose effort levels are live`, async () => {
        const page = await open(entry, variant, width);
        await pressCentre(page, ".acpmux-chips .acpmux-model .acpmux-picker-button");
        await page.locator(".acpmux-quick-menu").first().waitFor();
        // The compact menu, not the full picker: that one is More models.
        expect(await page.locator(".acpmux-mp").count()).toBe(0);
        // The running model's effort: its row's side dropdown (#27948), else the menu's Effort row.
        // Exactly one of the two is offered.
        const side = page.locator(".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger");
        const effortRow = page.getByRole("menuitem", { name: /^Effort/ });
        expect((await side.count()) + (await effortRow.count())).toBe(1);
        expect(
          await side.count(),
          `${where}: the side dropdown is offered exactly where model and effort are picked together`,
        ).toBe(inline ? 1 : 0);
        await ((await side.count()) ? side : effortRow).click();
        await page.waitForFunction(() => document.querySelectorAll(".acpmux-quick-menu").length >= 2);
        const levels = page.locator(".acpmux-quick-menu").last().locator('[role="menuitemradio"]');
        expect(await levels.count()).toBeGreaterThan(1);
        expect(
          await page
            .locator(".acpmux-quick-menu")
            .last()
            .locator('[role="menuitemradio"][aria-checked="true"]')
            .count(),
        ).toBe(1);
        await page.keyboard.press("Escape");
        await page.close();
      });
    }
});
