// cmux-web-test-timeout: 300
// l10n-allow-file: assertions on the English catalog's words.
// A slow acpmux after a drop, end to end: the pane's own lines above the composer while it waits
// (HostError.tsx). The stand-in daemon holds its answers to the reconnect's watch and attach
// (support/papercutChat.ts `stall`) and the connection drops, as a restarted, busy acpmux does. Then:
// - Nothing at all shows until "Waiting for the agent service (0:25)": no "Reconnecting…" at any point
//   (Leo, 2026-11-22: "i dont wanna see reconnecting to the Mac in a toast, i want it to just
//   connect"), and once the waiting line shows no painted frame drops it.
// - The waiting line's Restart agent service holds its place while the time ticks (before: it moved
//   sideways with each second's digits, the time not being the shared fixed-width clock).
// - No transcript row in view moves through any of it.
// Real Chromium against the pane's dev entry; CI fails the file when it cannot launch it
// (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-reconnect-wait-line.test.ts
// With CMUX_FRAMES_DIR set it writes a still of the hand-over and of the ticking line there.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-reconnect-wait-line.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: false });
  });
  afterAll(async () => {
    pane?.stall([]);
    await pane?.close();
    await browser?.close();
  });

  test("a slow reconnect's lines hand over with no blank frame, the Restart button holds still, and no row moves", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    const frames = process.env.CMUX_FRAMES_DIR;
    try {
      pane.stall(["_acpmux/watch", "_acpmux/attach"]);
      pane.drop();
      const sampling = page.evaluate(
        async ({ rowSelector }) => {
          const tops = () =>
            new Map(
              [...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => [
                row.dataset.rowId!,
                row.getBoundingClientRect().top,
              ]),
            );
          const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
          const first = new Map([...tops()].filter(([, top]) => top > view.top && top < view.bottom));
          const start = performance.now();
          const seen: { t: number; line: string; restartX?: number; moved: number }[] = [];
          await new Promise<void>((resolve) => {
            window.cmuxAfterPaint(() => {
              const t = performance.now() - start;
              const dock = document.querySelector<HTMLElement>(".acpmux-dock");
              const line = dock?.querySelector(
                ":scope > .acpmux-host-slot > .acpmux-host-line, :scope > .acpmux-host-slot > .acpmux-host-line-group",
              );
              const restart = line?.querySelector<HTMLElement>(".acpmux-host-line-quiet");
              const now = tops();
              let moved = 0;
              for (const [id, top] of first) moved = Math.max(moved, Math.abs((now.get(id) ?? Infinity) - top));
              seen.push({
                t: Math.round(t),
                line: line?.querySelector(".acpmux-host-line-message")?.textContent ?? "",
                restartX: restart ? Math.round(restart.getBoundingClientRect().left * 100) / 100 : undefined,
                moved,
              });
              // Until the waiting line has ticked a few seconds.
              if (t < 30_500) return true;
              resolve();
              return false;
            });
          });
          return seen;
        },
        { rowSelector: TRANSCRIPT_ROW },
      );
      if (frames) {
        // Stills: the hand-over moment and the line ticking. Optional evidence only (CMUX_FRAMES_DIR);
        // the assertions below read every painted frame.
        // fixed-wait: a still of a moment on the reconnect's own 25 s clock, the one under test.
        await page.waitForTimeout(24_900);
        await page.screenshot({ path: path.join(frames, "reconnect-handover-25.2s.png") });
        // fixed-wait: the second still, inside the second the line used to be gone.
        await page.waitForTimeout(600);
        await page.screenshot({ path: path.join(frames, "reconnect-handover-25.8s.png") });
        // fixed-wait: the waiting line a few ticks on.
        await page.waitForTimeout(2_200);
        await page.screenshot({ path: path.join(frames, "waiting-line-ticking.png") });
      }
      const seen = await sampling;
      const shownAt = seen.findIndex((frame) => frame.line);
      const after = seen.slice(shownAt);
      const blank = after.filter((frame) => !frame.line);
      const waiting = after.filter((frame) => frame.line.startsWith("Waiting for the agent service"));
      const xs = [...new Set(waiting.map((frame) => frame.restartX))];
      console.log(
        `RECONNECT-WAIT ${JSON.stringify({
          reconnectingAt: seen[shownAt]?.t,
          waitingAt: waiting[0]?.t,
          blankFrames: blank.length,
          blankMs: blank.length ? blank.at(-1)!.t - blank[0]!.t : 0,
          restartXs: xs,
          ticks: new Set(waiting.map((frame) => frame.line)).size,
          movedPx: Math.max(...seen.map((frame) => frame.moved)),
        })}`,
      );
      expect(seen[shownAt]?.line).toStartWith("Waiting for the agent service");
      expect(seen.filter((frame) => frame.line.includes("Reconnecting"))).toEqual([]);
      expect(waiting.length).toBeGreaterThan(0);
      // The line ticked over several seconds.
      expect(new Set(waiting.map((frame) => frame.line)).size).toBeGreaterThanOrEqual(3);
      expect(blank.map((frame) => frame.t)).toEqual([]);
      expect(xs.length).toBe(1);
      for (const frame of seen) expect(frame.moved).toBeLessThanOrEqual(0.5);
    } finally {
      pane.stall([]);
      await page.close();
    }
  });
});
