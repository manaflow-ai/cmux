// l10n-allow-file: test fixture prompts and the notices' stand-in text, not shipped UI.
// A notice that comes into the chat's bottom stack after the chat has painted moves neither the
// composer nor any transcript row in view (Leo, 2026-11-16, after restarting his NIGHTLY: "it said
// something went wrong with a retry button just above the composer ... and then it layout shifted as it
// drew and tried to settle"). #45558 made the host's own line (HostError.tsx, `.acpmux-host-line` and
// `.acpmux-host-line-group`, test/agent-pane-host-line-still.test.ts) lie over the transcript's foot;
// the composer's other notices take their own height in the same stack (bottomStack.css), held the same way
// (Leo, 2026-11-22: "that message should not shift layout"; no row moves, the composer neither): an app notice about the agent service (PaneNotices.tsx, `.acpmux-host-error`) and the
// daemon's "Retrying…" line (AutoResumeNotice.tsx, `.acpmux-switch-notice`), both of which a relaunch
// can bring late. Each is put in the floating stack where App.tsx draws it (before the composer form),
// with its markup; the transcript sees it through the stack's size, as it sees the real one. Real
// Chromium against the pane's dev entry and a stand-in acpmux (support/papercutChat.ts). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-dock-notice-still.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-dock-notice-still.test.ts", async () => {
  const NOTICES = {
    // PaneNoticeCard's markup: an app notice about the chat's agent service, with its button.
    paneNotice:
      '<output class="acpmux-host-error acpmux-harness-notice" data-pane-notice="test" data-test-dock-notice=""><div class="acpmux-host-error-card"><p class="acpmux-host-error-message">The agent service restarted.</p><p class="acpmux-host-error-hint">Approvals wait until it is back.</p><div class="acpmux-host-error-actions"><button type="button">Retry</button></div></div></output>',
    // AutoResumeNotice's markup: the daemon waits to retry the turn.
    autoResume:
      '<output class="acpmux-switch-notice" data-auto-resume="waiting" data-test-dock-notice="">Retrying in 5s…</output>',
  } as const;
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

  /// Puts the notice in the stack (or takes it out) and returns, for each frame painted after, how far
  /// each row in view before it moved, at most, and how far the composer card's top moved.
  const change = (page: Page, html: string | undefined) =>
    page.evaluate(
      async ({ html, rowSelector }) => {
        const tops = () =>
          new Map(
            [...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => [
              row.dataset.rowId!,
              row.getBoundingClientRect().top,
            ]),
          );
        const box = () => document.querySelector<HTMLElement>(".acpmux-composer-box")!.getBoundingClientRect().top;
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const before = new Map([...tops()].filter(([, top]) => top > view.top && top < view.bottom));
        const boxBefore = box();
        // The free room between the newest row's bottom and the stack's top: what a notice may cover (#45558).
        const lastBottom = Math.max(
          ...[...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => row.getBoundingClientRect().bottom),
        );
        const dockTop = document.querySelector<HTMLElement>(".acpmux-dock")!.getBoundingClientRect().top;
        const gap = Math.max(0, dockTop - lastBottom);
        const painted = () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => {
              const channel = new MessageChannel();
              channel.port1.onmessage = () => resolve();
              channel.port2.postMessage(0);
            }),
          );
        const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
        const start = performance.now();
        if (html) {
          const holder = document.createElement("div");
          holder.innerHTML = html;
          dock.insertBefore(holder.firstElementChild!, dock.querySelector(":scope > .acpmux-composer"));
        } else dock.querySelector("[data-test-dock-notice]")!.remove();
        const rows: number[] = [];
        const composer: number[] = [];
        // The settle: from the change to the last painted frame in which a row in view or the composer
        // moved more than 1 px (0 when none did).
        let settle = 0;
        for (let frame = 0; frame < 12; frame++) {
          await painted();
          const now = tops();
          let most = 0;
          for (const [id, top] of before) most = Math.max(most, Math.abs((now.get(id) ?? Infinity) - top));
          rows.push(Math.round(most * 10) / 10);
          composer.push(Math.round(Math.abs(box() - boxBefore) * 10) / 10);
          if (rows.at(-1)! > 1 || composer.at(-1)! > 1) settle = performance.now() - start;
        }
        return {
          rows,
          composer,
          settle: Math.round(settle),
          gap: Math.round(gap),
          inView: before.size,
          notice: dock.querySelector("[data-test-dock-notice]")?.getBoundingClientRect().height ?? 0,
        };
      },
      { html, rowSelector: TRANSCRIPT_ROW },
    );

  for (const [name, html] of Object.entries(NOTICES)) {
    test(`a ${name} coming and going in the bottom stack moves no row in view and not the composer`, async () => {
      const page = await pane.open({ width: 900, height: 700 });
      try {
        const at = await page.evaluate(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          return node.scrollHeight - node.clientHeight - node.scrollTop;
        });
        // The view follows the latest row.
        expect(at).toBeLessThanOrEqual(2);
        const came = await change(page, html);
        console.log(
          `${name} came (${came.notice}px tall, ${came.gap}px free under the newest row): rows moved ${came.rows.join(",")}; composer moved ${came.composer.join(",")}; settled ${came.settle} ms`,
        );
        expect(came.inView).toBeGreaterThan(3);
        // The notice took room in the stack (it is not an empty stand-in).
        expect(came.notice).toBeGreaterThan(12);
        expect(Math.max(...came.composer)).toBeLessThanOrEqual(1);
        // A notice lies over the free room under the newest row (#45558's rule), and one taller than that room
        // (the agent-service card) lies over the newest row's foot too: no row moves for any notice (Leo,
        // 2026-11-22: "that message should not shift layout"). The room takes it once the rows move anyway.
        expect(Math.max(...came.rows)).toBeLessThanOrEqual(1);
        const went = await change(page, undefined);
        console.log(
          `${name} went: rows moved ${went.rows.join(",")}; composer moved ${went.composer.join(",")}; settled ${went.settle} ms`,
        );
        expect(Math.max(...went.composer)).toBeLessThanOrEqual(1);
        expect(Math.max(...went.rows)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });
  }
});
