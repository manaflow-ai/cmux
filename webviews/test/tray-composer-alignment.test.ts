// cmux-web-test-timeout: 300
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
  const TOLERANCE = 0.5;
  setDefaultTimeout(300_000);
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
      params: { variant: "panel-118", theme: "Apple System Colors" },
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
            // Claude's compact grid remains the stable in-box host even when its chips
            // render in the quiet footer row; Codex uses its separate bar layout.
            const expectedQuiet = expectedLook === "claude";
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
                tracks: ["time", "status"].map((track) => ({
                  name: track,
                  head: rect(`.acpmux-running-tray__head > .acpmux-running-tray__${track}`),
                  rows: [
                    ...document.querySelectorAll<HTMLElement>(
                      `.acpmux-running-tray__list .acpmux-agent-line__${track}`,
                    ),
                  ].map((node) => ({
                    ...rectFrom(node),
                    visible:
                      getComputedStyle(node).display !== "none" && getComputedStyle(node).visibility !== "hidden",
                  })),
                })),
                tray: rect('[data-alignment-surface="tray"][data-alignment-inset="surface"]'),
                composer: rect('[data-alignment-surface="composer"][data-alignment-inset="surface"]'),
                trayLeft: rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="left-icon"]',
                ),
                trayRight: rect(
                  '[data-alignment-surface="tray"] .acpmux-running-tray__head > [data-alignment-column="right-action"]',
                ),
                finished: (() => {
                  const node = document.querySelector<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__finished',
                  );
                  return node ? rectFrom(node) : null;
                })(),
                finishedRight: (() => {
                  const node = document.querySelector<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__finished > [data-alignment-column="right-action"]',
                  );
                  return node ? rectFrom(node) : null;
                })(),
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
                plainFooter: !!document.querySelector('[data-alignment-surface="composer"] [data-footer-look="plain"]'),
                expanded:
                  document
                    .querySelector('[data-alignment-surface="tray"] .acpmux-running-tray__head')
                    ?.getAttribute("aria-expanded") === "true",
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
                    '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line__stop-slot > .acpmux-chat-inspector-stop[data-alignment-column="right-action"]',
                  );
                  return stop ? rectFrom(stop) : null;
                })(),
                subagentStops: [
                  ...document.querySelectorAll<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-agent-line__stop-slot > .cv-subagent__stop',
                  ),
                ].map((stop) => ({
                  stop: rectFrom(stop),
                  row: rectFrom(stop.closest<HTMLElement>(".acpmux-agent-line")!),
                })),
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
                    '.acpmux-agent-line__stop-slot[data-alignment-column="right-action"]',
                  );
                  return right ? rectFrom(right) : null;
                })(),
                chevrons: [
                  ...document.querySelectorAll<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-agent-line__chevron',
                  ),
                ].map((node) => ({
                  box: rectFrom(node),
                  hasStop: Boolean(
                    node.closest(".acpmux-agent-line")?.querySelector(".acpmux-agent-line__stop-slot > button"),
                  ),
                })),
                headerChevron: (() => {
                  const node = document.querySelector<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__head .acpmux-running-tray__chevron',
                  );
                  return node ? rectFrom(node) : null;
                })(),
                footerChevron: (() => {
                  const node = document.querySelector<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__finished .acpmux-running-tray__chevron',
                  );
                  return node ? rectFrom(node) : null;
                })(),
                gridRows: [
                  ...document.querySelectorAll<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__head, [data-alignment-surface="tray"] .acpmux-agent-line__button',
                  ),
                ].map((row) => ({
                  box: rectFrom(row),
                  icon: rectFrom(row.querySelector<HTMLElement>('[data-alignment-column="left-icon"]')!),
                })),
                textColumns: [
                  ...document.querySelectorAll<HTMLElement>(
                    '[data-alignment-surface="tray"] .acpmux-running-tray__head .acpmux-running-tray__title, [data-alignment-surface="tray"] .acpmux-running-tray__list .acpmux-summary-text',
                  ),
                ].map(rectFrom),
              };
            });
            if (variant === "alignment-collapsed" && width === 720 && plainFooter && scheme === "dark") {
              await page.evaluate(() => {
                document.querySelector<HTMLElement>(".acpmux-dock")!.style.display = "contents";
              });
              await page.waitForFunction(
                () => getComputedStyle(document.querySelector<HTMLElement>(".acpmux-dock")!).display === "contents",
              );
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
                for (const selector of [".acpmux-composer", '[data-alignment-surface="tray"]']) {
                  const node = document.querySelector<HTMLElement>(selector);
                  if (node) node.style.translate = "-36px 0";
                }
                // Translate does not resize a box. Trigger the observed action subtree so
                // this checks a fresh measurement in the inspector's shifted coordinates.
                // The composer itself is the observed transformed ancestor; no action-subtree
                // mutation is needed to make this a real ancestor-change recomputation.
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
              const shifted = await page.evaluate(() => {
                const bounds = (selector: string) => {
                  const rect = document.querySelector(selector)!.getBoundingClientRect();
                  return { left: rect.left, right: rect.right };
                };
                return {
                  dockDisplay: getComputedStyle(document.querySelector(".acpmux-dock")!).display,
                  composer: bounds('[data-alignment-surface="composer"]'),
                  tray: bounds('[data-alignment-surface="tray"]'),
                };
              });
              expect(shifted.dockDisplay).toBe("contents");
              const composerShift = shifted.composer.left - result.composer.left;
              expect(Math.abs(composerShift)).toBeGreaterThan(0);
              expect(shifted.tray.left - result.tray.left).toBeCloseTo(composerShift, 1);
              expect(shifted.tray.right - result.tray.right).toBeCloseTo(composerShift, 1);
              expect(shifted.tray.left).toBeCloseTo(shifted.composer.left, 1);
              expect(shifted.tray.right).toBeCloseTo(shifted.composer.right, 1);
              for (const transform of [
                "matrix(1, 0, 0, 1, -24, 0)",
                "matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -24, 0, 0, 1)",
              ]) {
                await page.evaluate((transform) => {
                  for (const selector of [".acpmux-composer", '[data-alignment-surface="tray"]']) {
                    const node = document.querySelector<HTMLElement>(selector);
                    if (node) {
                      node.style.translate = "";
                      node.style.transform = transform;
                    }
                  }
                }, transform);
                await page.evaluate(
                  () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
                );
                const afterMatrix = await page.evaluate(() => {
                  const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
                  return dock.style.getPropertyValue("--acpmux-tray-end-inset");
                });
                expect(afterMatrix, "matrix translation must preserve layout columns").toBe(beforeShift["end-inset"]);
              }
              const beforeActionMutation = await page.evaluate(() => {
                const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
                return dock.style.getPropertyValue("--acpmux-tray-end-inset");
              });
              await page.evaluate(() => {
                const actions = document.querySelector<HTMLElement>(".acpmux-composer-actions");
                const button = actions
                  ? [...actions.querySelectorAll<HTMLElement>("button")]
                      .filter((node) => getComputedStyle(node).visibility !== "hidden")
                      .sort((a, b) => b.getBoundingClientRect().right - a.getBoundingClientRect().right)[0]
                  : undefined;
                if (!actions || !button) throw new Error("missing visible action for mutation test");
                const replacement = button.cloneNode(true) as HTMLElement;
                replacement.style.position = "relative";
                replacement.style.left = "12px";
                replacement.dataset.alignmentMutationReplacement = "true";
                (window as unknown as { __trayOriginalButton?: HTMLElement }).__trayOriginalButton = button;
                button.replaceWith(replacement);
              });
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              await page.waitForFunction(
                (expected) => {
                  const inset = document
                    .querySelector<HTMLElement>(".acpmux-dock")!
                    .style.getPropertyValue("--acpmux-tray-end-inset");
                  return Math.abs(Number.parseFloat(inset) - expected) < 0.05;
                },
                Number.parseFloat(beforeActionMutation) - 12,
              );
              const afterActionMutation = await page.evaluate(() => {
                const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
                return dock.style.getPropertyValue("--acpmux-tray-end-inset");
              });
              expect(Number.parseFloat(afterActionMutation)).toBeCloseTo(
                Number.parseFloat(beforeActionMutation) - 12,
                1,
              );
              await page.evaluate(() => {
                const original = (window as unknown as { __trayOriginalButton?: HTMLElement }).__trayOriginalButton;
                const replacement = document.querySelector<HTMLElement>(
                  '.acpmux-composer-actions button[data-alignment-mutation-replacement="true"]',
                );
                if (!original || !replacement) throw new Error("missing action mutation restore nodes");
                replacement.replaceWith(original);
                delete (window as unknown as { __trayOriginalButton?: HTMLElement }).__trayOriginalButton;
                for (const selector of [".acpmux-composer", '[data-alignment-surface="tray"]']) {
                  const node = document.querySelector<HTMLElement>(selector);
                  if (node) node.style.transform = "";
                }
              });
            }
            expect(result.actualLook).toBe(expectedLook);
            expect(result.quiet).toBe(expectedQuiet);
            expect(result.plainFooter).toBe(plainFooter);
            expect(result.expanded).toBe(variant.endsWith("expanded"));
            const expectedRows = variant.endsWith("expanded") ? 5 : 0;
            for (const track of result.tracks) {
              const visibleRows = track.rows.filter((row) => row.visible);
              expect(track.head.width, `${track.name} head must be measurable`).toBeGreaterThan(0);
              expect(visibleRows.length, `${track.name} row count`).toBe(expectedRows);
              for (const row of visibleRows) {
                expect(row.width, `${track.name} row must be measurable`).toBeGreaterThan(0);
                expect(row.height, `${track.name} row must be measurable`).toBeGreaterThan(0);
              }
            }
            const center = (box: { left: number; right: number }) => (box.left + box.right) / 2;
            const checks = {
              surfaceStart: Math.abs(result.tray.left - result.composer.left),
              surfaceEnd: Math.abs(result.tray.right - result.composer.right),
              leadingSize: Math.abs(result.trayLeft.width - 28),
              leftColumn: Math.abs(center(result.trayLeft) - result.composer.left - 22),
              rightColumn: result.headerChevron
                ? Math.abs(result.composer.right - center(result.headerChevron) - 22)
                : Infinity,
              ...(result.rowLeft
                ? {
                    rowLeftColumn: Math.abs(center(result.rowLeft) - result.composer.left - 22),
                  }
                : {}),
              ...(result.rowRight
                ? {
                    rowRightColumn: Math.abs(result.composer.right - center(result.rowRight) - 54),
                  }
                : {}),
              ...(result.commandStop && result.commandRow
                ? {
                    commandRightColumn: Math.abs(result.composer.right - center(result.commandStop) - 54),
                    commandStopWithinRow: Math.max(
                      result.commandRow.top - result.commandStop.top,
                      result.commandStop.bottom - result.commandRow.bottom,
                    ),
                  }
                : {}),
              ...Object.fromEntries(
                result.subagentStops.map(({ stop }, index) => [
                  `subagentStopRightColumn${index}`,
                  Math.abs(result.composer.right - center(stop) - 54),
                ]),
              ),
              ...(result.noStopRight && result.noStopRow
                ? {
                    noStopRightColumn: Math.abs(result.composer.right - center(result.noStopRight) - 54),
                    noStopRightInset: Math.abs(result.tray.right - center(result.noStopRight) - 54),
                  }
                : {}),
              ...(result.finishedRight
                ? {
                    finishedRightColumn: Math.abs(result.composer.right - center(result.finishedRight) - 22),
                  }
                : {}),
              ...Object.fromEntries(
                result.chevrons.map(({ box }, index) => [
                  `chevronRightColumn${index}`,
                  Math.abs(result.tray.right - center(box) - 22),
                ]),
              ),
              headerChevronRightInset: result.headerChevron
                ? Math.abs(result.tray.right - center(result.headerChevron) - 22)
                : 0,
              footerChevronRightInset: result.footerChevron
                ? Math.abs(result.tray.right - center(result.footerChevron) - 22)
                : 0,
              rowHeight: Math.max(...result.gridRows.map(({ box }) => Math.abs(box.height - 28))),
              rowLeadingCenter: Math.max(
                ...result.gridRows.map(({ icon }) => Math.abs(center(icon) - result.composer.left - 22)),
              ),
              textColumnStart: result.textColumns.length
                ? Math.max(...result.textColumns.map((text) => Math.abs(text.left - result.tray.left - 44)))
                : 0,
            };
            console.log(JSON.stringify({ variant, scheme, width, plainFooter, result, checks }));
            const evidenceDir = process.env.CMUX_ALIGNMENT_CAPTURE_DIR ?? "/tmp/grid-stack-columns";
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
            for (const track of result.tracks)
              for (const row of track.rows) {
                expect(Math.abs(row.left - track.head.left), `${track.name} track start`).toBeLessThanOrEqual(
                  TOLERANCE,
                );
                expect(Math.abs(row.right - track.head.right), `${track.name} track end`).toBeLessThanOrEqual(
                  TOLERANCE,
                );
              }
            for (const [name, value] of Object.entries(checks))
              expect(value, `${name} drifted by ${value.toFixed(2)}px`).toBeLessThanOrEqual(TOLERANCE);
            expect(result.headerChevron, "tray header chevron must be measurable").not.toBeNull();
            if (result.headerChevron)
              expect(Math.abs(result.tray.right - center(result.headerChevron) - 22)).toBeLessThanOrEqual(TOLERANCE);
            if (result.footerChevron)
              expect(Math.abs(result.tray.right - center(result.footerChevron) - 22)).toBeLessThanOrEqual(TOLERANCE);
            expect(checks.textColumnStart).toBeLessThanOrEqual(TOLERANCE);
            for (const [name, value] of Object.entries(checks).filter(([name]) =>
              name.startsWith("subagentStopRightColumn"),
            ))
              expect(value, `${name} drifted by ${value.toFixed(2)}px`).toBeLessThanOrEqual(TOLERANCE);
            const expectedSubagentStops = variant.endsWith("expanded") && !variant.includes("codex") ? 3 : 0;
            expect(result.subagentStops.length, "running subagent stop controls").toBe(expectedSubagentStops);
            for (const { stop, row } of result.subagentStops) {
              expect(stop.width, "subagent stop must be measurable").toBeGreaterThan(0);
              expect(stop.height, "subagent stop must be measurable").toBeGreaterThan(0);
              expect(stop.left).toBeGreaterThanOrEqual(row.left - TOLERANCE);
              expect(stop.right).toBeLessThanOrEqual(row.right + TOLERANCE);
              expect(stop.top).toBeGreaterThanOrEqual(row.top - TOLERANCE);
              expect(stop.bottom).toBeLessThanOrEqual(row.bottom + TOLERANCE);
            }
            if (variant.endsWith("expanded")) {
              expect(result.commandRow, "expanded tray must render a command row").not.toBeNull();
              expect(result.commandStop, "command stop must carry the right-action marker").not.toBeNull();
              if (!result.commandRow || !result.commandStop) throw new Error("expanded command geometry missing");
              expect(result.commandStop.width, "command stop must be measurable").toBeGreaterThan(0);
              expect(result.commandStop.height, "command stop must be measurable").toBeGreaterThan(0);
              expect(result.commandRow.width, "command row must be measurable").toBeGreaterThan(0);
              expect(result.commandRow.height, "command row must be measurable").toBeGreaterThan(0);
              expect(checks.commandRightColumn).toBeLessThanOrEqual(TOLERANCE);
              expect(checks.commandStopWithinRow).toBeLessThanOrEqual(TOLERANCE);
              expect(result.noStopRow, "expanded tray must render a no-stop row").not.toBeNull();
              expect(result.noStopRight, "no-stop row must retain its reserved action slot").not.toBeNull();
              expect(checks.noStopRightColumn).toBeLessThanOrEqual(TOLERANCE);
              expect(checks.noStopRightInset).toBeLessThanOrEqual(TOLERANCE);
            }
            await page.close();
          });

  // The large fixture opens all 118 rows and scrolls the list. Check both ends of its
  // scroll range: native scrollbars must not move the rows off the pinned header/footer.
  for (const scrollers of ["overlay", "legacy"])
    for (const width of [720, 260])
      for (const scheme of ["light", "dark"])
        test(`many subagents (${scheme}, ${width}px, ${scrollers}): header, rows and footer share the grid`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: 720 } });
          try {
            await page.goto(stageURL("panel-118", scheme));
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.locator(".acpmux-running-tray__finished").waitFor();
            await page.evaluate(() => document.fonts.ready);
            await page.evaluate((mode) => {
              document.documentElement.dataset.scrollers = mode;
            }, scrollers);
            const problems: string[] = [];
            for (const scroll of ["top", "bottom"] as const) {
              await page.locator(".acpmux-running-tray__list").evaluate((list, scroll) => {
                list.scrollTop = scroll === "top" ? 0 : list.scrollHeight;
              }, scroll);
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const measured = await page.evaluate(() => {
                const bounds = (node: Element) => {
                  const box = node.getBoundingClientRect();
                  return {
                    left: box.left,
                    right: box.right,
                    height: box.height,
                    center: (box.left + box.right) / 2,
                  };
                };
                const tray = document.querySelector(".acpmux-running-tray")!;
                const rows = [
                  ...tray.querySelectorAll(
                    ".acpmux-running-tray__head, .acpmux-agent-line__button, .acpmux-running-tray__finished",
                  ),
                ];
                return {
                  composer: bounds(document.querySelector(".acpmux-composer-box")!),
                  tray: bounds(tray),
                  rows: rows.map((row) => {
                    const icon = row.querySelector('[data-alignment-column="left-icon"]');
                    const chevron = row.querySelector(".acpmux-running-tray__chevron, .acpmux-agent-line__chevron");
                    const text = row.querySelector(".acpmux-summary-text")!;
                    return {
                      name: row.className,
                      box: bounds(row),
                      icon: icon ? bounds(icon) : null,
                      chevron: chevron ? bounds(chevron) : null,
                      text: bounds(text),
                    };
                  }),
                  count: tray.querySelectorAll(".acpmux-agent-line").length,
                };
              });
              const evidenceDir = process.env.CMUX_ALIGNMENT_CAPTURE_DIR ?? "/tmp/grid-stack-columns";
              await mkdir(evidenceDir, { recursive: true });
              const key = `panel-118-${scheme}-${width}-${scrollers}-${scroll}`;
              await page.screenshot({ path: path.join(evidenceDir, `${key}.png`), fullPage: true });
              await writeFile(path.join(evidenceDir, `${key}.json`), JSON.stringify(measured, null, 2));
              console.log(JSON.stringify({ variant: "panel-118", scheme, width, scroll, measured }));
              const check = (name: string, actual: number, expected: number) => {
                if (Math.abs(actual - expected) > TOLERANCE)
                  problems.push(`${scroll} ${name}: ${actual}px, expected ${expected}px`);
              };
              check("surface left", measured.tray.left, measured.composer.left);
              check("surface right", measured.tray.right, measured.composer.right);
              expect(measured.count, "large fixture must render every agent").toBe(118);
              expect(measured.rows.length, "header plus agents plus footer").toBe(120);
              for (const [index, row] of measured.rows.entries()) {
                check(`row ${index} left edge`, row.box.left, measured.composer.left);
                check(`row ${index} right edge`, row.box.right, measured.composer.right);
                check(`row ${index} height`, row.box.height, 28);
                check(`row ${index} text`, row.text.left - measured.composer.left, 44);
                if (row.text.right - row.text.left < 43.5)
                  problems.push(`row ${index}: text column has no useful width`);
                if (row.icon) check(`row ${index} leading center`, row.icon.center - measured.composer.left, 22);
                if (row.chevron)
                  check(`row ${index} trailing center`, measured.composer.right - row.chevron.center, 22);
                else problems.push(`${scroll} row ${index}: missing chevron`);
              }
            }
            expect(problems).toEqual([]);
          } finally {
            await page.close();
          }
        });
});
