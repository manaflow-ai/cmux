// l10n-allow-file: the gallery fixture supplies the three status words this geometry contract measures.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-composer-geometry.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, "agent-pane.subagent-tray", {
      browser,
      params: { variant: "geometry" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const width of [760, 300, 200]) {
    test(`running tray tracks share the composer controls at ${width}px`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({
        viewport: { width, height: 520 },
        deviceScaleFactor: 2,
        reducedMotion: "reduce",
      });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.subagent-tray", { variant: "geometry" })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const head = page.locator(".acpmux-running-tray__head");
        if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
        await page.locator(".acpmux-running-tray .acpmux-agent-line").first().waitFor();
        const geometry = await page.evaluate(() => {
          const rect = (node: Element | null) => {
            if (!node) return null;
            const r = node.getBoundingClientRect();
            return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
          };
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const rows = [...tray.querySelectorAll<HTMLElement>(".acpmux-agent-line")].map((row) => ({
            row: rect(row)!,
            scrollWidth: row.scrollWidth,
            clientWidth: row.clientWidth,
            button: rect(row.querySelector(".acpmux-agent-line__button"))!,
            leading: rect(row.querySelector(".acpmux-lineage__icon"))!,
            time: rect(row.querySelector(".acpmux-agent-line__time"))!,
            status: rect(row.querySelector("[data-tray-status]"))!,
            stopTrack: rect(row.querySelector(".acpmux-agent-line__stop-track"))!,
            stop: rect(row.querySelector(".acpmux-agent-line__stop-slot > button")),
            chevron: rect(row.querySelector(".acpmux-agent-line__chevron, .acpmux-agent-line__chevron-track"))!,
            statusText: row.querySelector("[data-tray-status]")?.textContent?.trim() ?? "",
          }));
          const composer = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
          return {
            composer: rect(composer)!,
            plus: rect(document.querySelector(".acpmux-composer-plus")),
            mic: rect(document.querySelector(".acpmux-composer-actions .acpmux-mic"))!,
            stop: rect(document.querySelector(".acpmux-composer-actions .acpmux-cancel"))!,
            rows,
          };
        });
        expect(geometry.rows).toHaveLength(3);
        expect(geometry.rows.map((row) => row.statusText).join(" ")).toMatch(/Running/);
        expect(geometry.rows.map((row) => row.statusText).join(" ")).toMatch(/Done/);
        expect(geometry.rows.map((row) => row.statusText).join(" ")).toMatch(/Cancelled/);
        if (!geometry.stop || !geometry.mic) throw new Error("the running composer must expose Stop and mic controls");
        const center = (r: { left: number; right: number; top: number; bottom: number }) => ({
          x: (r.left + r.right) / 2,
          y: (r.top + r.bottom) / 2,
        });
        const within = (actual: number, expected: number) =>
          expect(Math.abs(actual - expected)).toBeLessThanOrEqual(0.5);
        expect(geometry.rows.filter((row) => row.stop)).toHaveLength(1);
        within(
          geometry.rows[0]!.leading.left - geometry.rows[0]!.row.left,
          geometry.composer.right - geometry.mic.right,
        );
        // The composer may hide + at the narrow fit step; when present, its inset is the
        // leading-row inset the tray follows.
        if (geometry.plus)
          within(
            geometry.rows[0]!.leading.left - geometry.rows[0]!.row.left,
            geometry.plus.left - geometry.composer.left,
          );
        for (const row of geometry.rows) {
          expect(row.scrollWidth).toBeLessThanOrEqual(row.clientWidth + 1);
          within(row.row.left, geometry.composer.left);
          within(row.row.right, geometry.composer.right);
          within(center(row.chevron).x, center(geometry.mic).x);
          // The time and the state are one cluster at the line's end, one tray gap apart, and one
          // gap before the line's next control: Stop's track on a line with Stop, else the chevron
          // (cmux#31492: "8m 56s Done" floated a Stop track and a status track's slack away).
          const next = row.stop ? row.stopTrack.left : row.chevron.left;
          const gaps = [row.status.left - row.time.right, next - row.status.right, row.chevron.left - row.stopTrack.right];
          expect(gaps[0]).toBeGreaterThan(0);
          for (const gap of gaps) within(gap, gaps[0]!);
          within(row.stopTrack.left, geometry.rows[0]!.stopTrack.left);
          within(row.chevron.right, geometry.rows[0]!.chevron.right);
          within(geometry.composer.right - row.chevron.right, geometry.composer.right - geometry.mic.right);
          if (row.stop) {
            within(center(row.stop).x, center(geometry.stop).x);
            within(row.stop.right, geometry.stop.right);
            within(center(row.stop).y, center(row.time).y);
            within(center(row.chevron).y, center(row.time).y);
            expect(center(row.stop).y).toBeGreaterThanOrEqual(row.row.top - 0.5);
            expect(center(row.stop).y).toBeLessThanOrEqual(row.row.bottom + 0.5);
          }
        }
      } finally {
        await page.close();
      }
    });
  }
});
