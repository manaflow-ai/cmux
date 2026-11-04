// l10n-allow-file: gallery fixture tray labels are test data.
// Leo, 2026-11-04, on the tray's two- and three-row agent lines (#34480): "I don't like how
// misaligned and how much extra space those agent cards take compared to the past one lines we
// had/how Claude code just has one lines too". Every agent line is one row again, at 760px and at
// 360px: its title, what it did last muted after it, then its state, time and Stop in their fixed
// columns. And what needs the person (the failed line here) leads the list, so the list's cap never
// clips it while the header says "1 failed". In real Chromium (Playwright; CI fails the file when it
// cannot launch, requireBrowserLane). CMUX_TRAY_CAPTURE_DIR keeps a still of each width.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { openRunningTray } from "./support/openRunningTray";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-one-row.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.parallel-agents";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "four-agents" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const width of [760, 360]) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`four agents: one row each, aligned columns, the failed line first at ${width}px (${theme})`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width, height: 620 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "four-agents", theme })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-running-tray").waitFor();
          await openRunningTray(page);
          if (process.env.CMUX_TRAY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_TRAY_CAPTURE_DIR, { recursive: true });
            await page.screenshot({
              path: path.join(
                process.env.CMUX_TRAY_CAPTURE_DIR,
                `parallel-four-agents-${width}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
              ),
            });
          }
          const geometry = await page.evaluate(() => {
            const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
            const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
            const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
            const box = (node: Element | null) => {
              const rect = node!.getBoundingClientRect();
              return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, height: rect.height };
            };
            return {
              head: box(head),
              list: box(list),
              lines: [...list.querySelectorAll<HTMLElement>(".acpmux-agent-line")].map((line) => ({
                name: line.querySelector(".acpmux-summary-agent__name")!.textContent,
                status: line.dataset.status,
                line: box(line),
                inline: Boolean(line.querySelector(".acpmux-agent-line__latest-inline")),
                below: Boolean(line.querySelector(".acpmux-agent-line__latest")),
                text: box(line.querySelector(".acpmux-summary-text")),
                time: box(line.querySelector(".acpmux-agent-line__time")),
                track: box(line.querySelector(".acpmux-agent-line__stop-track")),
                chevron: box(line.querySelector(".acpmux-agent-line__chevron, .acpmux-agent-line__chevron-track")),
              })),
            };
          });
          expect(geometry.lines).toHaveLength(4);
          // The failed line leads, then the rest in the tray's own order.
          expect(geometry.lines[0]!.status).toBe("failed");
          // Every line is one row, the header's height, and every line is inside the list's box.
          for (const line of geometry.lines) {
            expect(Math.abs(line.line.height - geometry.head.height)).toBeLessThanOrEqual(0.5);
            expect(line.line.bottom).toBeLessThanOrEqual(geometry.list.bottom + 0.5);
            expect(line.below).toBe(false);
          }
          // The running lines say what they did last after their titles, on the same row.
          expect(geometry.lines.filter((line) => line.inline).length).toBeGreaterThanOrEqual(2);
          // The time, Stop and chevron columns line up across the rows, each on its title's row.
          const [first] = geometry.lines;
          for (const line of geometry.lines) {
            expect(Math.abs(line.time.right - first!.time.right)).toBeLessThanOrEqual(0.5);
            expect(Math.abs(line.track.left - first!.track.left)).toBeLessThanOrEqual(0.5);
            expect(Math.abs(line.chevron.right - first!.chevron.right)).toBeLessThanOrEqual(0.5);
            const middle = (rect: { top: number; bottom: number }) => (rect.top + rect.bottom) / 2;
            expect(Math.abs(middle(line.time) - middle(line.text))).toBeLessThanOrEqual(1);
            expect(line.text.right).toBeLessThanOrEqual(line.time.left + 0.5);
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
