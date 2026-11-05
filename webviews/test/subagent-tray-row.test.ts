// l10n-allow-file: gallery fixture names and tray labels are test data.
// The running tray's line as Claude Code's and ChatGPT's task rows read (Leo, 2026-11-02, on a done
// line above the composer: "this running thing now looks mildly awkward"). His line read just
// "Subagent", "36s Done" sat at the far right, and the reply's footer icons showed through it, since
// a lone ended line drew no surface over the transcript. In real Chromium (Playwright; CI fails the
// file when it cannot launch, requireBrowserLane), on gallery `agent-pane.subagent-row-anatomy`:
// - the line's title is its task, not "Subagent";
// - its state word comes before its time ("Done · 36s"); a running line shows its time alone;
// - the tray draws a surface (a fill, or the composer's frost), settled or running;
// - that surface spans the composer card's width, edge to edge.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-row.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagent-row-anatomy";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "done-task-label" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const variant of ["done-task-label", "running-one"] as const) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`${variant}: the task names the line, its state precedes its time, and it sits on the composer-wide glass (${theme})`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({ viewport: { width: 760, height: 360 }, reducedMotion: "reduce" });
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-running-tray .acpmux-agent-line").first().waitFor();
          const row = await page.evaluate(() => {
            for (const animation of document.getAnimations()) {
              if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
            }
            const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
            const line = tray.querySelector<HTMLElement>(".acpmux-agent-line")!;
            const box = (node: Element) => {
              const rect = node.getBoundingClientRect();
              return { left: rect.left, right: rect.right, width: rect.width };
            };
            const style = getComputedStyle(tray);
            return {
              title: line.querySelector(".acpmux-summary-agent__name")?.textContent ?? "",
              state: box(line.querySelector(".acpmux-agent-line__meta")!),
              stateText: line.querySelector(".acpmux-summary-agent__state")?.textContent ?? "",
              time: box(line.querySelector(".acpmux-agent-line__time")!),
              timeText: line.querySelector(".acpmux-agent-line__time")?.textContent ?? "",
              tray: box(tray),
              composer: box(document.querySelector(".acpmux-composer-box")!),
              background: style.backgroundColor,
              image: style.backgroundImage,
              frost: style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter"),
            };
          });
          // The task names it, never the bare kind word.
          expect(row.title).toBe(
            variant === "done-task-label"
              ? "Review the subagent tray row"
              : "Audit the bottom stack for motion that skips the tokens",
          );
          // The state word, then its time: "Done · 36s". A running line shows its time alone, with
          // no Running word (Leo, 2026-11-03: "do we really need a running symbol vs just having the
          // time and a square stop button?").
          expect(row.stateText).toBe(variant === "done-task-label" ? "Done" : "");
          expect(row.timeText).not.toBe("");
          expect(row.state.right).toBeLessThanOrEqual(row.time.left + 0.5);
          // A surface the transcript never shows through: a fill, a frost, or both.
          const painted = row.background !== "rgba(0, 0, 0, 0)" || row.image !== "none";
          expect(painted).toBe(true);
          expect(row.frost === "" || row.frost === "none").toBe(false);
          // That surface is the composer card's width, edge to edge.
          expect(Math.abs(row.tray.left - row.composer.left)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(row.tray.right - row.composer.right)).toBeLessThanOrEqual(0.5);
        } finally {
          await page.close();
        }
      });
    }
  }
});
