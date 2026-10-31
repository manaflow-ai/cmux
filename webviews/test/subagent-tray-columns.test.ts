// l10n-allow-file: gallery fixture names and tray labels are test data.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { GALLERY_NOW } from "../src/gallery/clock";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-columns.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray";
  const variant = "duration-columns";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
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

  for (const interfaceScale of [1, 1.25]) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`narrow workflow progress stays above trailing controls at scale ${interfaceScale} (${theme})`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width: 300, height: 560 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "workflow-progress", interfaceScale, theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForFunction(() => document.querySelector(".acpmux-running-tray[data-narrow]"));
          await page.clock.setFixedTime(new Date(GALLERY_NOW));
          const progress = page.locator(".acpmux-running-tray .acpmux-agent-line__progress");
          await progress.waitFor();
          const geometry = await progress.evaluate((node) => {
            const row = node.closest(".acpmux-agent-line")!;
            const box = (element: Element) => {
              const rect = element.getBoundingClientRect();
              return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
            };
            const range = document.createRange();
            range.selectNodeContents(node);
            return {
              row: box(row),
              title: box(row.querySelector(".acpmux-summary-text")!),
              progress: box(node),
              lines: [...range.getClientRects()].map((rect) => ({
                left: rect.left,
                right: rect.right,
                top: rect.top,
                bottom: rect.bottom,
              })),
              time: box(row.querySelector(".acpmux-agent-line__time")!),
              status: box(row.querySelector(".acpmux-agent-line__status")!),
              stop: box(row.querySelector(".acpmux-agent-line__stop-slot > button")!),
            };
          });
          // This fixture must exercise wrapping; measuring only the progress element's box
          // misses text painted outside a fixed-height title track.
          expect(geometry.lines.length).toBeGreaterThan(1);
          expect(geometry.title.top).toBeGreaterThanOrEqual(geometry.row.top - 1);
          expect(geometry.title.bottom).toBeLessThanOrEqual(geometry.row.bottom + 1);
          for (const line of [geometry.progress, ...geometry.lines]) {
            expect(line.top).toBeGreaterThanOrEqual(geometry.title.top - 1);
            expect(line.bottom).toBeLessThanOrEqual(geometry.title.bottom + 1);
            expect(line.left).toBeGreaterThanOrEqual(geometry.title.left - 1);
            expect(line.right).toBeLessThanOrEqual(geometry.title.right + 1);
            for (const control of [geometry.time, geometry.status, geometry.stop]) {
              expect(line.bottom).toBeLessThanOrEqual(control.top + 1);
            }
          }
          const stopCenter = (geometry.stop.top + geometry.stop.bottom) / 2;
          for (const control of [geometry.time, geometry.status]) {
            expect(Math.abs((control.top + control.bottom) / 2 - stopCenter)).toBeLessThanOrEqual(1);
          }
          expect(geometry.stop.bottom).toBeLessThanOrEqual(geometry.row.bottom + 1);
          if (process.env.CMUX_TRAY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
            const clip = await page.evaluate(() => {
              const tray = document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
              const composer = document.querySelector(".acpmux-composer")!.getBoundingClientRect();
              const top = Math.max(0, tray.top - 16);
              return { x: 0, y: top, width: 300, height: Math.min(innerHeight, composer.bottom + 16) - top };
            });
            await page.screenshot({
              path: path.join(
                process.env.CMUX_TRAY_CAPTURE_DIR,
                `tray-workflow-progress-${interfaceScale}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
              ),
              clip,
            });
          }
        } finally {
          await page.close();
        }
      });

      test(`narrow short dock keeps header and View all reachable at scale ${interfaceScale} (${theme})`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width: 300, height: 400 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "short-dock", interfaceScale, theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForFunction(() => document.querySelector(".acpmux-running-tray[data-narrow]"));
          // Keep the longest format present while measuring: the gallery clock otherwise
          // advances from 12h 59m 59s to the much shorter 13h during a slow capture.
          await page.clock.setFixedTime(new Date(GALLERY_NOW));
          await page.waitForFunction(
            () =>
              document.querySelector(".acpmux-running-tray__head .acpmux-running-tray__time")?.textContent?.trim() ===
              "12h 59m 59s",
          );
          const pinned = await page.evaluate(() => {
            const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
            const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
            const more = tray.querySelector<HTMLElement>(".acpmux-running-tray__finished")!;
            const box = tray.getBoundingClientRect();
            const bounds = (node: HTMLElement) => {
              const rect = node.getBoundingClientRect();
              return {
                top: rect.top,
                bottom: rect.bottom,
                height: rect.height,
                hit: node.contains(document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)),
              };
            };
            return { trayTop: box.top, trayBottom: box.bottom, head: bounds(head), more: bounds(more) };
          });
          // One row at every width: the header's time follows its counts, never a second line.
          expect(pinned.head.height).toBeCloseTo(28 * interfaceScale, 1);
          expect(pinned.more.height).toBeCloseTo(28 * interfaceScale, 1);
          for (const row of [pinned.head, pinned.more]) {
            expect(row.top).toBeGreaterThanOrEqual(pinned.trayTop - 0.5);
            expect(row.bottom).toBeLessThanOrEqual(pinned.trayBottom + 0.5);
            expect(row.hit).toBe(true);
          }
          const duration = await page
            .locator(".acpmux-running-tray__head .acpmux-running-tray__time")
            .evaluate((node) => {
              const range = document.createRange();
              range.selectNodeContents(node);
              const lines = [...range.getClientRects()];
              const box = node.getBoundingClientRect();
              return {
                lines: lines.length,
                textRight: lines[0]!.right,
                right: box.right,
                overflow: node.scrollWidth - node.clientWidth,
              };
            });
          expect(duration.lines).toBe(1);
          expect(duration.textRight).toBeLessThanOrEqual(duration.right + 0.5);
          expect(duration.overflow).toBeLessThanOrEqual(1);
          if (process.env.CMUX_TRAY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
            const clip = await page.evaluate(() => {
              const tray = document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
              const composer = document.querySelector(".acpmux-composer")!.getBoundingClientRect();
              const top = Math.max(0, tray.top - 16);
              return { x: 0, y: top, width: 300, height: Math.min(innerHeight, composer.bottom + 16) - top };
            });
            await page.screenshot({
              path: path.join(
                process.env.CMUX_TRAY_CAPTURE_DIR,
                `tray-short-dock-${interfaceScale}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
              ),
              clip,
            });
          }
          const more = page.locator(".acpmux-running-tray__finished");
          await more.click();
          expect(await more.getAttribute("aria-expanded")).toBe("true");

          // Give the list a row of room again, then exercise the live Stop control inside its
          // scroller. A clipped tray or a footer overlay must not cover the control's hit target.
          await page.evaluate(() => {
            const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
            const header = dock.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
            const height = Number.parseFloat(dock.style.maxHeight);
            dock.style.maxHeight = `${height + 2 * header.getBoundingClientRect().height}px`;
          });
          const stop = page.locator(".acpmux-running-tray .acpmux-agent-line__stop-slot > button").first();
          await stop.scrollIntoViewIfNeeded();
          const control = await stop.evaluate((node) => {
            const list = node.closest(".acpmux-running-tray__list")!;
            const box = node.getBoundingClientRect();
            const listBox = list.getBoundingClientRect();
            return {
              top: box.top,
              bottom: box.bottom,
              listTop: listBox.top,
              listBottom: listBox.bottom,
              hit: node.contains(document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)),
            };
          });
          expect(control.top).toBeGreaterThanOrEqual(control.listTop - 0.5);
          expect(control.bottom).toBeLessThanOrEqual(control.listBottom + 0.5);
          expect(control.hit).toBe(true);
        } finally {
          await page.close();
        }
      });
    }
  }

  for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
    test(`expanded tray keeps trailing columns with real durations (${theme})`, async () => {
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
        const collapsedTime = head.locator(".acpmux-running-tray__time");
        expect(await collapsedTime.count()).toBe(1);
        const collapsedHeaderText = (await collapsedTime.textContent())?.trim() ?? "";
        expect(collapsedHeaderText).toMatch(/^(?:\d+h(?: \d+m)?(?: \d+s)?|\d+m(?: \d+s)?|\d+s)$/);
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
              chevron: rect(".acpmux-agent-line__chevron", row),
              hasStop: Boolean(row.querySelector(".acpmux-agent-line__stop-slot > button")),
            })),
            footer: tray.querySelector(".acpmux-running-tray__finished")
              ? rect(".acpmux-running-tray__finished > svg", tray)
              : undefined,
            head: {
              title: rect(".acpmux-running-tray__title", head),
              time: rect(".acpmux-running-tray__time", head),
              chevron: rect(".acpmux-running-tray__status > svg", head),
            },
          };
        });
        expect(columns.rows.length).toBeGreaterThanOrEqual(3);
        const [first, ...rest] = columns.rows;
        expect(rest.every((row) => row.status.left === first!.status.left)).toBe(true);
        expect(rest.every((row) => row.time.right === first!.time.right)).toBe(true);
        expect(rest.every((row) => row.stop.left === first!.stop.left)).toBe(true);
        // The header's time is quiet meta right after its counts (one 8px gap), never a column of
        // its own far from them.
        expect(Math.abs(columns.head.time.left - columns.head.title.right - 8)).toBeLessThanOrEqual(1);
        // One trailing track (Leo, 2026-10-29: "There's this right indent for no reason."): the
        // header's, every line's and View all's chevrons end on one x.
        expect(rest.every((row) => row.chevron.right === first!.chevron.right)).toBe(true);
        expect(columns.head.chevron.right).toBe(first!.chevron.right);
        if (columns.footer) expect(columns.footer.right).toBe(first!.chevron.right);
        expect(columns.rows.some((row) => row.hasStop)).toBe(true);
        expect(columns.rows.some((row) => !row.hasStop)).toBe(true);

        const measure = () =>
          page.evaluate(() => {
            const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
            const trayBox = tray.getBoundingClientRect();
            const rect = (selector: string, root: ParentNode) => {
              const node = root.querySelector<HTMLElement>(selector);
              if (!node) throw new Error(`missing ${selector}`);
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
            const textRect = (node: HTMLElement) => {
              const range = document.createRange();
              range.selectNodeContents(node);
              const boxes = [...range.getClientRects()];
              const box = node.getBoundingClientRect();
              const style = getComputedStyle(node);
              return {
                text: node.textContent?.trim() ?? "",
                lineCount: boxes.length,
                textRight: boxes.length === 0 ? null : boxes[0]!.right,
                boxRight: box.right,
                height: box.height,
                scrollWidth: node.scrollWidth,
                clientWidth: node.clientWidth,
                whiteSpace: style.whiteSpace,
                fontVariantNumeric: style.fontVariantNumeric,
              };
            };
            const rows = [...tray.querySelectorAll<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line")];
            const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head");
            if (!head) throw new Error("missing tray head");
            return {
              tray: { left: trayBox.left, right: trayBox.right, width: trayBox.width },
              rows: rows.map((row) => {
                const time = row.querySelector<HTMLElement>(".acpmux-agent-line__time");
                if (!time) throw new Error("missing row time");
                return {
                  name: rect(".acpmux-summary-agent__name", row),
                  summary: rect(".acpmux-summary-text", row),
                  time: { ...rect(".acpmux-agent-line__time", row), ...textRect(time) },
                  status: rect(".acpmux-agent-line__status", row),
                  chevron: row.querySelector<HTMLElement>(".acpmux-agent-line__chevron")
                    ? rect(".acpmux-agent-line__chevron", row)
                    : null,
                  stop: rect(".acpmux-agent-line__stop-slot", row),
                  hasStop: Boolean(row.querySelector(".acpmux-agent-line__stop-slot > button")),
                };
              }),
              head: (() => {
                const time = head.querySelector<HTMLElement>(".acpmux-running-tray__time");
                if (!time) throw new Error("missing header time");
                return {
                  title: rect(".acpmux-running-tray__title", head),
                  time: { ...rect(".acpmux-running-tray__time", head), ...textRect(time) },
                  chevron: rect(".acpmux-running-tray__status > svg", head),
                };
              })(),
            };
          });
        const initial = await measure();
        expect(initial.rows.length).toBeGreaterThanOrEqual(3);
        const [initialFirst, ...initialRest] = initial.rows;
        expect(initialRest.every((row) => row.status.left === initialFirst!.status.left)).toBe(true);
        expect(initialRest.every((row) => row.time.right === initialFirst!.time.right)).toBe(true);
        expect(initialRest.every((row) => row.stop.left === initialFirst!.stop.left)).toBe(true);
        expect(initial.head.time.left).toBeGreaterThanOrEqual(initial.head.title.right - 0.5);
        expect(initial.head.time.left - initial.head.title.right).toBeLessThanOrEqual(8.5);
        expect(initial.rows.every((row) => !row.chevron || row.chevron.right === initial.head.chevron.right)).toBe(true);
        expect(initial.rows.some((row) => row.hasStop)).toBe(true);
        expect(initial.rows.some((row) => !row.hasStop)).toBe(true);
        expect(initial.rows.every((row) => row.summary.width >= 60)).toBe(true);
        expect(initial.rows.every((row) => row.summary.right <= row.time.left + 0.5)).toBe(true);
        expect(initial.rows.every((row) => row.status.left >= row.time.right - 0.5)).toBe(true);
        // Stop's track, then the chevron's, after the state.
        expect(initial.rows.every((row) => row.stop.left >= row.status.right - 0.5)).toBe(true);
        expect(initial.rows.every((row) => !row.chevron || row.chevron.left >= row.stop.right - 0.5)).toBe(true);
        expect(initial.rows.every((row) => !row.chevron || row.chevron.right <= initial.tray.right + 0.5)).toBe(true);
        expect(initial.rows.every((row) => row.time.lineCount <= 1)).toBe(true);
        expect(
          initial.rows.every((row) => row.time.lineCount === 0 || row.time.textRight! <= row.time.boxRight + 0.5),
        ).toBe(true);
        expect(initial.rows.every((row) => row.time.scrollWidth <= row.time.clientWidth + 1)).toBe(true);
        expect(initial.rows.every((row) => row.time.height <= 18)).toBe(true);
        expect(initial.rows.every((row) => row.time.whiteSpace === "nowrap")).toBe(true);
        expect(initial.rows.every((row) => row.time.fontVariantNumeric.includes("tabular-nums"))).toBe(true);
        expect(initial.rows.every((row) => row.stop.right <= initial.tray.right + 0.5)).toBe(true);
        const headerDuration = page.locator(".acpmux-running-tray__head .acpmux-running-tray__time");
        expect(await headerDuration.count()).toBe(1);
        expect(initial.head.time.text).toMatch(/^(?:\d+h(?: \d+m)?(?: \d+s)?|\d+m(?: \d+s)?|\d+s)$/);
        const durationMs = (value: string) => {
          if (!value) return 0;
          return value.split(" ").reduce((total, unit) => {
            const amount = Number.parseInt(unit, 10);
            return (
              total + (unit.endsWith("h") ? amount * 3_600_000 : unit.endsWith("m") ? amount * 60_000 : amount * 1_000)
            );
          }, 0);
        };
        expect(durationMs(initial.head.time.text)).toBe(
          Math.max(...initial.rows.map((row) => durationMs(row.time.text))),
        );
        expect(initial.rows.map((row) => row.time.text)).toContain(initial.head.time.text);

        const beforeTick = await measure();
        const beforeTexts = beforeTick.rows.map((row) => row.time.text);
        await page.waitForFunction(
          (previous) =>
            [...document.querySelectorAll<HTMLElement>(".acpmux-agent-line__time")].some(
              (time, index) => time.textContent?.trim() !== previous[index],
            ),
          beforeTexts,
        );
        const afterTick = await measure();
        expect(afterTick.rows.map((row) => row.time.text)).not.toEqual(beforeTexts);
        expect(afterTick.rows.every((row) => row.time.lineCount <= 1)).toBe(true);
        expect(afterTick.rows.every((row) => row.summary.width >= 60)).toBe(true);
        expect(
          afterTick.rows.every((row) => row.time.lineCount === 0 || row.time.textRight! <= row.time.boxRight + 0.5),
        ).toBe(true);
        expect(afterTick.rows.map((row) => row.time.right)).toEqual(initial.rows.map((row) => row.time.right));
        expect(afterTick.rows.map((row) => row.time.textRight)).toEqual(initial.rows.map((row) => row.time.textRight));
        expect(afterTick.rows.map((row) => row.time.scrollWidth)).toEqual(
          initial.rows.map((row) => row.time.scrollWidth),
        );
        expect(afterTick.rows.map((row) => row.time.clientWidth)).toEqual(
          initial.rows.map((row) => row.time.clientWidth),
        );
        expect(afterTick.rows.map((row) => row.status.left)).toEqual(initial.rows.map((row) => row.status.left));
        expect(afterTick.rows.map((row) => row.stop.left)).toEqual(initial.rows.map((row) => row.stop.left));
        expect(afterTick.rows.map((row) => row.time.height)).toEqual(initial.rows.map((row) => row.time.height));

        // The tray also has to remain usable in narrow panes used by the compact layout:
        // titles keep room, and every trailing control stays inside the tray.
        for (const width of [300, 240, 200]) {
          await page.setViewportSize({ width, height: 560 });
          const narrow = await measure();
          const [narrowFirst, ...narrowRest] = narrow.rows;
          expect(narrowRest.every((row) => row.status.left === narrowFirst!.status.left)).toBe(true);
          expect(narrowRest.every((row) => row.time.right === narrowFirst!.time.right)).toBe(true);
          expect(narrowRest.every((row) => row.stop.left === narrowFirst!.stop.left)).toBe(true);
          expect(narrow.rows.every((row) => row.summary.width >= 60)).toBe(true);
          expect(narrow.rows.every((row) => row.summary.bottom <= row.time.top + 0.5)).toBe(true);
          expect(narrow.rows.every((row) => row.time.lineCount <= 1)).toBe(true);
          expect(
            narrow.rows.every((row) => row.time.lineCount === 0 || row.time.textRight! <= row.time.boxRight + 0.5),
          ).toBe(true);
          expect(narrow.rows.every((row) => row.time.scrollWidth <= row.time.clientWidth + 1)).toBe(true);
          expect(narrow.rows.every((row) => row.stop.left >= row.status.right - 0.5)).toBe(true);
          expect(narrow.rows.every((row) => !row.chevron || row.chevron.left >= row.stop.right - 0.5)).toBe(true);
          expect(narrow.rows.every((row) => !row.chevron || row.chevron.right <= narrow.tray.right + 0.5)).toBe(true);
          expect(narrow.rows.every((row) => row.stop.right <= narrow.tray.right + 0.5)).toBe(true);
          expect(narrow.rows.every((row) => row.status.right <= narrow.tray.right + 0.5)).toBe(true);
          expect(narrow.rows.every((row) => row.status.left >= row.time.right - 0.5)).toBe(true);
          expect(narrow.head.time.left).toBeGreaterThanOrEqual(narrow.head.title.right - 0.5);
          expect(narrow.head.time.right).toBeLessThanOrEqual(narrow.head.chevron.left + 0.5);
          expect(narrow.rows.every((row) => !row.chevron || row.chevron.right === narrow.head.chevron.right)).toBe(true);
          await page.waitForFunction(
            (previous) =>
              [...document.querySelectorAll<HTMLElement>(".acpmux-agent-line__time")].some(
                (time, index) => time.textContent?.trim() !== previous[index],
              ),
            narrow.rows.map((row) => row.time.text),
          );
          const ticked = await measure();
          expect(ticked.rows.map((row) => row.time.text)).not.toEqual(narrow.rows.map((row) => row.time.text));
          expect(
            ticked.rows.every((row) => row.time.lineCount <= 1 && row.time.scrollWidth <= row.time.clientWidth + 1),
          ).toBe(true);
          expect(
            ticked.rows.every((row) => row.time.lineCount === 0 || row.time.textRight! <= row.time.boxRight + 0.5),
          ).toBe(true);
          expect(
            ticked.rows.every(
              (row) => row.summary.bottom <= row.time.top + 0.5 && row.status.left >= row.time.right - 0.5,
            ),
          ).toBe(true);
          expect(
            ticked.rows.map((row) => [
              row.time.right,
              row.status.left,
              row.chevron?.right,
              row.stop.left,
              row.time.height,
            ]),
          ).toEqual(
            narrow.rows.map((row) => [
              row.time.right,
              row.status.left,
              row.chevron?.right,
              row.stop.left,
              row.time.height,
            ]),
          );
        }
        await page.setViewportSize({ width: 300, height: 560 });

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
            return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
          };
          // The empty slot's own center, where it lies over the row's button: the click must reach the row.
          const slot = noStop.querySelector<HTMLElement>(".acpmux-agent-line__stop-slot");
          const stop = withStop.querySelector<HTMLElement>(".acpmux-agent-line__stop-slot > button");
          if (!slot || slot.getBoundingClientRect().width === 0)
            throw new Error("the no-stop row has no sized stop slot");
          return { noStop: center(slot), stop: center(stop!) };
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
