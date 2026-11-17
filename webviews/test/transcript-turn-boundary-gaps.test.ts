// l10n-allow-file: test of gallery fixtures.
// No blank band between turns, and each received message is named once (Leo, 2026-11-17, on ~90px of
// nothing under a reply's footer, then "Received 2 messages" over "Working for 15s" and a second
// "Received 2 messages" under it: "1 me 2 austin we sometimes have weird ui like this" / "in the
// periods here").
//
// Gallery entry agent-pane.turn-boundary-gaps (conversation/TurnBoundaryGaps.gallery.ts) draws the chat
// Leo came back to. In real Chromium, for every variant:
// - a row that takes height draws something: some text, svg or image in it has a box and is not
//   faded out (opacity 0) or hidden;
// - the footer's glyph centre sits footer-to-received (transcriptSpacing.ts LONE_SYSTEM_ROWS) over a
//   "Received" line drawn right under it, and with a read "New since you looked" line between them,
//   as far as with no line at all (a read line takes no space);
// - the received messages are named once: the "Received N messages" lines' counts and the message
//   lines drawn on their own add up to the messages there are.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import {
  BOUNDARY_MESSAGES,
  BOUNDARY_VARIANTS,
} from "../src/agent-session/acpmux/conversation/TurnBoundaryGaps.gallery";
import { LONE_SYSTEM_ROWS } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-turn-boundary-gaps.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.turn-boundary-gaps";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("turn boundary gaps", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, {
      browser,
      params: { variant: BOUNDARY_VARIANTS[0] },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = async (variant: string) => {
    const page = await browser.newPage({
      viewport: { width: 1000, height: 900 },
      deviceScaleFactor: 2,
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900, theme: "Catppuccin Mocha", reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    // Let any fade settle (reduced motion makes them instant, but a frame must paint).
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const result = await page.evaluate((bodies) => {
      const shown = (element: Element): boolean => {
        for (let at: Element | null = element; at; at = at.parentElement) {
          const style = getComputedStyle(at);
          if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
        }
        return true;
      };
      /** The boxes of what a row draws: its text lines and its svg or images, when not faded out. */
      const drawn = (scope: Element): DOMRect[] => {
        const boxes: DOMRect[] = [];
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const box of range.getClientRects()) if (box.width > 0 && box.height > 0) boxes.push(box);
        }
        for (const media of scope.querySelectorAll("svg, img")) {
          const box = media.getBoundingClientRect();
          if (box.width > 0 && box.height > 0 && shown(media)) boxes.push(box);
        }
        return boxes.sort((a, b) => a.top - b.top);
      };
      const rows = [...document.querySelectorAll<HTMLElement>("article.acpmux-row")].map((element) => {
        const box = element.getBoundingClientRect();
        const boxes = drawn(element);
        return {
          id: element.dataset.rowId ?? element.className,
          top: box.top,
          height: box.height,
          contentTop: boxes[0]?.top ?? null,
          contentBottom: boxes.length ? Math.max(...boxes.map((b) => b.bottom)) : null,
          firstCentre: boxes[0] ? (boxes[0].top + boxes[0].bottom) / 2 : null,
          text: (element.innerText ?? "").replace(/\s+/g, " ").trim(),
        };
      });
      const footer = document
        .querySelector<SVGElement>("[data-row-id='gap-footer'] .cv-turn-actions button svg")
        ?.getBoundingClientRect();
      const glyph = footer && footer.height > 0 ? (footer.top + footer.bottom) / 2 : null;
      const lines = [...document.querySelectorAll<HTMLElement>("article.acpmux-row")].map((element) =>
        (element.innerText ?? "").replace(/\s+/g, " ").trim(),
      );
      // A "Received N messages" or "Received a message" line counts N; a line drawing a body counts 1.
      let named = 0;
      const naming: string[] = [];
      for (const text of lines) {
        const count = /Received (\d+) messages/.exec(text)?.[1] ?? (/Received a message/.test(text) ? "1" : null);
        if (count) {
          named += Number(count);
          naming.push(text);
          continue;
        }
        for (const body of bodies)
          if (text.includes(body.slice(0, 30))) {
            named += 1;
            naming.push(text);
          }
      }
      return { rows, glyph, named, naming };
    }, BOUNDARY_MESSAGES);
    await page.close();
    return result;
  };

  type Measured = Awaited<ReturnType<typeof measure>>;
  /// The footer's glyph centre to the centre of the first thing drawn under it, and that row's id.
  const footerGap = (rows: Measured["rows"], glyph: number | null, table: string) => {
    expect(glyph, `no footer glyph; rows:\n${table}`).not.toBeNull();
    const footerAt = rows.findIndex((row) => row.id === "gap-footer");
    const next = rows.slice(footerAt + 1).find((row) => row.firstCentre !== null);
    expect(next, `nothing drawn under the footer; rows:\n${table}`).toBeDefined();
    return { gap: next!.firstCentre! - glyph!, next: next!.id };
  };

  for (const variant of BOUNDARY_VARIANTS)
    test(variant, async () => {
      const { rows, glyph, named, naming } = await measure(variant);
      const table = rows
        .map(
          (row) =>
            `${row.top.toFixed(1)} h=${row.height.toFixed(1)} content=${row.contentTop?.toFixed(1) ?? "none"} ${row.id} ${row.text.slice(0, 50)}`,
        )
        .join("\n");
      // A row that takes height draws something.
      const empty = rows.filter((row) => row.height > 0.5 && row.contentTop === null);
      expect(
        empty.map((row) => `${row.id} h=${row.height.toFixed(1)}`),
        `rows:\n${table}`,
      ).toEqual([]);
      // The footer sits its spacing over the first thing drawn under it; an unread divider there is
      // drawn and keeps its own place.
      if (variant === "inbox-unread") {
        expect(named, `rows:\n${table}`).toBe(BOUNDARY_MESSAGES.length);
        return;
      }
      const { gap, next } = footerGap(rows, glyph, table);
      if (variant.endsWith("-read")) {
        // A read line takes no space: the footer sits as far over the next turn as with no line.
        const without = await measure(variant.slice(0, -"-read".length));
        const expected = footerGap(without.rows, without.glyph, table).gap;
        expect(
          Math.abs(gap - expected),
          `footer glyph to ${next}: ${gap.toFixed(1)}px, ${expected.toFixed(1)}px with no line; rows:\n${table}`,
        ).toBeLessThanOrEqual(LONE_SYSTEM_ROWS.tolerance);
      } else if (/^Received/.test(rows.find((row) => row.id === next)?.text ?? "")) {
        expect(
          Math.abs(gap - LONE_SYSTEM_ROWS.footerToReceived),
          `footer glyph to ${next}: ${gap.toFixed(1)}px, spec ${LONE_SYSTEM_ROWS.footerToReceived}; rows:\n${table}`,
        ).toBeLessThanOrEqual(LONE_SYSTEM_ROWS.tolerance);
      }
      // Each received message is named once.
      expect(named, `rows naming the messages:\n${naming.join("\n")}\nrows:\n${table}`).toBe(BOUNDARY_MESSAGES.length);
    });

  // With motion on, marking the line read shrinks its row through the motion step: its height passes
  // through values between 28 and 0 over several frames, never 28 then 0 in one frame.
  test("a read line shrinks through the motion step with motion on", async () => {
    const page = await browser.newPage({
      viewport: { width: 1000, height: 900 },
      deviceScaleFactor: 2,
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "inbox-unread", width: 900, theme: "Catppuccin Mocha", reducedMotion: "false" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.locator(".cv-since__line").click({ button: "right" });
    const item = page.getByRole("menuitem", { name: /mark/i }).first();
    await item.waitFor();
    // Sample every frame from the click on until the row has settled.
    const sampling = page.evaluate(
      () =>
        new Promise<{ height: number; next: number }[]>((resolve) => {
          const samples: { height: number; next: number }[] = [];
          const start = performance.now();
          const frame = () => {
            const row = document.querySelector<HTMLElement>("[data-row-id='sinceDivider']");
            const next = row?.nextElementSibling?.getBoundingClientRect().top ?? NaN;
            samples.push({
              height: row?.getBoundingClientRect().height ?? 0,
              next,
            });
            if (performance.now() - start < 1200) requestAnimationFrame(frame);
            else resolve(samples);
          };
          requestAnimationFrame(frame);
        }),
    );
    await item.click();
    const samples = await sampling;
    await page.close();
    const heights = samples.map((sample) => Math.round(sample.height * 10) / 10);
    const tops = samples.map((sample) => Math.round(sample.next * 10) / 10);
    const trace = `heights per frame: ${heights.join(" ")}\nnext row's top per frame: ${tops.join(" ")}`;
    console.log(trace);
    expect(heights[0], trace).toBeGreaterThan(20);
    expect(heights.at(-1), trace).toBe(0);
    // Frames in the middle of the shrink: the row did not go from its height to 0 in one step.
    expect(heights.filter((height) => height > 2 && height < heights[0]! - 2).length, trace).toBeGreaterThanOrEqual(3);
    // Tied to the shrink's own rate: no frame moves the next row by more than twice what the line
    // shrank (its gaps close with it, about 24 px over its 28) plus 1 px. The rows are placed from
    // the height measured on the frame before, so a frame's move is held to that frame's shrink or
    // the one before it, whichever is larger.
    const shrink = heights.map((height, at) => (at === 0 ? 0 : Math.max(0, heights[at - 1]! - height)));
    const travel = tops[0]! - tops.at(-1)!;
    for (let at = 1; at < tops.length; at += 1) {
      const step = Math.abs(tops[at]! - tops[at - 1]!);
      expect(step, `frame ${at}\n${trace}`).toBeLessThanOrEqual(2 * Math.max(shrink[at]!, shrink[at - 1]!) + 1);
      // And no single frame pops a large part of the move (the gaps once dropped at 0: 24 px of 52).
      expect(step, `frame ${at}\n${trace}`).toBeLessThanOrEqual(0.25 * travel);
    }
    // It did move up by the line and its gaps (to the gap the footer has with no line at all).
    expect(travel, trace).toBeGreaterThan(20);
  });
});
