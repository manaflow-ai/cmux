// l10n-allow-file: gallery fixture names and tray labels are test data.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-columns.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray";
  const variant = "between-turns";

  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
    test(`expanded tray keeps fixed trailing columns with empty slots (${theme})`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({
        viewport: { width: 760, height: 560 },
        reducedMotion: "reduce",
      });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const head = page.locator(".acpmux-running-tray__head");
        await head.waitFor();
        if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
        await page.locator(".acpmux-running-tray__list .acpmux-agent-line").first().waitFor();
        await page.evaluate(() => {
          for (const animation of document.getAnimations()) {
            if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
          }
        });
        if (process.env.CMUX_TRAY_CAPTURE_DIR) {
          await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
          await page.screenshot({
            path: path.join(
              process.env.CMUX_TRAY_CAPTURE_DIR,
              `tray-columns-${theme.endsWith("Light") ? "light" : "dark"}.png`,
            ),
          });
        }

        const columns = await page.evaluate(() => {
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
          const rows = [...tray.querySelectorAll<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line")];
          const rect = (selector: string, root: ParentNode) => {
            const node = root.querySelector<HTMLElement>(selector);
            if (!node) throw new Error(`missing ${selector}`);
            const box = node.getBoundingClientRect();
            return { left: box.left, right: box.right, width: box.width };
          };
          return {
            rows: rows.map((row) => ({
              time: rect(".acpmux-agent-line__time", row),
              status: rect(".acpmux-agent-line__status", row),
              stop: rect(".acpmux-agent-line__stop-slot", row),
              hasStop: Boolean(row.querySelector(".acpmux-agent-line__stop-slot > button")),
            })),
            head: {
              time: rect(".acpmux-running-tray__time", head),
              status: rect(".acpmux-running-tray__status", head),
              stop: rect(".acpmux-running-tray__stop-slot", head),
            },
          };
        });
        expect(columns.rows.length).toBeGreaterThanOrEqual(3);
        const [first, ...rest] = columns.rows;
        expect(rest.every((row) => row.status.left === first!.status.left)).toBe(true);
        expect(rest.every((row) => row.time.right === first!.time.right)).toBe(true);
        expect(rest.every((row) => row.stop.left === first!.stop.left)).toBe(true);
        expect(columns.head.time.right).toBe(first!.time.right);
        expect(columns.head.status.left).toBe(first!.status.left);
        expect(columns.head.status.right).toBe(first!.status.right);
        expect(columns.head.stop.left).toBe(first!.stop.left);
        expect(columns.rows.some((row) => row.hasStop)).toBe(true);
        expect(columns.rows.some((row) => !row.hasStop)).toBe(true);

        const clickTargets = await page.evaluate(() => {
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const rows = [...tray.querySelectorAll<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line")];
          const noStop = rows.find((row) => !row.querySelector(".acpmux-agent-line__stop-slot > button"));
          const withStop = rows.find((row) => row.querySelector(".acpmux-agent-line__stop-slot > button"));
          if (!noStop || !withStop) throw new Error("missing stop and no-stop rows");
          const clicks = window as typeof window & { __trayClicks?: string[] };
          clicks.__trayClicks = [];
          noStop
            .querySelector(".acpmux-agent-line__button")
            ?.addEventListener("click", () => clicks.__trayClicks?.push("open"));
          withStop
            .querySelector(".acpmux-agent-line__stop-slot > button")
            ?.addEventListener("click", () => clicks.__trayClicks?.push("stop"));
          const center = (node: HTMLElement) => {
            const box = node.getBoundingClientRect();
            return { x: box.right - 2, y: box.top + box.height / 2 };
          };
          const stop = withStop.querySelector<HTMLElement>(".acpmux-agent-line__stop-slot > button");
          return { noStop: center(noStop), stop: center(stop!) };
        });
        await page.mouse.click(clickTargets.noStop.x, clickTargets.noStop.y);
        expect(await page.evaluate(() => (window as typeof window & { __trayClicks?: string[] }).__trayClicks)).toEqual(
          ["open"],
        );
        await page.mouse.click(clickTargets.stop.x, clickTargets.stop.y);
        expect(await page.evaluate(() => (window as typeof window & { __trayClicks?: string[] }).__trayClicks)).toEqual(
          ["open", "stop"],
        );

        const longState = await page.evaluate(() => {
          const row = document.querySelector<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line");
          const state = row?.querySelector<HTMLElement>(".acpmux-agent-line__status .acpmux-summary-agent__state");
          const status = row?.querySelector<HTMLElement>(".acpmux-agent-line__status");
          if (!state || !status) throw new Error("missing status state");
          state.textContent = "A very long localized waiting state that must stay in its track";
          const stateBox = state.getBoundingClientRect();
          const statusBox = status.getBoundingClientRect();
          const style = getComputedStyle(state);
          return {
            stateRight: stateBox.right,
            statusRight: statusBox.right,
            minWidth: style.minWidth,
            overflow: style.overflow,
            textOverflow: style.textOverflow,
            whiteSpace: style.whiteSpace,
          };
        });
        expect(longState.stateRight).toBeLessThanOrEqual(longState.statusRight + 0.5);
        expect(longState.minWidth).toBe("0px");
        expect(longState.overflow).toBe("hidden");
        expect(longState.textOverflow).toBe("ellipsis");
        expect(longState.whiteSpace).toBe("nowrap");
      } finally {
        await page.close();
      }
    });
  }
});
