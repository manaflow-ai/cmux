// cmux-web-test-timeout: 300
// l10n-allow-file: assertions on the English catalog's words.
// A slow acpmux after a drop, end to end: the pane's own chip above the composer while it waits
// (HostError.tsx). The stand-in daemon holds its answers to the reconnect's watch and attach
// (support/papercutChat.ts `stall`) and the connection drops, as a restarted, busy acpmux does. Then:
// - Nothing shows for as long as the wait lasts: the chip follows the connection's state, not a clock,
//   and a reconnect still waiting on acpmux has not failed, so it draws nothing (only a failed attempt
//   shows the chip, hostRecoveryChip.test.tsx). No line with a clock or a Restart button at any time
//   (Leo, 2026-11-22, on "Waiting for the agent service (0:46)  Restart agent service": "this is
//   unactionable"; and "surely we can think of better fixes than random timing which can shift").
// - No transcript row in view moves through any of it.
// Real Chromium against the pane's dev entry; CI fails the file when it cannot launch it
// (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-reconnect-wait-line.test.ts
// With CMUX_FRAMES_DIR set it writes stills of the chip there.
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

  test("a slow reconnect draws nothing at any duration, never a clock or a button, and no row moves", async () => {
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
          const seen: { t: number; line: string; buttons: number; moved: number }[] = [];
          await new Promise<void>((resolve) => {
            window.cmuxAfterPaint(() => {
              const t = performance.now() - start;
              const slot = document.querySelector<HTMLElement>(".acpmux-dock [data-host-slot]");
              const now = tops();
              let moved = 0;
              for (const [id, top] of first) moved = Math.max(moved, Math.abs((now.get(id) ?? Infinity) - top));
              seen.push({
                t: Math.round(t),
                line: slot?.textContent?.trim() ?? "",
                buttons: slot?.querySelectorAll("button").length ?? 0,
                moved,
              });
              // Well past the old 25 s hand-over.
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
        // Stills of the chip. Optional evidence only (CMUX_FRAMES_DIR); the assertions below read every
        // painted frame.
        // fixed-wait: a still just past the old 25 s hand-over, the moment under test.
        await page.waitForTimeout(25_800);
        await page.screenshot({ path: path.join(frames, "reconnect-chip-25.8s.png") });
      }
      const seen = await sampling;
      const lines = [...new Set(seen.map((frame) => frame.line))];
      console.log(
        `RECONNECT-WAIT ${JSON.stringify({
          frames: seen.length,
          lines,
          movedPx: Math.max(...seen.map((frame) => frame.moved)),
        })}`,
      );
      expect(seen.length).toBeGreaterThan(0);
      // No clock decides anything: a wait still in progress draws nothing, however long it lasts.
      expect(lines).toEqual([""]);
      for (const frame of seen) {
        expect(frame.buttons).toBe(0);
        expect(frame.moved).toBeLessThanOrEqual(0.5);
      }
    } finally {
      pane.stall([]);
      await page.close();
    }
  });
});
