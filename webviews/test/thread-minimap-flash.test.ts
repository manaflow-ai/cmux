// l10n-allow-file: fixture prompts and replies, not shipped UI.
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-flash.test.ts
// No CSS-presence oracle: assert captured text survives stationary hover/card changes. Moving
// scenarios report strip-loss candidates for inspection because scrolling also moves text.
// CMUX_FLASH_EVIDENCE saves sampled PNGs and counts; a pass does not prove the macOS bug fixed.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { transcriptPixels } from "./support/transcriptPixels";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-flash.test.ts", async () => {
  // Conditions hold across consecutive painted frames. A missed interaction fails at its deadline
  // instead of ending observation before the card or scroll arrives. Every exit cancels the reader.
  async function completed(page: Page, goal: "settled" | "closed" | "bottom" | "landing", id = "", timeout = 5_000) {
    await page.evaluate(
      ({ goal, id, timeout }) =>
        new Promise<void>((resolve, reject) => {
          let stop = () => {};
          const finish = (error?: Error) => {
            clearTimeout(timer);
            stop();
            if (error) reject(error);
            else resolve();
          };
          const timer = setTimeout(() => finish(new Error(`interaction did not complete: ${goal} ${id}`)), timeout);
          let previous = "",
            stable = 0;
          stop = window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const box = scroller.getBoundingClientRect();
            const bubble = document.querySelector<HTMLElement>(`[data-row-id="${id}"] .cv-user__bubble`);
            const animations = document
              .getAnimations()
              .some((a) => a.playState === "running" && a.effect?.getComputedTiming().endTime !== Infinity);
            const gap = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
            const ready =
              !animations &&
              (goal === "closed"
                ? !document.querySelector(".acpmux-minimap__card, .acpmux-minimap__rail[data-hovering]")
                : goal === "bottom"
                  ? gap <= 2
                  : goal === "landing"
                    ? !!bubble && Math.abs(bubble.getBoundingClientRect().top - box.top - 35) <= 1
                    : true);
            const current = `${scroller.scrollTop}:${scroller.scrollHeight}`;
            stable = ready && current === previous ? stable + 1 : 0;
            previous = current;
            if (stable >= 3) finish();
          });
        }),
      { goal, id, timeout },
    );
  }

  async function observeRows(page: Page, stationary: boolean) {
    await page.evaluate((stationary) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const expected = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter((node) => {
          const box = node.getBoundingClientRect();
          return box.height > 0 && box.bottom > view.top && box.top < view.bottom;
        })
        .map((node) => node.dataset.rowId!);
      // Moving windows lack an independent expected-ID set; don't report DOM completeness as zero.
      const stats = {
        adds: 0,
        removes: 0,
        missingFrames: stationary ? 0 : null,
        emptyViewportFrames: 0,
        fadingFrames: 0,
        domFrames: 0,
      };
      const count = (nodes: NodeList) =>
        [...nodes].reduce(
          (total, node) =>
            total +
            (node instanceof HTMLElement
              ? Number(node.matches("[data-row-id]")) + node.querySelectorAll("[data-row-id]").length
              : 0),
          0,
        );
      const consume = (records: MutationRecord[]) =>
        records.forEach((r) => {
          stats.adds += count(r.addedNodes);
          stats.removes += count(r.removedNodes);
        });
      const observer = new MutationObserver(consume);
      observer.observe(scroller, { childList: true, subtree: true });
      const stop = window.cmuxAfterPaint(() => {
        stats.domFrames++;
        const current = scroller.getBoundingClientRect();
        const nodes = stationary
          ? expected.map((id) => scroller.querySelector<HTMLElement>(`[data-row-id="${id}"]`))
          : [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter((node) => {
              const box = node.getBoundingClientRect();
              return box.bottom > current.top && box.top < current.bottom;
            });
        if (!nodes.length) stats.emptyViewportFrames++;
        if (
          stats.missingFrames !== null &&
          (!nodes.length ||
            nodes.some((node) => {
              const box = node?.getBoundingClientRect();
              return (
                !node ||
                !box ||
                box.width <= 0 ||
                box.height <= 0 ||
                box.bottom <= current.top ||
                box.top >= current.bottom
              );
            }))
        )
          stats.missingFrames++;
        if (nodes.some((node) => node && getComputedStyle(node).opacity !== "1")) stats.fadingFrames++;
      });
      window.__flashStop = () => {
        stop();
        consume(observer.takeRecords());
        observer.disconnect();
        delete window.__flashStop;
        return stats;
      };
    }, stationary);
  }

  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let chat: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
    chat = await papercutPane(() => browser, { turns: 30, running: false });
  });
  afterAll(async () => {
    await browser?.close();
    await chat?.close();
    await vite?.close();
  });
  const paragraph = "The streamed answer keeps enough spacing to exercise the transcript layout.";
  const rows = Array.from({ length: 30 }, (_, i) => [
    {
      id: `t${i}-user`,
      kind: "user",
      text: `Prompt ${i + 1}: inspect the thread rail redraw.`,
      at: 1,
      version: 1,
    },
    {
      id: `t${i}-answer`,
      kind: "assistant",
      text: `${paragraph}\n\n${paragraph}`,
      at: 1,
      version: 1,
    },
    {
      id: `t${i}-end`,
      kind: "turnSummary",
      status: "completed",
      durationMs: 1_000,
      at: 1,
      version: 1,
    },
  ]).flat();
  async function open() {
    const { port } = vite.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
      await page.waitForFunction(() => "__showRows" in window);
      await page.evaluate((rows) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(rows), rows);
      await page.locator(".acpmux-minimap__rail").waitFor();
      await completed(page, "settled");
      await page.evaluate(() => {
        document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 700;
      });
      await completed(page, "settled");
      return page;
    } catch (error) {
      await page.close();
      throw error;
    }
  }
  async function measure(
    page: Page,
    name: string,
    stationary: boolean,
    action: (mark: (phase: string) => void) => Promise<void>,
  ) {
    const pixels = await transcriptPixels(page);
    let output;
    let dom;
    try {
      await observeRows(page, stationary);
      await action(pixels.mark);
      await completed(page, "settled");
    } finally {
      try {
        output = await pixels.stop(name);
      } finally {
        dom = await page.evaluate(() => window.__flashStop?.());
        console.log(name, "DOM", JSON.stringify(dom));
      }
    }
    console.log(name, "pixels", JSON.stringify({ ...output, samples: undefined }));
    expect(output.frames).toBeGreaterThan(2);
    expect(output.blankFrames).toEqual([]);
    expect(output.stableLossFrames).toEqual([]);
    expect(dom?.emptyViewportFrames).toBe(0);
    // Scrolling can empty a strip legitimately; its partial-loss candidates stay in the report.
    if (stationary) {
      expect(output.transientFrames).toEqual([]);
      expect(output.referenceLossFrames).toEqual([]);
      expect(dom).toMatchObject({ adds: 0, removes: 0, missingFrames: 0 });
    }
  }
  const hover = async (page: Page) => {
    const box = await page.locator('[data-tick="2"]').boundingBox();
    if (!box) throw new Error("tick not drawn");
    await page.mouse.move(box.x + 8, box.y + box.height / 2);
    await page.locator(".acpmux-minimap__card").waitFor({ timeout: 5_000 });
  };
  test("captured transcript stays present through rail hover leave and card dismissal", async () => {
    const page = await open();
    try {
      await measure(page, "hover-leave", true, async (mark) => {
        mark("hover");
        await hover(page);
        mark("highlight-clear");
        await page.mouse.move(1100, 20);
        await completed(page, "closed");
      });
      await measure(page, "card-open-close", true, async (mark) => {
        mark("open");
        await hover(page);
        await page.locator(".acpmux-minimap__card").hover();
        mark("close");
        await page.keyboard.press("Escape");
        await page.mouse.move(1100, 20);
        await completed(page, "closed");
      });
    } finally {
      await page.close();
    }
  });
  test("tick click and next/previous turn land at the requested prompt", async () => {
    const page = await open();
    try {
      await measure(page, "tick-click", false, async (mark) => {
        mark("jump");
        await page.locator('[data-tick="12"]').click();
        await completed(page, "landing", "t12-user");
      });
      for (const [action, id] of [
        ["nextTurn", "t13-user"],
        ["previousTurn", "t12-user"],
      ]) {
        await page.evaluate((action) => window.dispatchEvent(new CustomEvent(`cmux-acpmux-${action}`)), action);
        await completed(page, "landing", id);
      }
    } finally {
      await page.close();
    }
  });
  test("live latest reply grows through daemon chunks while following bottom", async () => {
    const page = await chat.open({ width: 1280, height: 820 });
    try {
      await page.emulateMedia({ colorScheme: "dark" });
      await page.evaluate(() => {
        document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 1e9;
      });
      await completed(page, "bottom");
      const start = await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop);
      await measure(page, "live-stream", false, async (mark) => {
        mark("stream");
        chat.record("user_message", {
          text: "Stream the latest reply",
          promptId: "flash-live",
          turnId: "flash-live",
        });
        chat.record("turn_started", {});
        for (let index = 1; index <= 12; index++) {
          chat.record(
            "agent_message_chunk",
            {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: {
                  sessionUpdate: "agent_message_chunk",
                  content: { type: "text", text: `Live paragraph ${index}: ${paragraph}\n\n` },
                },
              },
            },
            "in",
          );
          await page.getByText(`Live paragraph ${index}:`, { exact: false }).waitFor();
          await completed(page, "bottom");
        }
        chat.record("turn_result", { status: "completed" });
        await completed(page, "bottom");
      });
      expect((await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop)) - start).toBeGreaterThan(300);
    } finally {
      await page.close();
    }
  });

  test("a missed interaction fails its deadline and releases observation", async () => {
    const page = await open();
    try {
      await expect(
        measure(page, "timeout-control", true, () => completed(page, "landing", "absent", 50)),
      ).rejects.toThrow("interaction did not complete");
      expect(await page.evaluate(() => window.__flashStop === undefined)).toBe(true);
      await completed(page, "settled");
    } finally {
      await page.close();
    }
  });

  test("pixel oracle detects a paint-only blank with unchanged DOM geometry", async () => {
    const page = await open();
    const pixels = await transcriptPixels(page);
    try {
      const before = await page.locator(".acpmux-row").first().boundingBox();
      const partial = await page.addStyleTag({
        content: ".acpmux-row.acpmux-assistant { visibility: hidden !important; }",
      });
      try {
        await pixels.checkpoint("injected-partial");
        expect(await page.locator(".acpmux-row").first().boundingBox()).toEqual(before);
      } finally {
        await partial.evaluate((node) => node.parentNode?.removeChild(node));
      }
      await pixels.checkpoint("restored-partial");
      const style = await page.addStyleTag({
        content: ".acpmux-thread { visibility: hidden !important; }",
      });
      try {
        await page.evaluate(() => window.cmuxPaintFrame());
        await pixels.checkpoint("injected-blank");
        expect(await page.locator(".acpmux-row").first().boundingBox()).toEqual(before);
        expect(
          await page
            .locator(".acpmux-row")
            .first()
            .evaluate((node) => getComputedStyle(node).opacity),
        ).toBe("1");
      } finally {
        await style.evaluate((node) => node.parentNode?.removeChild(node));
      }
      await completed(page, "settled");
    } finally {
      try {
        const result = await pixels.stop("positive-control");
        console.log(
          "positive-control",
          JSON.stringify({
            frames: result.frames,
            blankFrames: result.blankFrames,
            stableLossFrames: result.stableLossFrames,
          }),
        );
        expect(result.blankFrames.length).toBeGreaterThan(0);
        expect(result.stableLossFrames.some((index) => result.samples[index]!.phase === "injected-partial")).toBe(true);
        expect(
          result.samples.find((sample) => sample.phase === "injected-partial" && sample.source === "screenshot")!.ink,
        ).toBeGreaterThan(30);
      } finally {
        await page.close();
      }
    }
  });
});
