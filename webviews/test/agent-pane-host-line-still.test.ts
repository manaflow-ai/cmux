// l10n-allow-file: test fixture prompts and the host line's stand-in text, not shipped UI.
// The host's line above the composer (HostError.tsx: "Reconnecting…", or a refusal and its Retry) moves
// no transcript row when it comes or goes while the view follows the latest row (Leo, 2026-11-16, after
// restarting his NIGHTLY: "it said something went wrong with a retry button just above the composer ...
// and then it layout shifted as it drew and tried to settle"). Before, the room under the last row took
// the line's height in the frame it came, and every row in view jumped up by it, then down when it went.
// The line is put in the floating stack where App.tsx draws `hostLine` (before the composer), as its
// commit does; the transcript sees it through the stack's size, as it sees the real one. Real Chromium
// against the pane's dev entry and a stand-in acpmux (support/papercutChat.ts); CI fails the file when
// it cannot launch it (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-host-line-still.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-host-line-still.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  /// Puts the host's line in the stack (or takes it out) and returns, for each frame painted after,
  /// how far each row in view before it moved, at most.
  const change = (page: Page, add: boolean) =>
    page.evaluate(
      async ({ add, rowSelector }) => {
        const tops = () =>
          new Map(
            [...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => [
              row.dataset.rowId!,
              row.getBoundingClientRect().top,
            ]),
          );
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const before = new Map([...tops()].filter(([, top]) => top > view.top && top < view.bottom));
        // After the frame paints: a task queued from its animation frame callback.
        const painted = () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => {
              const channel = new MessageChannel();
              channel.port1.onmessage = () => resolve();
              channel.port2.postMessage(0);
            }),
          );
        const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
        if (add) {
          // HostUnavailableLine's markup: the group, its line, the message and Retry.
          const group = document.createElement("div");
          group.className = "acpmux-host-line-group";
          group.dataset.testHostLine = "";
          group.innerHTML =
            '<div class="acpmux-host-line"><p class="acpmux-host-line-message">Can\'t reach the agent service.</p><button type="button">Retry</button></div>';
          dock.insertBefore(group, dock.querySelector(":scope > .acpmux-composer"));
        } else dock.querySelector("[data-test-host-line]")!.remove();
        const moved: number[] = [];
        for (let frame = 0; frame < 12; frame++) {
          await painted();
          const now = tops();
          let most = 0;
          for (const [id, top] of before) most = Math.max(most, Math.abs((now.get(id) ?? Infinity) - top));
          moved.push(most);
        }
        return {
          moved,
          rows: before.size,
          line: dock.querySelector("[data-test-host-line]")?.getBoundingClientRect().height ?? 0,
        };
      },
      { add, rowSelector: TRANSCRIPT_ROW },
    );

  test("the host line coming and going above the composer moves no row in view", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      const at = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return node.scrollHeight - node.clientHeight - node.scrollTop;
      });
      // The view follows the latest row.
      expect(at).toBeLessThanOrEqual(2);
      const came = await change(page, true);
      expect(came.rows).toBeGreaterThan(3);
      // The line took room in the stack (it is not an empty stand-in).
      expect(came.line).toBeGreaterThan(16);
      for (const moved of came.moved) expect(moved).toBeLessThanOrEqual(0.5);
      const went = await change(page, false);
      for (const moved of went.moved) expect(moved).toBeLessThanOrEqual(0.5);
    } finally {
      await page.close();
    }
  });
});
