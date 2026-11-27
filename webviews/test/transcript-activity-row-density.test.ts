// Every activity row kind of Leo's 2026-11-17 capture (gallery entry agent-pane.activity-row-density;
// Leo: "expanded, then / folded worked // these are too big") draws on the one shared row metric
// (rowMetric.ts ROW_METRIC), measured in Chromium:
//
// - each one-line row (another machine's message, a run of a script and received lines, "Background
//   command completed", a thinking line, "Sent a message", "Received 3 messages") is one row tall,
//   and consecutive rows sit flush, one row apart top to top: no kind is taller, and a received
//   line's "where it was sent from" no longer adds a second line under it;
// - each row's words are the metric's size, its session chip the metric's height, its glyph the
//   metric's size;
// - "Worked for" is one row with the metric's room around its rule.
//
// With FAST_CHECKS_OUT set it also writes each variant's screenshot there (the PR's before and after
// and the density candidates). CMUX_ROW_DENSITY_LOG=1 logs every row.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { ROW_METRIC } from "../src/agent-session/acpmux/rowMetric";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

/** The prose size "Worked for" keeps (chatDisplay.ts DEFAULT_CHAT_DISPLAY.fontSize). */
const PROSE = 14;

await requireBrowserLane("transcript-activity-row-density.test.ts", async () => {
  setDefaultTimeout(300_000);
  const ENTRY = "agent-pane.activity-row-density";
  const MEASURED = ["expanded", "folded", "runs-open"];
  const SHOTS = ["density-roomy", "density-compact", "density-dense"];
  const OUT = process.env.FAST_CHECKS_OUT;
  const LOG = process.env.CMUX_ROW_DENSITY_LOG === "1";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("activity row density", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: MEASURED[0]! } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; top: number; height: number; kind: string; text: string };
  type Measured = {
    rows: Row[];
    /** The words of each one-line row's line: their computed size, by the element's class. */
    words: { cls: string; size: number }[];
    chips: number[];
    glyphs: number[];
    worked: number[];
  };

  /** The row kinds of the capture that are one line while shut. */
  const LINE_KINDS = ["acpmux-row--line", "acpmux-backgroundTask", "acpmux-activity"];

  const measured = new Map<string, Measured>();
  const of = async (variant: string): Promise<Measured> => {
    const known = measured.get(variant);
    if (known) return known;
    const page = await browser.newPage({ viewport: { width: 860, height: 900 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760, theme: "Catppuccin Mocha", reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      const result = await page.evaluate((lineKinds) => {
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
          .filter((row) => row.getBoundingClientRect().height > 0)
          .map((row) => {
            const box = row.getBoundingClientRect();
            return {
              id: row.dataset.rowId ?? "",
              top: box.top,
              height: box.height,
              kind: lineKinds.find((kind) => row.classList.contains(kind)) ?? "",
              text: (row.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60),
            };
          });
        const LABELS = [
          ".cv-agent-tag__label",
          ".cv-received__preview",
          ".cv-tool__summary",
          ".cv-bgtask__state",
          ".cv-message-group__count",
          ".cv-thought__preview",
        ];
        const words = [...LABELS, ".cv-worked__label"].flatMap((selector) =>
          [...document.querySelectorAll<HTMLElement>(`.acpmux-row ${selector}`)]
            .filter((element) => element.getBoundingClientRect().height > 0)
            .map((element) => ({ cls: selector, size: parseFloat(getComputedStyle(element).fontSize) })),
        );
        const heightOf = (selector: string) =>
          [...document.querySelectorAll<Element>(selector)]
            .map((element) => element.getBoundingClientRect().height)
            .filter((height) => height > 0);
        return {
          rows,
          words,
          chips: heightOf(".acpmux-row button.cv-agent-tag.is-open"),
          glyphs: heightOf(".acpmux-row .cv-tool__icon > svg"),
          worked: heightOf(".acpmux-row .cv-worked.is-toggle"),
        };
      }, LINE_KINDS);
      if (LOG)
        console.log(
          `ROW_DENSITY ${variant}\n${result.rows.map((row) => `${row.top.toFixed(2)}+${row.height.toFixed(2)} ${row.kind} ${row.id} | ${row.text}`).join("\n")}\n${JSON.stringify({ ...result, rows: undefined })}`,
        );
      if (OUT) {
        mkdirSync(OUT, { recursive: true });
        await page.screenshot({ path: path.join(OUT, `${variant}.png`), fullPage: true });
      }
      measured.set(variant, result);
      return result;
    } finally {
      await page.close();
    }
  };

  const lineRows = (rows: Row[]) => rows.filter((row) => row.kind !== "");
  /** An opened run draws a row per call, flush (`.cv-tools` gap 0): how many rows tall. */
  const callsIn = (height: number) => Math.round(height / ROW_METRIC.height);
  const runHeight = (calls: number) => calls * ROW_METRIC.height;

  for (const variant of MEASURED) {
    test(`each shut one-line row is one row of the metric, ${ROW_METRIC.height}px (${variant})`, async () => {
      const lines = lineRows((await of(variant)).rows);
      if (variant !== "folded") expect(lines.length).toBeGreaterThanOrEqual(4);
      // Opened (runs-open), a run is a whole number of rows of the metric.
      for (const row of lines) {
        const calls = variant === "runs-open" ? Math.max(1, callsIn(row.height)) : 1;
        expect({ row: `${row.id} | ${row.text}`, height: Math.round(row.height * 4) / 4 }).toEqual({
          row: `${row.id} | ${row.text}`,
          height: runHeight(calls),
        });
      }
    });
    test(`consecutive one-line rows sit flush, ${ROW_METRIC.height}px top to top (${variant})`, async () => {
      const { rows } = await of(variant);
      for (let index = 1; index < rows.length; index += 1) {
        const above = rows[index - 1]!;
        const below = rows[index]!;
        if (!above.kind || !below.kind) continue;
        expect({ pair: `${above.id} -> ${below.id}`, pitch: Math.round((below.top - above.top) * 4) / 4 }).toEqual({
          pair: `${above.id} -> ${below.id}`,
          pitch: Math.round(above.height * 4) / 4,
        });
        expect({ pair: `${above.id} -> ${below.id}`, above: Math.round(above.height * 4) / 4 }).toEqual({
          pair: `${above.id} -> ${below.id}`,
          above: runHeight(Math.max(1, callsIn(above.height))),
        });
      }
    });
    test(`each row's words are ${ROW_METRIC.font}px, its chips ${ROW_METRIC.chip}px, its glyphs ${ROW_METRIC.glyph}px (${variant})`, async () => {
      const { words, chips, glyphs } = await of(variant);
      expect(words.length).toBeGreaterThan(0);
      // "Worked for" keeps the prose size (--cv-worked-font-size), not the row metric's.
      for (const word of words) expect(word).toEqual({ cls: word.cls, size: word.cls === ".cv-worked__label" ? PROSE : ROW_METRIC.font });
      for (const chip of chips) expect(chip).toBeCloseTo(ROW_METRIC.chip, 1);
      for (const glyph of glyphs) expect(glyph).toBeCloseTo(ROW_METRIC.glyph, 1);
    });
    test(`"Worked for" is one row and its rule's room (${variant})`, async () => {
      const { rows, worked } = await of(variant);
      expect(worked.length).toBe(2);
      for (const height of worked) expect(height).toBeCloseTo(ROW_METRIC.height + ROW_METRIC.ruleAbove, 1);
      for (const row of rows.filter((each) => each.id.startsWith("worked-")))
        expect(row.height).toBeCloseTo(ROW_METRIC.height + ROW_METRIC.ruleAbove + ROW_METRIC.ruleBelow, 1);
    });
  }

  // The density candidates the gallery compares, drawn for the PR (no assertion past drawing).
  if (OUT)
    for (const variant of SHOTS)
      test(`draws ${variant}`, async () => {
        expect((await of(variant)).rows.length).toBeGreaterThan(0);
      });
});
