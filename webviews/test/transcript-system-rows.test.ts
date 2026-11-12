// The system and tool rows of Leo's 2026-11-02 capture of a Claude chat (gallery entry
// agent-pane.transcript-system-rows#leo-capture; Leo: "these are all so stupid looking"): another
// agent's received line, a reply that said only ".", "Scheduled check", an opened "Ran 2 commands"
// and a compaction's note ("Compaction ended": a running compaction is the live line's state).
// Measured between visible marks in Chromium, light and dark
// (leo-workspace design/transcript-spacing.md rule 2):
//
// - consecutive one-line rows are SYSTEM_ROW_PITCH (22) apart centre to centre, whatever their kind
//   (rule 3): no block gap between a status row, a background turn's line and a tool run;
// - a reply of one period draws nothing, so nothing sits on its own line under the received line;
// - "Scheduled check" and "Compaction ended" start their words on the run's text column.
//
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every row and every measured mark.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SYSTEM_ROW_PITCH } from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-system-rows.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-system-rows";
  const VARIANT = "leo-capture";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const LOG = process.env.CMUX_TRANSCRIPT_SPACING_LOG === "1";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript system rows", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Mark = { name: string; centre: number; left: number } | null;
  type Measured = { marks: Mark[]; bare: string[]; rows: string[] };

  /** The rows in the capture's order: each mark is the first glyph line of the text named. */
  const ORDER = [
    "gcp-agent-lane-2/cloud-clouddo",
    "Scheduled check",
    "Ran 2 commands",
    // A command the verb table does not know (`gh workflow`) reads as Bash's description
    // (commandActions.ts commandSaid).
    "Check backend.yml dispatch inputs",
    "Dispatch production promote of the candidate",
    "Compaction ended",
  ];

  const measure = (page: Page): Promise<Measured> =>
    page.evaluate((order) => {
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return false;
        }
        return true;
      };
      /** The glyph box of the first shown text node holding `text`. */
      const mark = (text: string) => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const at = node.textContent?.indexOf(text) ?? -1;
          if (at < 0 || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + text.length);
          const rect = [...range.getClientRects()].find((each) => each.width > 0 && each.height > 0);
          if (rect) return { name: text, centre: (rect.top + rect.bottom) / 2, left: rect.left };
        }
        return null;
      };
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].filter(shown);
      // A row that draws only punctuation or nothing: Leo's lone ".".
      const bare = rows
        .map((row) => (row.innerText || "").replace(/\s+/g, " ").trim())
        .filter((text) => /^[.\s]*$/.test(text) && rows.length > 0);
      return {
        marks: order.map(mark),
        bare,
        rows: rows.map((row) => {
          const box = row.getBoundingClientRect();
          const text = (row.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60);
          return `${box.top.toFixed(2)}-${box.bottom.toFixed(2)} ${row.className.replace(/\s+/g, ".")} | ${text}`;
        }),
      };
    }, ORDER);

  const measured = new Map<string, Measured>();
  const of = async (theme: (typeof THEMES)[number]) => {
    const known = measured.get(theme.file);
    if (known) return known;
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 1100, theme: theme.name, reducedMotion: "true", exp: "background-turn-look", arm: "line" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      const result = await measure(page);
      if (LOG)
        console.log(
          `TRANSCRIPT_SYSTEM_ROWS ${theme.file}\n${result.rows.join("\n")}\n${JSON.stringify({ ...result, rows: undefined })}`,
        );
      measured.set(theme.file, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const theme of THEMES) {
    test(`finds every row of the capture (${theme.file})`, async () => {
      const { marks } = await of(theme);
      expect(marks.map((each, index) => (each ? each.name : `missing: ${ORDER[index]}`))).toEqual(ORDER);
    });
    test(`a reply of one period draws nothing (${theme.file})`, async () => {
      expect((await of(theme)).bare).toEqual([]);
    });
    for (let index = 1; index < ORDER.length; index += 1)
      test(`"${ORDER[index - 1]}" to "${ORDER[index]}" is ${SYSTEM_ROW_PITCH}px centre to centre (${theme.file})`, async () => {
        const { marks } = await of(theme);
        const gap = marks[index]!.centre - marks[index - 1]!.centre;
        expect(Math.abs(gap - SYSTEM_ROW_PITCH)).toBeLessThanOrEqual(1);
      });
    test(`"Scheduled check" and the compaction start their words on the run's text column (${theme.file})`, async () => {
      const { marks } = await of(theme);
      const run = marks[2]!.left;
      expect(Math.abs(marks[1]!.left - run)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(marks[5]!.left - run)).toBeLessThanOrEqual(0.5);
    });
  }
});
