// l10n-allow-file: synthetic long-chat fixtures, never private session content.
// Leo: "Sometimes it's literally impossible to scroll upwards because it keeps trying to
// re-render or strema or recalculate or whatever the fuck".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = { at: number; top: number; gap: number; anchor: number | null };
type Write = { at: number; from: number; to: number; stack: string };
type Probe = Window & {
  lockout: { frames: Frame[]; writes: Write[]; stop: () => void; anchorId?: string };
};

await requireBrowserLane("transcript-scroll-lockout.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  const output = process.env.CMUX_LOCKOUT_OUTPUT ?? "/tmp/cmux-scroll-lockout";
  const update = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  beforeAll(async () => {
    mkdirSync(output, { recursive: true });
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 3000,
      running: true,
      extra: [["in", "agent_message_chunk", update("Streaming fixture.\n\n" + "Initial paragraph with wrapped content. ".repeat(100))]],
      ready: ".acpmux-row .cv-markdown",
    });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  async function paint(page: Page, count = 3) {
    await page.evaluate(async (count) => {
      for (let n = 0; n < count; n++) await window.cmuxPaintFrame();
    }, count);
  }
  async function probe(page: Page) {
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const w = window as unknown as Probe;
      const data = (w.lockout = { frames: [], writes: [], stop: () => {} } as Probe["lockout"]);
      const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
      Object.defineProperty(node, "scrollTop", {
        configurable: true,
        get: () => descriptor.get!.call(node),
        set: (to: number) => {
          data.writes.push({ at: performance.now(), from: descriptor.get!.call(node), to, stack: new Error().stack ?? "" });
          descriptor.set!.call(node, to);
        },
      });
      const viewport = node.getBoundingClientRect();
      const row = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => {
        const rect = row.getBoundingClientRect();
        return rect.top >= viewport.top && rect.top < viewport.bottom;
      });
      data.anchorId = row?.dataset.rowId;
      data.stop = window.cmuxAfterPaint((at) => {
        const bounds = node.getBoundingClientRect();
        const rows = [...node.querySelectorAll<HTMLElement>(".acpmux-row")];
        const visible = rows.map((row) => row.getBoundingClientRect()).filter((r) => r.bottom > bounds.top && r.top < bounds.bottom);
        const first = Math.min(...visible.map((r) => r.top));
        const anchor = rows.find((row) => row.dataset.rowId === data.anchorId);
        data.frames.push({ at, top: node.scrollTop, gap: visible.length ? Math.max(0, first - bounds.top) : node.clientHeight, anchor: anchor?.getBoundingClientRect().top ?? null });
        return true;
      });
    });
  }

  for (const scenario of ["tail-one-pixel", "remeasure", "tool-fold"] as const) {
    test(`3000 turns: upward input stays released during 10s stream (${scenario})`, async () => {
      const page = await pane.open({ width: 900, height: 700 });
      try {
        const scroller = page.locator(".acpmux-scroll");
        await page.getByText("Streaming fixture.", { exact: false }).first().waitFor();
        const box = (await scroller.boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await probe(page);
        const before = await scroller.evaluate((node) => node.scrollTop);
        await page.mouse.wheel(0, scenario === "tail-one-pixel" ? -1 : -250);
        await paint(page);
        const parked = await scroller.evaluate((node) => node.scrollTop);
        const cutoff = await page.evaluate(() => performance.now());
        await page.screenshot({ path: `${output}/${scenario}-before.png` });
        const started = performance.now();
        let chunks = 0;
        let folded = false;
        let unfolded = false;
        let resized = false;
        while (performance.now() - started < 10_000) {
          pane.record("agent_message_chunk", update(`Stream chunk ${chunks++}: new words below the reader.\n\n`), "in");
          if (scenario === "remeasure" && !resized && chunks >= 20) {
            await page.setViewportSize({ width: 700, height: 700 });
            resized = true;
          }
          if (scenario === "tool-fold" && chunks >= 20 && !folded) {
            const toggle = page.locator(".cv-worked, .cv-tools > .cv-tool.is-toggle").last();
            if (await toggle.isVisible()) { await toggle.click(); folded = true; }
          }
          if (scenario === "tool-fold" && chunks >= 40 && folded && !unfolded) {
            const toggle = page.locator(".cv-worked, .cv-tools > .cv-tool.is-toggle").last();
            if (await toggle.isVisible()) { await toggle.click(); unfolded = true; }
          }
          // fixed-wait: the daemon token cadence is the input under test, not a readiness wait.
          await Bun.sleep(50);
        }
        await paint(page, 5);
        const data = await page.evaluate(() => {
          const data = (window as unknown as Probe).lockout;
          data.stop();
          return { frames: data.frames, writes: data.writes, anchorId: data.anchorId };
        });
        const frames = data.frames.filter((frame) => frame.at >= cutoff);
        const writes = data.writes.filter((write) => write.at >= cutoff);
        const rises = frames.slice(1).filter((frame, i) => frame.top > frames[i]!.top + 0.5);
        const times = frames.slice(1).map((frame, i) => frame.at - frames[i]!.at).sort((a, b) => a - b);
        const anchors = frames.flatMap((frame) => frame.anchor === null ? [] : [frame.anchor]);
        const metrics = {
          scenario, turns: 3000, chunks, before, parked, frames: frames.length,
          writes: writes.length, downwardWrites: writes.filter((w) => w.to > w.from + 0.5).length,
          unintendedDrift: Math.max(0, ...frames.map((f) => f.top - parked)), rises: rises.length,
          emptyGap: Math.max(0, ...frames.map((f) => f.gap)),
          anchorDrift: anchors.length ? Math.max(...anchors) - Math.min(...anchors) : null,
          frameP95: times[Math.floor(times.length * 0.95)], frameMax: times.at(-1),
          folded, unfolded, resized,
        };
        console.log("SCROLL_LOCKOUT", JSON.stringify(metrics));
        writeFileSync(`${output}/${scenario}.json`, JSON.stringify({ metrics, ...data }, null, 2));
        await page.screenshot({ path: `${output}/${scenario}-after.png` });
        expect(parked).toBeLessThan(before - 0.5);
        expect(frames.length).toBeGreaterThan(20);
        if (scenario === "tail-one-pixel") {
          expect(metrics.unintendedDrift).toBeLessThanOrEqual(1);
          expect(metrics.downwardWrites).toBe(0);
          expect(metrics.rises).toBe(0);
        } else if (scenario === "remeasure") {
          expect(resized).toBe(true);
          expect(metrics.anchorDrift).not.toBeNull();
          expect(metrics.anchorDrift!).toBeLessThanOrEqual(2);
        } else {
          expect(folded).toBe(true);
          expect(unfolded).toBe(true);
        }
      } finally { await page.close(); }
    });
  }
});
