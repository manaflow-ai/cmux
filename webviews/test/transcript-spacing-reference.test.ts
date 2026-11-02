// A reply that something follows keeps the room its action row took on 2026-10-30, though it draws
// no row there now (model.ts `keepsReplyRoom`, conversation.css `--cv-reply-room`).
//
// Leo, 2026-11-01, on a capture he took of a NEXT build from about two days earlier: "i like this
// spacing kinda i prefer it to what we have now tho it's just minor differences".
//
// In gallery entry agent-pane.transcript-spacing-reference (one running turn in the capture's shape: a
// reply and a harness notice; a steer, a sent message and three paragraphs; a steer, a run of
// commands, a one-line reply, a run, an answered question and its answer), measured in Chromium in
// light and dark from one block's last drawn text line to the next block's first, each gap equals what
// feat-cmux-next 8f5dfe06ee58 (2026-10-30) drew for the same fixture. Two of them moved
// with the per-reply action row's removal on 2026-10-31 and come back here: a reply to the status row
// under it (17.75px before, 43.75px after) and a reply to the next prompt (21.75 before, 49.75 after).
// Those two are asserted to 0.5px; the rest are logged beside their 2026-10-30 values, since later
// settled designs own them (the one-line row pitch, #29965). No per-reply action row comes back.
//
// The second of them is now the grid's: #27580 (044769ae, transcript columns and block spacing) put
// every vertical gap on the stack (leo-workspace design/grid.md 5.5 Vertical rhythm: block 24, turn
// 32; "the boundary between a user message and another transcript element takes 32") and set
// `--cv-reply-room` to 0. So a reply to the next prompt is one turn gap between the two rows' boxes,
// read from `--grid-gap-turn` (45.75px ink to ink here), and is asserted that way in its own case.
// The reply to the status row under it is still held to its 2026-10-30 value here.
//
// CAPTURE keeps the capture's own gaps, read from its pixels, for reference only: they are not the
// 2026-10-30 build's, and a follow-up decides whether they become the target
// (design/chat-transcript.md "Rows between replies").
//
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every gap without the assertions.
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

  /**
   * Every gap the capture shows, in CSS px, ink to ink: from one block's last drawn text line to the
   * next block's first (a prompt's words, not its bubble; the question card's words, not its border),
   * so it compares with the capture, where only the text can be measured. null where a block is missing.
   */
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
      type Box = { top: number; bottom: number };
      /** The drawn text of `scope`: the union of its shown text runs' boxes. */
      const ink = (scope: Element | null | undefined): Box | null => {
        if (!scope) return null;
        let box: Box | null = null;
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.height === 0) continue;
            box = box
              ? { top: Math.min(box.top, rect.top), bottom: Math.max(box.bottom, rect.bottom) }
              : { top: rect.top, bottom: rect.bottom };
          }
        }
        return box;
      };
      /** The shown element whose own text holds `text`. */
      const holding = (text: string): HTMLElement | null => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode())
          if (node.textContent?.includes(text) && node.parentElement && shown(node.parentElement))
            return node.parentElement;
        return null;
      };
      const rowOf = (text: string) => holding(text)?.closest<HTMLElement>(".acpmux-row") ?? null;
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter(shown)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const rowAfter = (row: HTMLElement | null) => (row ? (rows[rows.indexOf(row) + 1] ?? null) : null);
      const paragraph = (text: string) => ink(holding(text)?.closest(".cv-md p, .cv-md li") ?? holding(text));
      const prompt = (text: string) => ink(holding(text)?.closest(".cv-user__bubble") ?? holding(text));

      const reply = paragraph("docs half of the release page");
      const notice = ink(rowOf("Fixed the stale release cache"));
      const there = prompt("are you there?");
      const sent = ink(rowAfter(rowOf("are you there?")));
      const first = paragraph("I'm here. The editor restarted");
      const second = paragraph("I've restarted the lane");
      const third = paragraph("The other lanes may have stopped");
      const regroup = prompt("we should regroup");
      const runFive = ink(rowAfter(rowOf("we should regroup")));
      const card = ink(holding("Which auth method")?.closest(".acpmux-row"));
      const ship = prompt("Yes, ship it");

      const gap = (above: Box | null, below: Box | null) =>
        above && below ? Math.round((below.top - above.bottom) * 100) / 100 : null;
      /** A row's own box: grid.md 5.5 measures its gaps between the boxes of adjacent elements. */
      const rowBox = (row: HTMLElement | null | undefined): Box | null => {
        if (!row) return null;
        const rect = row.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom };
      };
      /** The turn gap as the transcript draws it (the token scales with Interface Size). */
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--grid-gap-turn)";
      (document.querySelector(".acpmux-thread") ?? document.body).append(probe);
      const turnGap = probe.getBoundingClientRect().height;
      probe.remove();
      const thirdRow = holding("The other lanes may have stopped")?.closest<HTMLElement>(".acpmux-row");
      return {
        "paragraph -> prompt (rows)": gap(rowBox(thirdRow), rowBox(rowOf("we should regroup"))),
        "turn gap": turnGap,
        "reply -> notice": gap(reply, notice),
        "notice -> prompt": gap(notice, there),
        "prompt -> sent message": gap(there, sent),
        "sent message -> paragraph": gap(sent, first),
        "paragraph -> paragraph": gap(first, second),
        "paragraph -> paragraph (2)": gap(second, third),
        "paragraph -> prompt": gap(third, regroup),
        "prompt -> run summary": gap(regroup, runFive),
        "card -> prompt": gap(card, ship),
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

  /** What 8f5dfe06ee58 (2026-10-30) drew, CSS px (fleet job dbcc3aa4fd702e93d4132ce0, light and dark alike). */
  const OCT_30: Record<string, number> = {
    "reply -> notice": 43.75,
    "notice -> prompt": 23,
    "prompt -> sent message": 53.25,
    "sent message -> paragraph": 10.5,
    "paragraph -> paragraph": 19.75,
    "paragraph -> paragraph (2)": 19.75,
    "paragraph -> prompt": 49.75,
    "prompt -> run summary": 51.75,
    "card -> prompt": 28,
  };
  /**
   * The gap this test holds to OCT_30: the one under a reply over its status row. (A reply to the
   * next prompt is the grid's turn gap since #27580: its own case below.) The
   * others are logged beside them; later settled designs own them (the one-line row pitch, #29965).
   */
  const MOVED = ["reply -> notice"] as const;
  const TOLERANCE = 0.5;

  /**
   * The capture's gaps, text ink to text ink, CSS px (image px times 22.75 / 30: its body line pitch is
   * 30 image px). Reference only, not asserted: its build is not known yet.
   */
  const CAPTURE: Record<string, number> = {
    "reply -> notice": 29.6,
    "notice -> prompt": 84.9,
    "prompt -> sent message": 62.2,
    "sent message -> paragraph": 27.3,
    "paragraph -> paragraph": 19.7,
    "paragraph -> paragraph (2)": 20.5,
    "paragraph -> prompt": 81.9,
    "prompt -> run summary": 65.2,
    "card -> prompt": 72.8,
  };

  for (const theme of THEMES)
    test(`a reply keeps its 2026-10-30 room (${theme.name})`, async () => {
      const page = await open(theme.name);
      try {
        const measured = await measure(page);
        console.log(`TRANSCRIPT_SPACING ${theme.file} ${JSON.stringify(measured)} capture ${JSON.stringify(CAPTURE)}`);
        if (LOG_ONLY) return;
        const off = MOVED.map((name) => [name, OCT_30[name]!] as const)
          .filter(([name, want]) => measured[name] === null || Math.abs(measured[name]! - want) > TOLERANCE)
          .map(([name, want]) => `${name}: ${measured[name]}px, not ${want}px`);
        expect(off).toEqual([]);
      } finally {
        await page.close();
      }
    });

  for (const theme of THEMES)
    test(`a reply is one turn gap from the next prompt (${theme.name})`, async () => {
      const page = await open(theme.name);
      try {
        const measured = await measure(page);
        if (LOG_ONLY) return;
        const want = measured["turn gap"]!;
        expect(want).toBeGreaterThan(0);
        expect(measured["paragraph -> prompt (rows)"]).not.toBeNull();
        expect(Math.abs(measured["paragraph -> prompt (rows)"]! - want)).toBeLessThanOrEqual(TOLERANCE);
      } finally {
        await page.close();
      }
    });
});
