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
//   "Received" line drawn right under it;
// - a "New since you looked" line, unread or read, moves no row: every row sits at the top it has
//   with no line at all (Leo, 2026-11-22: "probably also not layout shift this"). The old line was a
//   28 px row whose gaps came with it, 52 px of shift each time it came and went; now 0;
// - over nothing new to read (a subagent's "started working" line) no line is drawn;
// - the received messages are named once: the "Received N messages" lines' counts and the message
//   lines drawn on their own add up to the messages there are.
// The `woken-*` variants hold the client's typing placeholder under the footer, where the live reducer
// left it when acpmux said a turn runs before its record landed (Leo, 2026-11-22, ~40px of nothing over
// "Received 2 messages": "sometimes you get these way-too-big gaps"): it draws no row, and the footer
// sits its spacing over the notice as in the other variants.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import {
  BOUNDARY_MESSAGES,
  BOUNDARY_VARIANTS,
  boundaryNamed,
} from "../src/agent-session/acpmux/conversation/TurnBoundaryGaps.gallery";
import { LONE_SYSTEM_ROWS } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
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
      const line = document.querySelector<HTMLElement>(".cv-since__line");
      const lineOpacity = line ? Number(getComputedStyle(line).opacity) : null;
      return { rows, glyph, named, naming, lineOpacity };
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
      const { rows, glyph, named, naming, lineOpacity } = await measure(variant);
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
      // A line, read or not, moves no row: each sits where it sits with no line (the "before" was
      // 52 px, a 28 px row and its gaps).
      const plain = variant.replace(/-(?:read|unread)$/, "");
      if (plain !== variant) {
        const without = await measure(plain);
        const tops = new Map(without.rows.map((row) => [row.id, row.top]));
        const shifts = rows
          .filter((row) => tops.has(row.id))
          .map((row) => ({ id: row.id, shift: row.top - tops.get(row.id)! }));
        const worst = Math.max(0, ...shifts.map(({ shift }) => Math.abs(shift)));
        console.log(`${variant}: the line moves rows by at most ${worst.toFixed(2)} px`);
        expect(shifts.length, `rows:\n${table}`).toBeGreaterThan(3);
        expect(worst, `shifts ${JSON.stringify(shifts)}\nrows:\n${table}`).toBeLessThanOrEqual(0.5);
      }
      if (variant.startsWith("status")) {
        // Nothing new to read under it: no line drawn (Leo's 2026-11-22 screenshot).
        expect(lineOpacity ?? 0, `rows:\n${table}`).toBe(0);
        return;
      }
      if (variant === "inbox-unread") {
        expect(named, `rows:\n${table}`).toBe(BOUNDARY_MESSAGES.length);
        return;
      }
      const { gap, next } = footerGap(rows, glyph, table);
      if ((rows.find((row) => row.id === next)?.text ?? "").startsWith("Received")) {
        expect(
          Math.abs(gap - LONE_SYSTEM_ROWS.footerToReceived),
          `footer glyph to ${next}: ${gap.toFixed(1)}px, spec ${LONE_SYSTEM_ROWS.footerToReceived}; rows:\n${table}`,
        ).toBeLessThanOrEqual(LONE_SYSTEM_ROWS.tolerance);
      }
      // Each received message is named once.
      expect(named, `rows naming the messages:\n${naming.join("\n")}\nrows:\n${table}`).toBe(boundaryNamed(variant));
    });

  // With motion on, the unread line holds while the window is not focused, then dissipates once
  // focus comes back and it has been on screen a moment (SinceDivider.tsx SINCE_DWELL_MS): its
  // opacity passes through values between 1 and 0 over several frames, and no row moves on any
  // frame from the line's first paint to after it is gone.
  test("the unread line holds unfocused, then fades with focus and moves no row on any frame", async () => {
    const page = await browser.newPage({
      viewport: { width: 1000, height: 900 },
      deviceScaleFactor: 2,
    });
    // The window starts unfocused: hasFocus answers false until the test focuses it.
    await page.addInitScript(() => {
      let focused = false;
      Document.prototype.hasFocus = () => focused;
      (window as unknown as { cmuxTestFocus: () => void }).cmuxTestFocus = () => {
        focused = true;
        window.dispatchEvent(new Event("focus"));
      };
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "inbox-unread", width: 900, theme: "Catppuccin Mocha", reducedMotion: "false" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await installPaintedFrames(page);
    // The row is 0 px tall (it takes no height), so wait for it attached, not "visible".
    await page.waitForSelector(".cv-since[data-shown]", { state: "attached", timeout: 10_000 });
    // Sample every painted frame: the line's opacity and every row's top.
    type Sample = { opacity: number; tops: Record<string, number>; focused: boolean; at: number };
    const sampling = page.evaluate(
      () =>
        new Promise<Sample[]>((resolve) => {
          const samples: Sample[] = [];
          const start = performance.now();
          let focusedAt = 0;
          window.cmuxAfterPaint(() => {
            const line = document.querySelector<HTMLElement>(".cv-since__line");
            const tops: Record<string, number> = {};
            for (const row of document.querySelectorAll<HTMLElement>("article.acpmux-row"))
              if (row.dataset.rowId) tops[row.dataset.rowId] = row.getBoundingClientRect().top;
            const now = performance.now();
            samples.push({
              opacity: line ? Number(getComputedStyle(line).opacity) : 0,
              tops,
              focused: focusedAt > 0,
              at: now - start,
            });
            // Unfocused past the dwell: the line must hold. Then focus.
            if (!focusedAt && now - start > 4_000) {
              focusedAt = now;
              (window as unknown as { cmuxTestFocus: () => void }).cmuxTestFocus();
            }
            if (!focusedAt || now - focusedAt < 4_500) return true;
            resolve(samples);
            return false;
          });
        }),
    );
    const samples = await sampling;
    await page.close();
    const opacities = samples.map((sample) => Math.round(sample.opacity * 100) / 100);
    const ids = Object.keys(samples[0]!.tops).filter((id) => id !== "sinceDivider");
    let worst = 0;
    for (const sample of samples)
      for (const id of ids)
        if (sample.tops[id] !== undefined) worst = Math.max(worst, Math.abs(sample.tops[id]! - samples[0]!.tops[id]!));
    const trace = `opacity per frame: ${opacities.join(" ")}\nrows' worst move over ${samples.length} frames: ${worst.toFixed(2)} px`;
    console.log(trace);
    expect(ids.length, trace).toBeGreaterThan(3);
    // It held while unfocused for longer than the dwell (past its own fade-in), then went.
    const held = samples.filter((sample) => !sample.focused && sample.at > 500);
    expect(held.length, trace).toBeGreaterThan(10);
    expect(
      held.every((sample) => sample.opacity === 1),
      trace,
    ).toBe(true);
    expect(opacities.at(-1), trace).toBe(0);
    // Faded over frames, never 1 then 0 in one.
    expect(opacities.filter((opacity) => opacity > 0.05 && opacity < 0.95).length, trace).toBeGreaterThanOrEqual(3);
    // And no row moved on any frame.
    expect(worst, trace).toBeLessThanOrEqual(0.5);
  });
});
