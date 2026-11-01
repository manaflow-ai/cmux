// l10n-allow-file: gallery fixture names and tray labels are test data.
// The running tray's trailing column in real Chromium (Playwright; CI fails the file when it cannot
// launch, requireBrowserLane). Leo's open tray (2026-10-31) hung each line's Stop below and right of
// the line, outside its box and off its centre, and put the header's chevron and the lines' in two
// columns; his folded header floated its elapsed time far from its counts. No line carries a Stop
// now (#28533: it is in each line's menu); every line's Stop track (its empty slot) is inside its
// line and on the line's centre (on its controls' row when the line is narrow), every chevron
// (the header's, each line's, View all's) ends on one x, and the header's time follows its counts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-trailing.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-tray-head";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "open" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(() => {
      for (const animation of document.getAnimations()) {
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
      }
    });

  const measure = (page: Page) =>
    page.evaluate(() => {
      const box = (node: Element | null) => {
        if (!node) return null;
        const rect = node.getBoundingClientRect();
        return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
      };
      const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
      const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      return {
        tray: box(tray)!,
        head: {
          row: box(head)!,
          title: box(head.querySelector(".acpmux-running-tray__title"))!,
          time: box(head.querySelector(".acpmux-running-tray__time"))!,
          chevron: box(head.querySelector(".acpmux-running-tray__status > svg"))!,
        },
        more: box(tray.querySelector(".acpmux-running-tray__finished > svg")),
        lines: [...tray.querySelectorAll<HTMLElement>(".acpmux-running-tray__list .acpmux-agent-line")].map((line) => ({
          row: box(line)!,
          // The lines time: on its row of controls, the last thing before Stops track (a done or
          // running line says no state word; design/chat-transcript.md "Subagent row anatomy").
          time: box(line.querySelector(".acpmux-agent-line__time"))!,
          track: box(line.querySelector(".acpmux-agent-line__stop-track"))!,
          slot: box(line.querySelector(".acpmux-agent-line__stop-slot"))!,
          stops: line.querySelectorAll(".acpmux-agent-line__stop-slot > button").length,
          chevron: box(line.querySelector(".acpmux-agent-line__chevron > svg")),
        })),
      };
    });

  const middle = (box: { top: number; bottom: number }) => (box.top + box.bottom) / 2;

  for (const width of [760, 300]) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`no line has a Stop; its track sits inside its line, and every chevron shares one x at ${width}px (${theme})`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width, height: 420 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "open", theme })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-running-tray__list .acpmux-agent-line").first().waitFor();
          await settle(page);
          const geometry = await measure(page);
          expect(geometry.lines.length).toBeGreaterThanOrEqual(3);
          expect(geometry.lines.every((line) => line.stops === 0)).toBe(true);
          for (const line of geometry.lines) {
            const slot = line.slot;
            // Inside the line's box.
            expect(slot.top).toBeGreaterThanOrEqual(line.row.top - 0.5);
            expect(slot.bottom).toBeLessThanOrEqual(line.row.bottom + 0.5);
            expect(slot.left).toBeGreaterThanOrEqual(line.row.left - 0.5);
            expect(slot.right).toBeLessThanOrEqual(line.row.right + 0.5);
            // On the centre line of its row of controls: the line's own when it is one row, its second
            // row (where its time sits) when the line is narrow.
            expect(Math.abs(middle(slot) - middle(line.time))).toBeLessThanOrEqual(1);
            if (width > 400) expect(Math.abs(middle(slot) - middle(line.row))).toBeLessThanOrEqual(1);
            // Over its own track, between the time and the chevron.
            expect(
              Math.abs((slot.left + slot.right) / 2 - (line.track.left + line.track.right) / 2),
            ).toBeLessThanOrEqual(1);
            expect(slot.left).toBeGreaterThanOrEqual(line.time.right - 0.5);
            if (line.chevron) expect(line.chevron.left).toBeGreaterThanOrEqual(slot.right - 0.5);
          }
          // The empty slot never takes a click: at its centre the line's own button is under the pointer.
          const hits = await page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")].map((line) => {
              const slot = line.querySelector<HTMLElement>(".acpmux-agent-line__stop-slot")!;
              slot.scrollIntoView({ block: "nearest" });
              const rect = slot.getBoundingClientRect();
              const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
              return Boolean(hit && line.querySelector(".acpmux-agent-line__button")?.contains(hit));
            }),
          );
          expect(hits.length).toBe(geometry.lines.length);
          expect(hits.every(Boolean)).toBe(true);
          await page.evaluate(() => document.querySelector(".acpmux-running-tray__list")?.scrollTo(0, 0));
          // Stop's track holds its x on every line.
          expect(new Set(geometry.lines.map((line) => line.track.left)).size).toBe(1);
          // One chevron column: the header's, every line's and View all's end on one x.
          const chevrons = [
            geometry.head.chevron.right,
            ...geometry.lines.flatMap((line) => (line.chevron ? [line.chevron.right] : [])),
            ...(geometry.more ? [geometry.more.right] : []),
          ];
          expect(chevrons.length).toBeGreaterThanOrEqual(2);
          for (const right of chevrons) expect(Math.abs(right - geometry.head.chevron.right)).toBeLessThanOrEqual(0.5);
          expect(geometry.head.chevron.right).toBeLessThanOrEqual(geometry.tray.right + 0.5);
          // The header is one row; its time follows its counts one 8px gap later.
          expect(geometry.head.row.bottom - geometry.head.row.top).toBeLessThanOrEqual(28.5);
          expect(geometry.head.time.left - geometry.head.title.right).toBeGreaterThanOrEqual(7.5);
          expect(geometry.head.time.left - geometry.head.title.right).toBeLessThanOrEqual(8.5);
          expect(Math.abs(middle(geometry.head.time) - middle(geometry.head.title))).toBeLessThanOrEqual(1);
          if (process.env.CMUX_TRAY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
            const tone = theme.endsWith("Light") ? "light" : "dark";
            const clip = await page.evaluate(() => {
              const tray = document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
              const composer = document.querySelector(".acpmux-composer")!.getBoundingClientRect();
              const top = Math.max(0, tray.top - 12);
              return { x: 0, y: top, width: innerWidth, height: Math.min(innerHeight, composer.bottom + 12) - top };
            });
            await page.screenshot({
              path: path.join(process.env.CMUX_TRAY_CAPTURE_DIR, `tray-open-${width}-${tone}.png`),
              clip,
            });
            await page.click(".acpmux-running-tray__head");
            await page.waitForFunction(
              () => document.querySelector(".acpmux-running-tray__head")?.getAttribute("aria-expanded") === "false",
            );
            await settle(page);
            const folded = await page.evaluate(() => {
              const tray = document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
              const composer = document.querySelector(".acpmux-composer")!.getBoundingClientRect();
              const top = Math.max(0, tray.top - 12);
              return { x: 0, y: top, width: innerWidth, height: Math.min(innerHeight, composer.bottom + 12) - top };
            });
            await page.screenshot({
              path: path.join(process.env.CMUX_TRAY_CAPTURE_DIR, `tray-folded-${width}-${tone}.png`),
              clip: folded,
            });
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
