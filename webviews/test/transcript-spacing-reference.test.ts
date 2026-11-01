// The transcript's vertical spacing is the 2026-10-30 NEXT nightly's.
//
// Leo, 2026-11-01, on a capture of that build: "i like this spacing kinda i prefer it to what we have
// now tho it's just minor differences".
//
// In gallery entry agent-pane.transcript-spacing-reference (three settled turns: a reply and a
// subagent's end; a prompt, a sent message and three paragraphs; a prompt, a run of commands, a short
// reply, a second run, an answered question card and the next prompt), measured in Chromium in light
// and dark, each gap below equals the value the 2026-10-30 build (feat-cmux-next 8f5dfe06ee58) drew
// for the same fixture, to 0.5px. A gap runs from one block's bottom to the next one's top, where a
// block is a prompt's bubble, a prose paragraph, the question card's border box, or the drawn text of
// any other row (a tool run's summary, a subagent's end, a sent message).
// design/chat-transcript.md "Transcript spacing" keeps the table.
//
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every gap only, without the assertions: how the reference
// values were read at 8f5dfe06ee58.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-spacing-reference.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-spacing-reference";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const TOLERANCE = 0.5;
  const LOG_ONLY = process.env.CMUX_TRANSCRIPT_SPACING_LOG === "1";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript spacing reference", () => test("browser", () => {}));
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

  type Measured = Record<string, number | null>;

  /** Every gap the reference names, in CSS px; null where a block is missing. */
  const measure = (page: Page): Promise<Measured> =>
    page.evaluate(() => {
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
        }
        return true;
      };
      type Box = { top: number; bottom: number; left: number };
      /** The drawn text of `scope`: the union of its shown text runs' boxes. */
      const ink = (scope: Element): Box | null => {
        let box: Box | null = null;
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.height === 0) continue;
            box = box
              ? {
                  top: Math.min(box.top, rect.top),
                  bottom: Math.max(box.bottom, rect.bottom),
                  left: Math.min(box.left, rect.left),
                }
              : { top: rect.top, bottom: rect.bottom, left: rect.left };
          }
        }
        return box;
      };
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter(shown)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      /** The shown element whose own text holds `text`, deepest first. */
      const holding = (text: string): HTMLElement | null => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode())
          if (node.textContent?.includes(text) && node.parentElement && shown(node.parentElement))
            return node.parentElement;
        return null;
      };
      const rect = (element: Element | null | undefined): Box | null => {
        if (!element) return null;
        const box = element.getBoundingClientRect();
        return { top: box.top, bottom: box.bottom, left: box.left };
      };
      const bubble = (text: string) => rect(holding(text)?.closest(".cv-user__bubble") ?? holding(text));
      /** A prose paragraph's line boxes, or the text's own where it is not a paragraph. */
      const paragraph = (text: string) => {
        const at = holding(text);
        return rect(at?.closest(".cv-md p, .cv-md li") ?? at);
      };
      const rowOf = (text: string) => holding(text)?.closest<HTMLElement>(".acpmux-row") ?? null;
      const rowAfter = (row: HTMLElement | null) => (row ? (rows[rows.indexOf(row) + 1] ?? null) : null);
      const rowInk = (row: HTMLElement | null) => (row ? ink(row) : null);
      /** The question card: the nearest bordered box around its question. */
      const card = (() => {
        for (let node = holding("Which auth method"); node; node = node.parentElement)
          if (parseFloat(getComputedStyle(node).borderTopWidth) > 0) return node;
        return null;
      })();

      const reply = paragraph("docs half of the release page");
      const status = rowInk(rowOf("Fixed the stale release cache"));
      const there = bubble("are you there?");
      const sent = rowInk(rowAfter(rowOf("are you there?")));
      const first = paragraph("I'm here. The editor restarted");
      const second = paragraph("I've restarted the lane");
      const third = paragraph("The other lanes may have stopped");
      const regroup = bubble("we should regroup");
      const runFive = rowInk(rowAfter(rowOf("we should regroup")));
      const note = paragraph("reading the release dashboard");
      const noteRow = rowOf("reading the release dashboard");
      const runThree = noteRow?.querySelector(".cv-md") ? rowInk(rowAfter(noteRow)) : null;
      const cardBox = rect(card);
      const cardInk = card ? ink(card) : null;
      const ship = bubble("Yes, ship it");

      const gap = (above: Box | null, below: Box | null) =>
        above && below ? Math.round((below.top - above.bottom) * 100) / 100 : null;
      const inset = (value: number | null) => (value === null ? null : Math.round(value * 100) / 100);
      return {
        "reply -> status line": gap(reply, status),
        "status line -> prompt": gap(status, there),
        "prompt -> sent message": gap(there, sent),
        "sent message -> paragraph": gap(sent, first),
        "paragraph -> paragraph": gap(first, second),
        "paragraph -> paragraph (2)": gap(second, third),
        "paragraph -> prompt": gap(third, regroup),
        "prompt -> run summary": gap(regroup, runFive),
        "run summary -> prose": gap(runFive, note),
        "prose -> run summary": gap(note, runThree),
        "run summary -> card": gap(runThree, cardBox),
        "card padding top": cardBox && cardInk ? inset(cardInk.top - cardBox.top) : null,
        "card padding left": cardBox && cardInk ? inset(cardInk.left - cardBox.left) : null,
        "card padding bottom": cardBox && cardInk ? inset(cardBox.bottom - cardInk.bottom) : null,
        "card -> prompt": gap(cardBox, ship),
      };
    });

  const open = async (theme: string) => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 1700 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "shipped", width: 1100, theme, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    return page;
  };

  /**
   * What the 2026-10-30 nightly (feat-cmux-next 8f5dfe06ee58) drew for this fixture, CSS px, read
   * with CMUX_TRANSCRIPT_SPACING_LOG=1 (fleet job 8ddeea232026d2fd60296122, light and dark alike).
   * Before this change, base drew three of them smaller: reply -> status line 14, paragraph ->
   * prompt 8, prose -> run summary 14 (the room the per-reply action row took, removed with it).
   */
  const REFERENCE: Record<string, number> = {
    "reply -> status line": 40,
    "status line -> prompt": 13,
    "prompt -> sent message": 41.5,
    "sent message -> paragraph": 8.5,
    "paragraph -> paragraph": 14,
    "paragraph -> paragraph (2)": 14,
    "paragraph -> prompt": 36,
    "prompt -> run summary": 40,
    "run summary -> prose": 7.5,
    "prose -> run summary": 40,
    "run summary -> card": 8.5,
    "card padding top": 10,
    "card padding left": 13,
    "card padding bottom": 10,
    "card -> prompt": 8,
  };

  for (const theme of THEMES)
    test(`gaps match the 2026-10-30 rhythm (${theme.name})`, async () => {
      const page = await open(theme.name);
      try {
        const measured = await measure(page);
        console.log(`TRANSCRIPT_SPACING ${theme.file} ${JSON.stringify(measured)}`);
        if (LOG_ONLY) return;
        const off = Object.entries(REFERENCE)
          .filter(([name, want]) => measured[name] === null || Math.abs(measured[name]! - want) > TOLERANCE)
          .map(([name, want]) => `${name}: ${measured[name]}px, not ${want}px`);
        expect(off).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
