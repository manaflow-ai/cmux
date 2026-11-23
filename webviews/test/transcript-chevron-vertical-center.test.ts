// Every transcript disclosure chevron, and every trailing time or status at a row's end, sits on
// its row's first text line: its glyph's middle on the middle of the words it follows
// (cmux#51746: a folded thought's chevron rode a few px above its words, while the tool rows
// around it, the received line above and the skill row below, sat on theirs). One row grammar,
// single-line and cut with an ellipsis: a thought, a tool call, a skill, a message line.
//
// Measured in Chromium over the transcript gallery scenes, at a wide and a narrow pane:
// - every laid-out chevron's glyph middle lies within MAX_OFFSET px of the middle of the first text
//   line of the row it opens;
// - every trailing time or status (a thought's "4s", a call's duration) does the same;
// - a finished subagent's new dot with no time shown beside it ends its line, flush on the row's
//   right edge, on its words' middle, at every transcript spacing.
//
// CMUX_CHEVRON_LOG=1 logs every glyph measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-chevron-vertical-center.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** The farthest a glyph's middle may sit from its line's middle, in CSS px. */
  const MAX_OFFSET = 1;
  const LOG = process.env.CMUX_CHEVRON_LOG === "1";
  /**
   * A scene, opened before it is measured: every closed "Worked for" and run line (`expand`), then
   * with `openThought` the first thought too. `rows` names a row the scene must measure a chevron in,
   * so a scene whose rows stay folded fails instead of passing on the Worked-for line alone.
   */
  const SCENES: { entry: string; variant: string; expand?: boolean; openThought?: boolean; rows?: string }[] = [
    // Thoughts: folded, cut with an ellipsis, short and long, alone, leading a run and between calls.
    { entry: "agent-pane.thought-shapes", variant: "short", expand: true, rows: ".cv-thought" },
    { entry: "agent-pane.thought-shapes", variant: "long", expand: true, rows: ".cv-thought" },
    { entry: "agent-pane.thought-shapes", variant: "lead-run", expand: true, rows: ".cv-thought" },
    { entry: "agent-pane.thought-shapes", variant: "between-calls", expand: true, rows: ".cv-thought" },
    { entry: "agent-pane.thought-shapes", variant: "wrapping-line", expand: true, rows: ".cv-thought" },
    // A thought opened: its first line wraps, and its glyph, chevron and time stay on that line.
    {
      entry: "agent-pane.thought-shapes",
      variant: "long",
      expand: true,
      openThought: true,
      rows: ".cv-thought.is-open",
    },
    // A call opened whose label wraps to the whole pattern (ToolRow.tsx `is-whole-open`).
    { entry: "agent-pane.transcript", variant: "cut-line-open", rows: ".cv-tool.is-whole-open" },
    // Tool calls, runs, system rows and message lines.
    { entry: "agent-pane.transcript-system-rows", variant: "leo-capture" },
    { entry: "agent-pane.received-messages", variant: "collapsed" },
    { entry: "agent-pane.transcript-spacing-table", variant: "shipped" },
    { entry: "agent-pane.message-line-look", variant: "leo-capture" },
    { entry: "agent-pane.claude-desktop-organization", variant: "shared" },
  ];
  const WIDTHS = [760, 420];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript chevron vertical center", () => test("browser", () => {}));
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
    for (const entry of new Set(SCENES.map((scene) => scene.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: SCENES.find((scene) => scene.entry === entry)!.variant },
      });
    await warmGalleryFrame(vite, "agent-pane.subagent-done", { browser, params: { variant: "reply" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Glyph = {
    kind: "chevron" | "trail";
    row: string;
    /** Whether it sits in a row the scene names (`rows`). */
    named: boolean;
    /** The glyph's middle less its line's middle, in CSS px; null when no words share its row. */
    offset: number | null;
  };
  /** A row's trailing time or status at its end. */
  const TRAIL =
    ".cv-thought__time, .cv-tool__trail, .cv-command__meta, .cv-agent-activity__trail, .cv-subagent-done__trail";

  const measure = (page: Page, rows: string): Promise<Glyph[]> =>
    page.evaluate(
      ([TRAIL, rows]) => {
        /** Laid out, whatever its opacity: a chevron that shows only on hover has its place at rest. */
        const laidOut = (element: Element) => {
          const box = element.getBoundingClientRect();
          if (box.width === 0 || box.height === 0) return false;
          for (let node: Element | null = element; node; node = node.parentElement)
            if (getComputedStyle(node).display === "none") return false;
          return true;
        };
        const named = (element: Element) => rows !== "" && element.closest(rows) !== null;
        const shown = (element: Element) => {
          const box = element.getBoundingClientRect();
          if (box.width === 0 || box.height === 0) return false;
          for (let node: Element | null = element; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
          }
          return true;
        };
        /** The text line boxes in `scope` outside `skip`, from the top. */
        const lines = (scope: Element, skip: Element) => {
          const rects: DOMRect[] = [];
          const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const parent = node.parentElement;
            if (!parent || !node.textContent?.trim() || skip.contains(parent) || parent.closest(TRAIL)) continue;
            if (!shown(parent)) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            for (const rect of range.getClientRects()) if (rect.width > 0 && rect.height > 0) rects.push(rect);
          }
          return rects;
        };
        /** The middle of the first line of words in the nearest box around `glyph` that has any. */
        const lineMiddle = (glyph: Element, box: DOMRect) => {
          for (let scope = glyph.parentElement; scope; scope = scope.parentElement) {
            // Words on the glyph's own row: a line's top under the glyph's bottom is a later line.
            const rects = lines(scope, glyph).filter((rect) => rect.top < box.bottom + 4 && rect.bottom > box.top - 4);
            if (rects.length > 0) {
              const top = Math.min(...rects.map((rect) => rect.top));
              const first = rects.filter((rect) => rect.top < top + 6);
              // The words' own font box: a chip's or a mono span's taller box would skew the middle.
              const middles = first.map((rect) => (rect.top + rect.bottom) / 2).sort((a, b) => a - b);
              return {
                middle: middles[Math.floor(middles.length / 2)],
                row: `${scope.className || scope.tagName} | ${(scope.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50)}`,
              };
            }
            if (scope.classList.contains("acpmux-row")) break;
          }
          return null;
        };
        const out: Glyph[] = [];
        for (const chevron of document.querySelectorAll(".acpmux-row .cv-rotor")) {
          if (!laidOut(chevron)) continue;
          // The glyph's own box, not its ink: the chevron is drawn centred in it, and the box keeps its
          // middle when it turns open, where the ink's slight asymmetry would move a rotated middle.
          const glyph = chevron.matches("svg") ? chevron : chevron.querySelector("svg");
          if (!glyph) continue;
          const box = glyph.getBoundingClientRect();
          const line = lineMiddle(chevron, box);
          out.push({
            kind: "chevron",
            named: named(chevron),
            row: line?.row ?? chevron.className.toString(),
            offset: line ? (box.top + box.bottom) / 2 - line.middle : null,
          });
        }
        for (const trail of document.querySelectorAll(`.acpmux-row :is(${TRAIL})`)) {
          if (!laidOut(trail) || !trail.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(trail);
          const box = range.getBoundingClientRect();
          if (box.height === 0) continue;
          const scope = trail.parentElement;
          if (!scope) continue;
          const rects = lines(scope, trail);
          if (rects.length === 0) continue;
          const top = Math.min(...rects.map((rect) => rect.top));
          const middles = rects
            .filter((rect) => rect.top < top + 6)
            .map((rect) => (rect.top + rect.bottom) / 2)
            .sort((a, b) => a - b);
          out.push({
            kind: "trail",
            named: named(trail),
            row: `${scope.className} | ${(scope.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50)}`,
            offset: (box.top + box.bottom) / 2 - middles[Math.floor(middles.length / 2)],
          });
        }
        return out;
      },
      [TRAIL, rows] as const,
    );

  /** Lets every running animation (not an endless one) finish, then two frames paint. */
  const settle = async (page: Page) => {
    await page.waitForFunction(
      () =>
        document
          .getAnimations()
          .every((a) => a.playState !== "running" || a.effect?.getComputedTiming().iterations === Infinity),
      undefined,
      { timeout: 10_000 },
    );
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  };
  /** Clicks open the first closed toggle `selector` matches, until none is left (bounded). */
  const openAll = async (page: Page, selector: string) => {
    for (let round = 0; round < 12; round++) {
      const closed = page.locator(`${selector}[aria-expanded="false"]`);
      if ((await closed.count()) === 0) return;
      await closed.first().click();
      await settle(page);
    }
  };

  const measured = new Map<string, Glyph[]>();
  const of = async (scene: (typeof SCENES)[number], width: number) => {
    const key = `${scene.entry}#${scene.variant}${scene.openThought ? "+open" : ""}@${width}`;
    const known = measured.get(key);
    if (known) return known;
    const page = await browser.newPage({ viewport: { width: width + 40, height: 1100 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(scene.entry, { variant: scene.variant, width, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      await settle(page);
      if (scene.expand) await openAll(page, "button.cv-worked.is-toggle, button.cv-tool.is-run.is-toggle");
      if (scene.openThought) {
        const thought = page.locator('button.cv-thought.is-toggle[aria-expanded="false"]').first();
        await thought.click();
        await settle(page);
      }
      await page.mouse.move(0, 0);
      await settle(page);
      const result = await measure(page, scene.rows ?? "");
      const out = process.env.FAST_CHECKS_OUT;
      if (out)
        await page.screenshot({
          path: path.join(out, `chevron-center-${key.replace(/[^\w.@-]+/g, "_")}.png`),
          fullPage: true,
        });
      if (LOG) console.log(`GLYPHS ${key}\n${result.map((each) => JSON.stringify(each)).join("\n")}`);
      measured.set(key, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const scene of SCENES)
    for (const width of WIDTHS) {
      const name = `${scene.entry}#${scene.variant}${scene.openThought ? " opened" : ""} at ${width}px`;
      test(`${name}: has chevrons to measure${scene.rows ? ` in ${scene.rows}` : ""}`, async () => {
        const chevrons = (await of(scene, width)).filter(({ kind }) => kind === "chevron");
        expect(chevrons.length).toBeGreaterThan(0);
        if (scene.rows) expect(chevrons.filter(({ named }) => named).length).toBeGreaterThan(0);
      });
      test(`${name}: every chevron and trailing time sits on its words' line`, async () => {
        const off = (await of(scene, width)).filter(
          ({ offset }) => offset === null || Math.abs(offset) > MAX_OFFSET + 0.01,
        );
        expect(off).toEqual([]);
      });
    }

  // A finished subagent's new dot (ReactionMark.tsx) with no time beside it at rest: the compact line
  // whose time waits for hover, and a line with no duration at all. The dot ends the line, flush on
  // the row's right edge (where a time or chevron column ends), and sits on its words' line, at each
  // transcript spacing (cmux#51746: it sat 6px in, room kept for a time that was not shown).
  const DOT_SCENES = ["reply", "reply-no-time"];
  const SPACINGS = ["", "tight", "roomy"];
  type Dot = { row: string; inset: number; offset: number | null };
  const dots = async (variant: string, width: number, spacing: string): Promise<Dot[]> => {
    const page = await browser.newPage({ viewport: { width: width + 40, height: 600 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.subagent-done", { variant, width, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate((spacing) => {
        if (spacing) document.documentElement.dataset.transcriptToolSpacing = spacing;
        return document.fonts.ready;
      }, spacing);
      await page.mouse.move(0, 0);
      await settle(page);
      return await page.evaluate(() =>
        [...document.querySelectorAll(".acpmux-row .cv-subagent-done-row .cv-reaction-mark")].map((dot) => {
          const row = dot.closest(".cv-subagent-done-row")!;
          const style = getComputedStyle(row);
          const edge =
            row.getBoundingClientRect().right - parseFloat(style.paddingRight) - parseFloat(style.borderRightWidth);
          const box = dot.getBoundingClientRect();
          const sentence = row.querySelector(".cv-agent-activity__sentence");
          const rects: DOMRect[] = [];
          if (sentence) {
            const walker = document.createTreeWalker(sentence, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              if (!node.textContent?.trim()) continue;
              const range = document.createRange();
              range.selectNodeContents(node);
              for (const rect of range.getClientRects()) if (rect.width > 0 && rect.height > 0) rects.push(rect);
            }
          }
          const middles = rects.map((rect) => (rect.top + rect.bottom) / 2).sort((a, b) => a - b);
          return {
            row: (row.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50),
            inset: edge - box.right,
            offset: middles.length ? (box.top + box.bottom) / 2 - middles[Math.floor(middles.length / 2)] : null,
          };
        }),
      );
    } finally {
      await page.close();
    }
  };
  for (const variant of DOT_SCENES)
    for (const width of WIDTHS)
      for (const spacing of SPACINGS)
        test(`agent-pane.subagent-done#${variant} at ${width}px, ${spacing || "default"} spacing: the new dot ends the line on its words' middle`, async () => {
          const found = await dots(variant, width, spacing);
          if (LOG)
            console.log(`DOTS ${variant}@${width}/${spacing}\n${found.map((dot) => JSON.stringify(dot)).join("\n")}`);
          expect(found.length).toBeGreaterThan(0);
          expect(
            found.filter(
              ({ inset, offset }) => Math.abs(inset) > 0.5 || offset === null || Math.abs(offset) > MAX_OFFSET + 0.01,
            ),
          ).toEqual([]);
        });
});
