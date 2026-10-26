// l10n-allow-file: fixture machine names, folders and transcript text, not shipped UI.
// Leo, 2026-10-26: the chat pane must not repeat machine · folder in the header.
// Exercise AcpmuxPane's real bridge, both native tab-row layouts and all saved placements;
// changing the folder or publishing scroll snapshots must never bring the label back.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-environment-scroll-stability.test.tsx", async () => {
  setDefaultTimeout(180_000);
  for (const [engine, launch] of [["chromium", chromium], ["webkit", webkit]] as const) {
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

      const settle = (page: Page) => page.evaluate(async () => {
        await document.fonts.ready;
        await Promise.all(document.getAnimations()
          .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
          .map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      });

      const publish = async (page: Page, fields: Record<string, unknown>) => {
        await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
        await page.waitForFunction(() => Boolean(sessionStorage.getItem("cmux.acpmux.snapshot")));
        await page.evaluate((fields) => {
          const current = JSON.parse(sessionStorage.getItem("cmux.acpmux.snapshot")!);
          const bridge = window.cmuxAcpmuxBridge;
          if (!bridge?.receive) throw new Error("Acpmux snapshot bridge is unavailable");
          bridge.receive({ ...current, summary: { ...current.summary, ...fields }, rows: [...current.rows] });
        }, fields);
        await settle(page);
      };

      const expectQuietHeader = async (page: Page) => {
        expect(await page.locator(".acpmux-env-line").count()).toBe(0);
        expect(await page.locator(".acpmux-environment-row").count()).toBe(0);
        expect(await page.locator(".acpmux-handoff-header-tools").count()).toBe(1);
        expect(await page.locator(".acpmux-handoff-header-tools button").count()).toBeGreaterThan(0);
      };

      for (const placement of ["left", "right", "off"] as const)
        for (const inTabRow of [false, true]) {
          test(`${placement}, ${inTabRow ? "native tab row" : "standalone header"}: no location label after folder/host changes and scroll`, async () => {
            const page = await pane.open({ width: 980, height: 720 });
            try {
              await page.evaluate(async ({ placement, inTabRow }) => {
                // @ts-expect-error Vite resolves this test-only runtime entry.
                const { setChatDisplay } = await import(/* @vite-ignore */ "/chatDisplay.ts");
                // @ts-expect-error Vite resolves this test-only runtime entry.
                const { setTabRow } = await import(/* @vite-ignore */ "/header/tabRow.ts");
                setChatDisplay({ "agentPane.display.environment.placement": placement });
                setTabRow(inTabRow ? { height: 28, trailingInset: 0 } : undefined);
              }, { placement, inTabRow });
              await settle(page);
              await expectQuietHeader(page);

              await publish(page, { cwd: "/home/dev/scratchpad", branch: "feature/example" });
              await expectQuietHeader(page);
              await publish(page, { cwd: "/remote/project", peer: "remote-demo", host: "remote-demo", hostKind: "ssh" });
              await expectQuietHeader(page);
              await page.evaluate(() => {
                const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
                if (!scroller) throw new Error("Transcript scroller is missing");
                scroller.scrollTop = 0;
                scroller.dispatchEvent(new Event("scroll", { bubbles: true }));
              });
              await publish(page, { cwd: "/", peer: undefined, host: undefined, hostKind: "local" });
              await expectQuietHeader(page);
            } finally {
              await page.close();
            }
          });
        }
    });
  }
});
