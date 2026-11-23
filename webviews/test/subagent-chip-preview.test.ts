// A subagent name chip shows its preview on hover and on keyboard focus (SubagentPreview.tsx).
//
// Leo, 2026-11-14, on a grouped "✧ St… , ✧ To… , ✧ P… , … and ✧ F… started working" row whose nine
// chips were cut to a letter or two: "there's no hover preview on these".
//
// In gallery entry agent-pane.subagent-chip-preview, variant `grouped` (nine subagents in a 560px
// pane, and a finished line under them):
// - the second chip is cut (its label overflows), and pointing at it shows the card with the
//   subagent's whole name and its task; no row moves; the pointer leaving puts it away;
// - Tab onto the third chip shows its card too;
// - the finished line's chip shows its card, which says it is done.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-chip-preview.test.ts", async () => {
  setDefaultTimeout(120_000);
  const ENTRY = "agent-pane.subagent-chip-preview";
  const CHIPS = ".cv-subagent-started button.cv-agent-tag";
  // The open card: a card that just closed fades out beside the next one (data-closed).
  const PREVIEW = ".acpmux-subagent-preview[data-open]";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "grouped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    await page.goto(`${base}${galleryFrame(ENTRY, { variant: "grouped" })}`);
    await page.locator(CHIPS).nth(8).waitFor();
    await page.mouse.move(0, 0);
    return page;
  };

  test("pointing at a cut chip in a grouped row shows its whole name and task, moving nothing", async () => {
    const page = await open();
    try {
      const chip = page.locator(CHIPS).nth(1);
      // Leo's row: the chip shows only a letter or two of its name.
      const cut = await chip
        .locator(".cv-agent-tag__label")
        .evaluate((label) => label.scrollWidth > label.clientWidth + 1);
      expect(cut).toBe(true);
      const rows = page.locator("[data-subagent-preview-gallery] > .acpmux-row");
      const before = await rows.evaluateAll((all) => all.map((row) => row.getBoundingClientRect().toJSON()));
      expect(await page.locator(PREVIEW).count()).toBe(0);

      await chip.hover();
      const card = page.locator(PREVIEW);
      await card.waitFor({ state: "visible", timeout: 5_000 });
      const text = (await card.innerText()).replace(/\s+/g, " ");
      expect(text).toContain("Tool-call audit");
      expect(text).toContain("Audit every tool call row for the shared row grammar and list each one that drifts");
      // Its state.
      expect(text).toContain("Running");
      // The card floats: no row moved.
      const after = await rows.evaluateAll((all) => all.map((row) => row.getBoundingClientRect().toJSON()));
      expect(after).toEqual(before);

      await page.mouse.move(0, 0);
      await card.waitFor({ state: "detached", timeout: 5_000 });
      expect(await page.locator(PREVIEW).count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("Tab onto a chip shows its preview", async () => {
    const page = await open();
    try {
      const target = page.locator(CHIPS).nth(2);
      let focused = false;
      for (let presses = 0; presses < 30 && !focused; presses++) {
        await page.keyboard.press("Tab");
        focused = await target.evaluate((element) => element === document.activeElement);
      }
      expect(focused).toBe(true);
      const card = page.locator(PREVIEW);
      await card.waitFor({ state: "visible", timeout: 5_000 });
      const text = (await card.innerText()).replace(/\s+/g, " ");
      expect(text).toContain("Profile the cold start");
      expect(text).toContain("Profile the agent pane's cold start and name the three slowest imports");
    } finally {
      await page.close();
    }
  });

  test("a finished line's chip shows its preview, done", async () => {
    const page = await open();
    try {
      await page.locator(".cv-subagent-done-row .cv-agent-tag").hover();
      const card = page.locator(PREVIEW);
      await card.waitFor({ state: "visible", timeout: 5_000 });
      const text = (await card.innerText()).replace(/\s+/g, " ");
      expect(text).toContain("Find why the find bar flickers when the transcript streams");
      expect(text).toContain("it now measures once per frame");
    } finally {
      await page.close();
    }
  });
});
