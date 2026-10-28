// Tray and composer share the same left and right control columns in both tray states.
// The gallery variants are the public fixture IDs for before/after captures:
// agent-pane.subagent-tray (alignment-collapsed) and (alignment-expanded).
import {
  afterAll,
  beforeAll,
  describe,
  expect,
  setDefaultTimeout,
  test,
} from "bun:test";
import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tray-composer-alignment.test.ts", async () => {
  const TOLERANCE = 1;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(
      "agent-pane.subagent-tray",
      {
        variant,
        theme:
          scheme === "light"
            ? "Apple System Colors Light"
            : "Apple System Colors",
      },
    )}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.subagent-tray", {
      browser,
      params: { variant: "alignment-collapsed", theme: "Apple System Colors" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["alignment-collapsed", "alignment-expanded"])
    for (const scheme of ["light", "dark"])
      test(`${variant} (${scheme}): tray and composer keep shared columns`, async () => {
        const page = await browser!.newPage({
          viewport: { width: 720, height: 520 },
        });
        await page.goto(stageURL(variant, scheme));
        await page.waitForFunction(
          () => document.documentElement.dataset.galleryReady === "1",
        );
        await page.locator('[data-alignment-surface="tray"]').waitFor();
        if (variant === "alignment-expanded") {
          const head = page.locator(
            '[data-alignment-surface="tray"] .acpmux-running-tray__head',
          );
          if ((await head.getAttribute("aria-expanded")) !== "true")
            await head.click();
          await page
            .locator(
              '[data-alignment-surface="tray"] .acpmux-running-tray__list',
            )
            .waitFor();
        }
        await page.locator('[data-alignment-surface="composer"]').waitFor();
        await page.evaluate(() => document.fonts.ready);
        await page.evaluate(
          () =>
            new Promise((done) =>
              requestAnimationFrame(() => requestAnimationFrame(done)),
            ),
        );
        const result = await page.evaluate(() => {
          const rect = (selector: string) => {
            const node = document.querySelector<HTMLElement>(selector);
            if (!node)
              throw new Error(`missing alignment selector: ${selector}`);
            const box = node.getBoundingClientRect();
            return {
              left: box.left,
              right: box.right,
              top: box.top,
              bottom: box.bottom,
              width: box.width,
              height: box.height,
            };
          };
          return {
            tray: rect(
              '[data-alignment-surface="tray"][data-alignment-inset="surface"]',
            ),
            composer: rect(
              '[data-alignment-surface="composer"][data-alignment-inset="surface"]',
            ),
            trayLeft: rect(
              '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="left-icon"]',
            ),
            trayRight: rect(
              '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="right-action"]',
            ),
            plus: rect(
              '[data-alignment-surface="composer"] [data-alignment-column="left-icon"] .acpmux-picker-button',
            ),
            mic: rect('[data-alignment-surface="composer"] .acpmux-mic'),
            rowLeft: document.querySelector(
              '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line__button [data-alignment-column="left-icon"]',
            )
              ? rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line__button [data-alignment-column="left-icon"]',
                )
              : null,
            rowRight: document.querySelector(
              '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line > [data-alignment-column="right-action"]',
            )
              ? rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line > [data-alignment-column="right-action"]',
                )
              : null,
            row: document.querySelector(
              '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line',
            )
              ? rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line',
                )
              : null,
          };
        });
        const center = (box: { left: number; right: number }) =>
          (box.left + box.right) / 2;
        const checks = {
          leftColumn: Math.abs(center(result.trayLeft) - center(result.plus)),
          rightColumn: Math.abs(center(result.trayRight) - center(result.mic)),
          trayLeftInset: Math.abs(
            center(result.trayLeft) - result.tray.left - 22,
          ),
          composerLeftInset: Math.abs(
            center(result.plus) - result.composer.left - 22,
          ),
          trayRightInset: Math.abs(
            result.tray.right - center(result.trayRight) - 22,
          ),
          composerRightInset: Math.abs(
            result.composer.right - center(result.mic) - 22,
          ),
          ...(result.rowLeft
            ? {
                rowLeftColumn: Math.abs(
                  center(result.rowLeft) - center(result.plus),
                ),
              }
            : {}),
          ...(result.rowRight
            ? {
                rowRightColumn: Math.abs(
                  center(result.rowRight) - center(result.mic),
                ),
              }
            : {}),
        };
        console.log(JSON.stringify({ variant, scheme, result, checks }));
        const evidenceDir = "/tmp/nx-tray-composer-align";
        await mkdir(evidenceDir, { recursive: true });
        const evidenceKey = variant + "-" + scheme;
        await page.screenshot({
          path: evidenceDir + "/" + evidenceKey + ".png",
          fullPage: true,
        });
        await writeFile(
          evidenceDir + "/" + evidenceKey + ".json",
          JSON.stringify({ variant, scheme, result, checks }, null, 2),
        );
        for (const [name, value] of Object.entries(checks))
          expect(
            value,
            `${name} drifted by ${value.toFixed(2)}px`,
          ).toBeLessThanOrEqual(TOLERANCE);
        await page.close();
      });
});
