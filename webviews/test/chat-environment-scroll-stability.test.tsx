// l10n-allow-file: fixture machine names, folders and transcript text, not shipped UI.
// Leo, 2026-10-26: the chat pane must not repeat machine · folder in the header.
// Exercise every App header placement and the native tab-row layout. The initial local fixture
// already represents a started chat; the absence check is deliberately independent of snapshot
// persistence so the regression proves the header's render paths rather than a storage detail.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-environment-scroll-stability.test.tsx", async () => {
  setDefaultTimeout(180_000);
  for (const [engine, launch] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    describe(engine, () => {
      let browser: Browser;
      let pane: Awaited<ReturnType<typeof papercutPane>>;
      beforeAll(async () => {
        // Browser absence is a verification failure, never a passing skip.
        browser = await launch.launch({ headless: true });
        pane = await papercutPane(() => browser, { turns: 4, running: false });
      });
      afterAll(async () => {
        await pane?.close();
        await browser?.close();
      });

      const settle = (page: Page) =>
        page.evaluate(async () => {
          await document.fonts.ready;
          await Promise.all(
            document
              .getAnimations()
              .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
              .map((animation) => animation.finished.catch(() => undefined)),
          );
          await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
        });

      const expectQuietHeader = async (page: Page) => {
        expect(await page.locator(".acpmux-env-line").count()).toBe(0);
        expect(await page.locator(".acpmux-environment-row").count()).toBe(0);
        expect(await page.locator(".acpmux-handoff-header-tools").count()).toBe(1);
        expect(await page.locator(".acpmux-handoff-header-tools button").count()).toBeGreaterThan(0);
      };

      for (const placement of ["left", "right", "off"] as const)
        for (const inTabRow of [false, true]) {
          test(`${placement}, ${inTabRow ? "native tab row" : "standalone header"}: no location label`, async () => {
            const page = await pane.open({ width: 980, height: 720 });
            try {
              await page.evaluate(
                async ({ placement, inTabRow }) => {
                  // @ts-expect-error Vite resolves this test-only runtime entry.
                  const { setChatDisplay } = await import(/* @vite-ignore */ "/chatDisplay.ts");
                  // @ts-expect-error Vite resolves this test-only runtime entry.
                  const { setTabRow } = await import(/* @vite-ignore */ "/header/tabRow.ts");
                  setChatDisplay({ "agentPane.display.environment.placement": placement });
                  setTabRow(inTabRow ? { height: 28, trailingInset: 0 } : undefined);
                },
                { placement, inTabRow },
              );
              await settle(page);
              await expectQuietHeader(page);
            } finally {
              await page.close();
            }
          });
        }
    });
  }
});
