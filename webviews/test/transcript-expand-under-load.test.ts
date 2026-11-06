// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a tool group at the very bottom of a running turn while the agent goes on (Leo,
// 2026-11-06, on a recording under heavy load: "the entire tool call expansion apparatus is borked",
// "way too discontinuous"). In his recording a row opened while the list reflowed under it, rows
// regrouped mid-motion, the jump arrow came up and the view jumped. Here a third command joins the
// opened group on the fold's third frame, with and without a 6x CPU throttle. On every painted frame:
// the view stays at its end, the jump arrow stays down, no row is drawn over the next, the opened
// row only grows and its line only rises. Under load the fold still ends in bounded time.
//
// Real Chromium from Playwright on the agent pane's gallery scene (ExpandAtBottom.gallery.ts,
// variant "under-load").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-expand-under-load.test.ts", async () => {
  const ENTRY = "agent-pane.expand-at-bottom";
  const VARIANT = "under-load";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("transcript-expand-under-load: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ROW = '[data-row-id="expand-at-bottom-run"]';
  const GROUP = `${ROW} button.cv-tool.is-toggle[aria-expanded]`;

  /// Every finite animation over, then the scroller's offset and height the same over 16 painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 16; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.locator(GROUP).waitFor();
    await page.waitForFunction(() => typeof window.cmuxGalleryArrive === "function", undefined, {
      timeout: 60_000,
    });
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    return page;
  }

  type Frame = {
    at: number;
    line: number;
    height: number;
    fromEnd: number;
    jump: boolean;
    overlap: number;
    open: string | null;
  };

  /// Clicks the group's line and reads every painted frame for `ms`; `cmuxGalleryArrive` runs in the
  /// callbacks of the fold's third frame, so the next snapshot lands mid-fold.
  const watchOpen = async (page: Page, ms = 900) => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      line.dataset.underLoadProbe = "";
      const box = line.getBoundingClientRect();
      const x = box.left + Math.min(40, box.width / 2);
      const y = box.top + box.height / 2;
      return { x, y, own: line.contains(document.elementFromPoint(x, y)) };
    }, GROUP);
    expect(point.own).toBe(true);
    const watching = page.evaluate(
      ({ duration, row }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          let start = 0;
          let clicked = 0;
          addEventListener("pointerdown", () => (start = performance.now()), {
            capture: true,
            once: true,
          });
          /// A row's drawn foot: its box, less what a clip cuts off its bottom.
          const foot = (node: HTMLElement) => {
            const cut = /inset\(\S+ \S+ ([\d.]+)px/.exec(getComputedStyle(node).clipPath);
            return node.getBoundingClientRect().bottom - (cut ? Number(cut[1]) : 0);
          };
          window.cmuxAfterPaint(
            () => {
              if (!start) return;
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const line = document.querySelector<HTMLElement>("[data-under-load-probe]")!;
              const opened = document.querySelector<HTMLElement>(row)!;
              const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
                .filter((each) => each.getBoundingClientRect().height > 0)
                .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
              let overlap = 0;
              for (let index = 1; index < rows.length; index++)
                overlap = Math.max(overlap, foot(rows[index - 1]!) - rows[index]!.getBoundingClientRect().top);
              const jump = document.querySelector<HTMLElement>(".acpmux-jump-latest");
              frames.push({
                at: performance.now() - start,
                line: line.getBoundingClientRect().top,
                height: foot(opened) - opened.getBoundingClientRect().top,
                fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
                jump: jump?.hasAttribute("data-shown") === true,
                overlap,
                open: line.getAttribute("aria-expanded"),
              });
              if (performance.now() - start < duration) return;
              resolve(frames);
              return false;
            },
            () => {
              if (!start) return;
              clicked += 1;
              if (clicked === 3) window.cmuxGalleryArrive!();
            },
          );
        }),
      { duration: ms, row: ROW },
    );
    await page.mouse.click(point.x, point.y);
    return watching;
  };

  for (const load of ["light", "stress"] as const)
    test(`at the very bottom (${load}), a group opened while a command joins it is one motion`, async () => {
      const page = await open();
      const cdp = await page.context().newCDPSession(page);
      if (load === "stress") await cdp.send("Emulation.setCPUThrottlingRate", { rate: 6 });
      const before = await page.evaluate(
        ({ selector, row }) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const opened = document.querySelector<HTMLElement>(row)!;
          return {
            line: document.querySelector<HTMLElement>(selector)!.getBoundingClientRect().top,
            height: opened.getBoundingClientRect().height,
            fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
          };
        },
        { selector: GROUP, row: ROW },
      );
      expect(before.fromEnd).toBeLessThanOrEqual(2);
      const frames = await watchOpen(page, load === "stress" ? 1500 : 900);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
      await settled(page);
      expect(frames.length).toBeGreaterThan(3);
      let height = before.height;
      let line = before.line;
      for (const [index, frame] of frames.entries()) {
        const at = { load, index, ...frame };
        expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
        expect({ at, jump: frame.jump }).toEqual({ at, jump: false });
        expect({ at, overlap: frame.overlap <= 1 }).toEqual({ at, overlap: true });
        expect({ at, grows: frame.height >= height - 0.5 }).toEqual({ at, grows: true });
        expect({ at, rises: frame.line <= line + 0.5 }).toEqual({ at, rises: true });
        height = frame.height;
        line = frame.line;
      }
      const after = await page.evaluate(
        (row) => ({
          commands: document.querySelectorAll(`${row} .cv-fold button.cv-tool`).length,
          label: document.querySelector<HTMLElement>(`${row} button.cv-tool.is-toggle`)?.textContent ?? "",
        }),
        ROW,
      );
      expect(after.label).toMatch(/3/);
      expect(after.commands).toBeGreaterThanOrEqual(3);
      // Bounded: the opened row stops growing within the fold's time and a few frames, under load too.
      const last = frames.at(-1)!;
      const lastChange = frames.findLast(
        (frame, index) => index > 0 && Math.abs(frame.height - frames[index - 1]!.height) > 0.5,
      );
      expect({ load, settledAt: (lastChange ?? last).at <= 700 }).toEqual({
        load,
        settledAt: true,
      });
      await page.close();
    });
});
