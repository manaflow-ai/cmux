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
  lockout: {
    frames: Frame[];
    writes: Write[];
    stop: () => void;
    anchorId?: string;
    paragraph?: number;
    lastUpAt?: number;
    nativeWheelTop?: number;
  };
};

await requireBrowserLane("transcript-scroll-lockout.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  const output = process.env.CMUX_LOCKOUT_OUTPUT ?? "/tmp/cmux-scroll-lockout";
  const update = (text: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  });
  beforeAll(async () => {
    mkdirSync(output, { recursive: true });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
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
          data.writes.push({
            at: performance.now(),
            from: descriptor.get!.call(node),
            to,
            stack: new Error().stack ?? "",
          });
          descriptor.set!.call(node, to);
        },
      });
      const viewport = node.getBoundingClientRect();
      const paragraph = [...node.querySelectorAll<HTMLElement>(".acpmux-row .cv-md p")].find((item) => {
        const rect = item.getBoundingClientRect();
        return rect.top >= viewport.top && rect.top < viewport.bottom;
      });
      const row = paragraph?.closest<HTMLElement>(".acpmux-row");
      data.anchorId = row?.dataset.rowId;
      data.paragraph = row && paragraph ? [...row.querySelectorAll(".cv-md p")].indexOf(paragraph) : undefined;
      const reader = (event: WheelEvent) => {
        if (event.deltaY < 0 && event.target instanceof Node && node.contains(event.target)) {
          data.lastUpAt = performance.now();
          data.nativeWheelTop = node.scrollTop;
        }
      };
      window.addEventListener("wheel", reader, { capture: true, passive: true });
      const stopFrames = window.cmuxAfterPaint((at) => {
        const bounds = node.getBoundingClientRect();
        const rows = [...node.querySelectorAll<HTMLElement>(".acpmux-row")];
        // Read only mounted content; absolute virtual row boxes can cover a visible empty gap.
        const visible = [...node.querySelectorAll<HTMLElement>(".cv-md p, .cv-tool, .cv-worked")]
          .map((item) => item.getBoundingClientRect())
          .filter((rect) => rect.bottom > bounds.top && rect.top < bounds.bottom)
          .sort((a, b) => a.top - b.top);
        let cursor = bounds.top;
        let gap = 0;
        for (const rect of visible) {
          gap = Math.max(gap, rect.top - cursor);
          cursor = Math.max(cursor, rect.bottom);
        }
        if (!visible.length) gap = node.clientHeight;
        const anchorRow = rows.find((row) => row.dataset.rowId === data.anchorId);
        const anchor =
          data.paragraph === undefined ? anchorRow : anchorRow?.querySelectorAll(".cv-md p")[data.paragraph];
        data.frames.push({
          at,
          top: node.scrollTop,
          gap,
          anchor: anchor?.getBoundingClientRect().top ?? null,
        });
        return true;
      });
      data.stop = () => {
        stopFrames();
        window.removeEventListener("wheel", reader, { capture: true });
      };
    });
  }

  for (const scenario of ["tail-one-pixel", "remeasure", "tool-fold"] as const) {
    test(`3000 turns: upward input stays released during 10s stream (${scenario})`, async () => {
      pane = await papercutPane(() => browser, {
        turns: 3000,
        running: true,
        extra: [
          [
            "in",
            "agent_message_chunk",
            update(
              "Streaming fixture.\n\n" +
                Array.from(
                  { length: scenario === "tail-one-pixel" ? 40 : 3 },
                  (_, i) => `Initial paragraph ${i}: ${"Wrapped fixture words. ".repeat(8)}\n\n`,
                ).join(""),
            ),
          ],
        ],
        ready: ".acpmux-row .cv-md",
      });
      const page = await pane.open({ width: 900, height: 700 }).catch(async (error: unknown) => {
        await pane.close();
        throw error;
      });
      let streaming = false;
      let stream: Promise<void> = Promise.resolve();
      try {
        const scroller = page.locator(".acpmux-scroll");
        await page.getByText("Streaming fixture.", { exact: false }).first().waitFor();
        const box = (await scroller.boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await probe(page);
        let chunks = 0;
        streaming = true;
        stream = (async () => {
          const started = performance.now();
          while (streaming && performance.now() - started < 10_000) {
            // fixed-wait: the daemon token cadence is the input under test, not a readiness wait.
            await Bun.sleep(50);
            if (streaming)
              pane.record(
                "agent_message_chunk",
                update(`Stream chunk ${chunks++}: new words below the reader.\n\n`),
                "in",
              );
          }
        })();
        if (scenario === "tail-one-pixel") {
          await page.getByText("Stream chunk 3:", { exact: false }).first().waitFor();
          await paint(page);
        }
        const before = await scroller.evaluate((node) => node.scrollTop);
        await page.mouse.wheel(0, scenario === "tail-one-pixel" ? -1 : -250);
        await paint(page);
        const parked = await scroller.evaluate((node) => node.scrollTop);
        const parkedAt = await page.evaluate(() => performance.now());
        const beforeImage = await page.screenshot({ path: `${output}/${scenario}-before.png` });
        const started = performance.now();
        let folded = false;
        let unfolded = false;
        let resized = false;
        let remeasuredHeight = 0;
        const foldDrifts: number[] = [];
        const clickFold = async () => {
          const toggle = page.locator(".cv-tools > .cv-tool.is-toggle").first();
          const rect = await toggle.boundingBox();
          const bounds = await scroller.boundingBox();
          if (!rect || !bounds || rect.y < bounds.y || rect.y + rect.height > bounds.y + bounds.height) return false;
          await page.mouse.click(rect.x + rect.width / 2, rect.y + rect.height / 2);
          await paint(page, 15);
          const after = await toggle.boundingBox();
          foldDrifts.push(after ? Math.abs(after.y - rect.y) : Infinity);
          return true;
        };
        while (performance.now() - started < 10_000) {
          if (scenario === "remeasure" && !resized && chunks >= 20) {
            remeasuredHeight = await page.evaluate(async () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const top = scroller.getBoundingClientRect().top;
              const above = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
                .filter((row) => row.getBoundingClientRect().bottom < top)
                .at(-1);
              if (!above) throw new Error("Fixture has no mounted row above the visible anchor");
              const height = above.getBoundingClientRect().height;
              // A delayed content measurement above the reader, such as an image acquiring height.
              above.style.minHeight = `${height + 120}px`;
              await window.cmuxPaintFrame();
              await window.cmuxPaintFrame();
              return above.getBoundingClientRect().height - height;
            });
            resized = true;
          }
          if (scenario === "tool-fold" && chunks >= 20 && !folded) {
            folded = await clickFold();
          }
          if (scenario === "tool-fold" && chunks >= 40 && folded && !unfolded) {
            unfolded = await clickFold();
          }
          // fixed-wait: the daemon token cadence is the input under test, not a readiness wait.
          await Bun.sleep(50);
        }
        await stream;
        streaming = false;
        await paint(page, 5);
        const data = await page.evaluate(() => {
          const data = (window as unknown as Probe).lockout;
          data.stop();
          return {
            frames: data.frames,
            writes: data.writes,
            anchorId: data.anchorId,
            lastUpAt: data.lastUpAt,
            nativeWheelTop: data.nativeWheelTop,
          };
        });
        expect(data.lastUpAt).toBeDefined();
        const cutoff = data.lastUpAt!;
        const frames = data.frames.filter((frame) => frame.at >= cutoff);
        const writes = data.writes.filter((write) => write.at >= cutoff);
        const rises = frames.slice(1).filter((frame, i) => frame.top > frames[i]!.top + 0.5);
        const times = frames
          .slice(1)
          .map((frame, i) => frame.at - frames[i]!.at)
          .sort((a, b) => a - b);
        const restingFrames = frames.filter((frame) => frame.at >= parkedAt);
        const anchors = restingFrames.flatMap((frame) => (frame.anchor === null ? [] : [frame.anchor]));
        const metrics = {
          scenario,
          turns: 3000,
          chunks,
          before,
          parked,
          nativeWheelTop: data.nativeWheelTop,
          minTop: Math.min(...frames.map((frame) => frame.top)),
          earlyWrites: data.writes.filter((write) => write.at >= cutoff && write.at <= cutoff + 250),
          frames: frames.length,
          writes: writes.length,
          downwardWrites: writes.filter((w) => w.to > w.from + 0.5).length,
          unintendedDrift: Math.max(0, ...restingFrames.map((f) => f.top - parked)),
          rises: rises.length,
          emptyGap: Math.max(0, ...frames.map((f) => f.gap)),
          anchorDrift: anchors.length ? Math.max(...anchors) - Math.min(...anchors) : null,
          frameP95: times[Math.floor(times.length * 0.95)],
          frameMax: times.at(-1),
          folded,
          unfolded,
          resized,
          remeasuredHeight,
          foldDrifts,
        };
        console.log("SCROLL_LOCKOUT", JSON.stringify(metrics));
        console.log("SCROLL_LOCKOUT_TRACE", JSON.stringify({ scenario, cutoff, parkedAt, ...data }));
        writeFileSync(`${output}/${scenario}.json`, JSON.stringify({ metrics, ...data }, null, 2));
        const afterImage = await page.screenshot({ path: `${output}/${scenario}-after.png` });
        console.log("SCROLL_LOCKOUT_PNG", `${scenario}-before.png`, beforeImage.toString("base64"));
        console.log("SCROLL_LOCKOUT_PNG", `${scenario}-after.png`, afterImage.toString("base64"));
        expect(parked).toBeLessThan(data.nativeWheelTop! - 0.5);
        expect(frames.length).toBeGreaterThan(20);
        if (scenario === "tail-one-pixel") {
          expect(metrics.unintendedDrift).toBeLessThanOrEqual(1);
          expect(metrics.downwardWrites).toBe(0);
          expect(metrics.rises).toBe(0);
        } else if (scenario === "remeasure") {
          expect(resized).toBe(true);
          expect(remeasuredHeight).toBeGreaterThanOrEqual(119);
          expect(metrics.anchorDrift).not.toBeNull();
          expect(metrics.anchorDrift!).toBeLessThanOrEqual(2);
        } else {
          expect(folded).toBe(true);
          expect(unfolded).toBe(true);
          expect(Math.max(...foldDrifts)).toBeLessThanOrEqual(2);
        }
      } finally {
        streaming = false;
        await stream;
        await page.close();
        await pane.close();
      }
    });
  }
});
