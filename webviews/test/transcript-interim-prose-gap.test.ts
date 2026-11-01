// Interim prose between tool rows has room above and below it.
//
// Leo, 2026-11-01, on a line of the agent's prose sitting tight between a tool row and a "Ran 2
// commands" row: "the thoughts in between tool calls probably want a bit more padding".
//
// In gallery entry agent-pane.interim-prose-gap (a running turn's opened run: a command, a short
// note, "Ran 2 commands" opened, a note, a command; turns.ts mergeShortNotes folds the notes into
// the run), measured in Chromium in light and dark:
// - each note (`.cv-tool-note`) has the run's block gap (24 on the grid; 12px `--cv-note-gap` on base
//   before the grid) between its text box and the row above it, and as much to the row below it;
// - every other gap in the run (between its tool rows, around the run) is the same as in the
//   `tight` variant, which draws the earlier 3px.
// design/chat-transcript.md "Notes between tool rows".
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { gridLength } from "../src/agent-session/acpmux/transcriptGrid";

await requireBrowserLane("transcript-interim-prose-gap.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.interim-prose-gap";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  /** The room above and below a note, CSS px (conversation.css `--cv-note-gap`). */
  // On the transcript grid (design/grid.md 5.5) a run stacks its rows and notes with the block gap,
  // so a note has the run's 24 above and below it: more room than #30400's 12, which this test held
  // on base, and the same as between any two blocks of the run.
  const NOTE_GAP = gridLength("gap-block");
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript interim prose gap", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "shipped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** One gap between two stacked boxes in the run: their labels and the room between them. */
  type Gap = { pair: string; room: number; note: boolean };

  /** Every vertical gap between the opened run's stacked boxes: its rows, groups and notes. */
  const measure = (page: Page): Promise<Gap[]> =>
    page.evaluate(() => {
      const label = (element: Element) =>
        element.classList.contains("cv-tool-note") ? "note" : (element.textContent ?? "").trim().slice(0, 24);
      const boxes = [...document.querySelectorAll(".cv-tool-run .cv-tool, .cv-tool-run .cv-tool-note")]
        .filter((element) => element.getBoundingClientRect().height > 0)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const gaps: Gap[] = [];
      for (let index = 0; index + 1 < boxes.length; index += 1) {
        const upper = boxes[index]!;
        const lower = boxes[index + 1]!;
        gaps.push({
          pair: `${label(upper)} -> ${label(lower)}`,
          room: lower.getBoundingClientRect().top - upper.getBoundingClientRect().bottom,
          note: upper.classList.contains("cv-tool-note") || lower.classList.contains("cv-tool-note"),
        });
      }
      return gaps;
    });

  const open = async (variant: string, theme: string) => {
    const page = await browser.newPage({ viewport: { width: 900, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 720, theme, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };
  const px = (value: number) => `${Math.round(value * 100) / 100}px`;

  for (const theme of THEMES)
    test(`a note between tool rows has room above and below it (${theme.name})`, async () => {
      const page = await open("shipped", theme.name);
      const earlier = await open("tight", theme.name);
      try {
        const gaps = await measure(page);
        console.log(`INTERIM_GAP shipped ${theme.file} ${JSON.stringify(gaps)}`);
        const around = gaps.filter((gap) => gap.note);
        // Two notes, each with a row above and below it.
        expect(around.length).toBe(4);
        const found = around
          .filter((gap) => Math.abs(gap.room - NOTE_GAP) > TOLERANCE)
          .map((gap) => `${gap.pair}: ${px(gap.room)}, not ${NOTE_GAP}px`);
        expect(found).toEqual([]);
        // Nothing else moves: the gaps between the run's tool rows match the earlier rhythm.
        const before = await measure(earlier);
        console.log(`INTERIM_GAP tight ${theme.file} ${JSON.stringify(before)}`);
        const others = (list: Gap[]) => list.filter((gap) => !gap.note).map((gap) => `${gap.pair} ${px(gap.room)}`);
        expect(others(gaps)).toEqual(others(before));
      } finally {
        await page.close();
        await earlier.close();
      }
    });
});
