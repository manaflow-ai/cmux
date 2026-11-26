// l10n-allow-file: the synthetic gallery supplies the labels.
// Session Info's Runs On opens as the row's drop-down (Lucas 2026-11-26): under the row, its end on
// the row's end, each choice with a short hint under its name, the check a trailing mark centred on
// its row. Before, the popup kept the composer's absolute placement (acpmux-menu without
// acpmux-picker-menu), so the positioner had no size and the pane's edge cut the menu off.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-runs-on-popup-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.hybrid-session-info-cloud";
  const variant = "info-where";
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
    await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("Runs On opens under its row, its end on the row's end, each choice with its hint and a centred trailing check", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 520, height: 560 }, deviceScaleFactor: 2 });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
      const trigger = page.locator('[data-menu="RunsOn"]');
      await trigger.waitFor();
      // The gallery starts on Auto; each pass picks the next choice, so every row is checked once.
      for (const [chosen, next] of [
        ["Auto", "Only in Cloud"],
        ["Only in Cloud", "Only on This Mac"],
        ["Only on This Mac", "Auto"],
      ] as const) {
        await trigger.click();
        const menu = page.locator('[role="menu"]');
        await menu.waitFor();
        // Past the open fade, so the popup is at its own size.
        await page.waitForFunction(() => {
          const popup = document.querySelector<HTMLElement>('[role="menu"]');
          return (
            popup !== null &&
            !popup.hasAttribute("data-starting-style") &&
            popup.getAnimations({ subtree: true }).every((animation) => animation.playState !== "running")
          );
        });
        const box = await page.evaluate(() => {
          const popup = document.querySelector<HTMLElement>('[role="menu"]')!;
          const items = [...popup.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
          const checked = popup.querySelector<HTMLElement>('[aria-checked="true"]')!;
          return {
            row: document.querySelector('[data-menu="RunsOn"]')!.getBoundingClientRect().toJSON(),
            popup: popup.getBoundingClientRect().toJSON(),
            names: items.map((item) => item.querySelector(".ui-menu-label")?.textContent),
            hints: items.map((item) => item.querySelector(".ui-menu-subtitle")?.textContent),
            heights: items.map((item) => item.getBoundingClientRect().height),
            checked: checked.getBoundingClientRect().toJSON(),
            checkedName: checked.querySelector(".ui-menu-label")?.textContent,
            check: checked.querySelector(".ui-menu-check")!.getBoundingClientRect().toJSON(),
            glyph: checked.querySelector(".ui-menu-check svg")!.getBoundingClientRect().toJSON(),
            value: getComputedStyle(document.querySelector(".acpmux-hybrid-where")!).visibility,
            popupClass: popup.className,
          };
        });
        const { row, popup, checked, check, glyph } = box;
        // Placed by the positioner, not the composer's absolute rule.
        expect(box.popupClass).toContain("acpmux-picker-menu");
        expect(box.names).toEqual(["Only on This Mac", "Auto", "Only in Cloud"]);
        expect(box.hints).toEqual([
          "Pauses when this Mac sleeps",
          "Moves to Cloud when this Mac sleeps",
          "Always runs in Cloud, holds a slot",
        ]);
        expect(box.checkedName).toBe(chosen);
        expect(Math.max(...box.heights) - Math.min(...box.heights)).toBeLessThan(0.5);
        expect(Math.abs(popup.right - row.right)).toBeLessThan(0.75);
        expect(popup.top).toBeGreaterThanOrEqual(row.bottom);
        expect(popup.left).toBeGreaterThanOrEqual(0);
        // The check: a 14 box 12 in from the menu's end, its 12 glyph on the row's middle.
        expect(Math.abs(popup.right - check.right - 12)).toBeLessThan(0.75);
        expect(Math.abs(glyph.height - 12)).toBeLessThan(0.5);
        expect(Math.abs(glyph.top + glyph.height / 2 - (checked.top + checked.height / 2))).toBeLessThan(0.75);
        expect(box.value).toBe("visible");
        await menu.getByRole("menuitemradio", { name: new RegExp(`^${next}`) }).click();
        await menu.waitFor({ state: "detached" });
        expect(await page.locator(".acpmux-hybrid-where").textContent()).toBe(next);
      }
    } finally {
      await page.close();
    }
  });
});
