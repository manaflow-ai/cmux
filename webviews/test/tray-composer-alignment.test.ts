// Tray and composer share the same left and right control columns in both tray states.
// The gallery variants are the public fixture IDs for before/after captures:
// agent-pane.subagent-tray (alignment-collapsed/expanded and Codex/narrow variants).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
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
        theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
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

  for (const variant of [
    "alignment-collapsed",
    "alignment-expanded",
    "alignment-codex-collapsed",
    "alignment-codex-expanded",
  ])
    for (const width of [720, 320, 260])
      for (const plainFooter of [true, false])
        for (const scheme of ["light", "dark"])
          test(`${variant} (${scheme}, ${width}px, plain=${plainFooter}): tray and composer keep shared columns`, async () => {
            const page = await browser!.newPage({
              viewport: { width: 720, height: 560 },
            });
            await page.goto(stageURL(variant, scheme));
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.locator('[data-alignment-surface="tray"]').waitFor();
            await page.evaluate((plainFooter) => {
              window.cmuxAcpmuxComposer?.({ plainFooter });
            }, plainFooter);
            const expectedLook = variant.includes("codex") ? "codex" : "claude";
            const expectedQuiet = plainFooter && expectedLook === "claude";
            await page.waitForFunction(
              ({ expectedLook, expectedQuiet }) => {
                const form = document.querySelector<HTMLElement>(".acpmux-composer");
                return (
                  (form?.dataset.composerLook ?? "claude") === expectedLook &&
                  !!form?.querySelector(".acpmux-composer-inner") === expectedQuiet
                );
              },
              { expectedLook, expectedQuiet },
            );
            if (variant.endsWith("expanded")) {
              const head = page.locator('[data-alignment-surface="tray"] .acpmux-running-tray__head');
              if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
              await page.locator('[data-alignment-surface="tray"] .acpmux-running-tray__list').waitFor();
            }
            await page.locator('[data-alignment-surface="composer"]').waitFor();
            // Resize the mounted layout so the observer, not only its initial read, supplies the columns.
            await page.setViewportSize({ width, height: 560 });
            await page.evaluate(() => document.fonts.ready);
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            const result = await page.evaluate(() => {
              const rectFrom = (node: HTMLElement) => {
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
              const rect = (selector: string) => {
                const node = document.querySelector<HTMLElement>(selector);
                if (!node) throw new Error(`missing alignment selector: ${selector}`);
                return rectFrom(node);
              };
              return {
                tray: rect('[data-alignment-surface="tray"][data-alignment-inset="surface"]'),
                composer: rect('[data-alignment-surface="composer"][data-alignment-inset="surface"]'),
                trayLeft: rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="left-icon"]',
                ),
                trayRight: rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="right-action"]',
                ),
                plus: rect(
                  '[data-alignment-surface="composer"] [data-alignment-column="left-icon"] .acpmux-picker-button',
                ),
                mic: (() => {
                  const nodes = [
                    ...document.querySelectorAll<HTMLElement>(
                      '[data-alignment-surface="composer"] .acpmux-composer-actions button',
                    ),
                  ]
                    .filter((node) => getComputedStyle(node).visibility !== "hidden")
                    .map(rectFrom)
                    .filter((box) => box.width > 0 && box.height > 0)
                    .sort((a, b) => b.right - a.right);
                  if (!nodes[0]) throw new Error("missing visible trailing action");
                  return nodes[0];
                })(),
                actualLook: document.querySelector<HTMLElement>(".acpmux-composer")?.dataset.composerLook ?? "claude",
                quiet: !!document.querySelector(".acpmux-composer-inner"),
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
                  ? rect('[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line')
                  : null,
                commandRow: (() => {
                  const row = [
                    ...document.querySelectorAll<HTMLElement>(
                      '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line',
                    ),
                  ].find((candidate) => candidate.querySelector(".acpmux-chat-inspector-stop"));
                  return row ? rectFrom(row) : null;
                })(),
                commandStop: (() => {
                  const stop = document.querySelector<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line > .acpmux-chat-inspector-stop[data-alignment-column="right-action"]',
                  );
                  return stop ? rectFrom(stop) : null;
                })(),
                noStopRow: (() => {
                  const row = [
                    ...document.querySelectorAll<HTMLElement>(
                      '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line',
                    ),
                  ].find((candidate) => !candidate.querySelector(".acpmux-chat-inspector-stop, .cv-subagent__stop"));
                  return row ? rectFrom(row) : null;
                })(),
                noStopRight: (() => {
                  const row = [
                    ...document.querySelectorAll<HTMLElement>(
                      '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line',
                    ),
                  ].find((candidate) => !candidate.querySelector(".acpmux-chat-inspector-stop, .cv-subagent__stop"));
                  const right = row?.querySelector<HTMLElement>(
                    '.acpmux-agent-line__button > [data-alignment-column="right-action"]',
                  );
                  return right ? rectFrom(right) : null;
                })(),
              };
            });
            if (variant === "alignment-collapsed" && width === 720 && plainFooter && scheme === "dark") {
              const beforeShift = await page.evaluate(() => {
                const dock = document.querySelector<HTMLElement>(".acpmux-dock");
                return dock
                  ? Object.fromEntries(
                      ["surface-start", "surface-end", "start-inset", "end-inset"].map((name) => [
                        name,
                        dock.style.getPropertyValue(`--acpmux-tray-${name}`),
                      ]),
                    )
                  : {};
              });
              await page.evaluate(() => {
                for (const selector of ['[data-alignment-surface="composer"]', '[data-alignment-surface="tray"]']) {
                  const node = document.querySelector<HTMLElement>(selector);
                  if (node) node.style.translate = "-36px 0";
                }
              });
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const afterShift = await page.evaluate(() => {
                const dock = document.querySelector<HTMLElement>(".acpmux-dock");
                return dock
                  ? Object.fromEntries(
                      ["surface-start", "surface-end", "start-inset", "end-inset"].map((name) => [
                        name,
                        dock.style.getPropertyValue(`--acpmux-tray-${name}`),
                      ]),
                    )
                  : {};
              });
              expect(afterShift, "inspector child translate must not alter layout columns").toEqual(beforeShift);
            }
            expect(result.actualLook).toBe(expectedLook);
            expect(result.quiet).toBe(expectedQuiet);
            const center = (box: { left: number; right: number }) => (box.left + box.right) / 2;
            const checks = {
              surfaceStart: Math.abs(result.tray.left - result.composer.left),
              surfaceEnd: Math.abs(result.tray.right - result.composer.right),
              leadingSize: Math.abs(result.plus.width - (width === 260 ? 24 : 28)),
              trailingSize: Math.abs(result.mic.width - 28),
              leftColumn: Math.abs(center(result.trayLeft) - center(result.plus)),
              rightColumn: Math.abs(center(result.trayRight) - center(result.mic)),
              trayLeftInset: Math.abs(
                center(result.trayLeft) - result.tray.left - (center(result.plus) - result.composer.left),
              ),
              composerLeftInset: Math.abs(
                center(result.plus) - result.composer.left - (center(result.trayLeft) - result.tray.left),
              ),
              trayRightInset: Math.abs(
                result.tray.right - center(result.trayRight) - (result.composer.right - center(result.mic)),
              ),
              composerRightInset: Math.abs(
                result.composer.right - center(result.mic) - (result.tray.right - center(result.trayRight)),
              ),
              ...(result.rowLeft
                ? {
                    rowLeftColumn: Math.abs(center(result.rowLeft) - center(result.plus)),
                  }
                : {}),
              ...(result.rowRight
                ? {
                    rowRightColumn: Math.abs(center(result.rowRight) - center(result.mic)),
                  }
                : {}),
              ...(result.commandStop && result.commandRow
                ? {
                    commandRightColumn: Math.abs(center(result.commandStop) - center(result.mic)),
                    commandStopWithinRow: Math.max(
                      result.commandRow.top - result.commandStop.top,
                      result.commandStop.bottom - result.commandRow.bottom,
                    ),
                  }
                : {}),
              ...(result.noStopRight && result.noStopRow
                ? {
                    noStopRightColumn: Math.abs(center(result.noStopRight) - center(result.mic)),
                    noStopRightInset: Math.abs(
                      result.tray.right - center(result.noStopRight) - (result.composer.right - center(result.mic)),
                    ),
                  }
                : {}),
            };
            console.log(JSON.stringify({ variant, scheme, width, plainFooter, result, checks }));
            const evidenceDir = "/tmp/nx-tray-composer-align";
            await mkdir(evidenceDir, { recursive: true });
            const evidenceKey = `${variant}-${scheme}-${width}-${plainFooter ? "plain" : "full"}`;
            await page.screenshot({
              path: evidenceDir + "/" + evidenceKey + ".png",
              fullPage: true,
            });
            await writeFile(
              evidenceDir + "/" + evidenceKey + ".json",
              JSON.stringify({ variant, scheme, width, plainFooter, result, checks }, null, 2),
            );
            for (const [name, value] of Object.entries(checks))
              expect(value, `${name} drifted by ${value.toFixed(2)}px`).toBeLessThanOrEqual(TOLERANCE);
            if (variant.endsWith("expanded")) {
              expect(result.commandRow, "expanded tray must render a command row").not.toBeNull();
              expect(result.commandStop, "command stop must carry the right-action marker").not.toBeNull();
              expect(checks.commandRightColumn).toBeLessThanOrEqual(TOLERANCE);
              expect(checks.commandStopWithinRow).toBeLessThanOrEqual(TOLERANCE);
              expect(result.noStopRow, "expanded tray must render a no-stop row").not.toBeNull();
              expect(result.noStopRight, "no-stop row must retain its right chevron").not.toBeNull();
              expect(checks.noStopRightColumn).toBeLessThanOrEqual(TOLERANCE);
              expect(checks.noStopRightInset).toBeLessThanOrEqual(TOLERANCE);
            }
            await page.close();
          });
});
