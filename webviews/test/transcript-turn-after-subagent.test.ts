// l10n-allow-file: test fixture replies, not shipped UI.
// The main agent's turns after a subagent's row, in Chromium (gallery agent-pane.turn-after-subagent,
// which replays acpmux's events through the pane's own client). Leo, 2026-11-08: "idk what happened
// here like the text in this situation isn't from the subagent?". The sequence: a background
// command's end, the subagent's "Subagent finished" row, then three turns the agent ran on its own
// (task notifications, no prompt). With the report closed, opened and closed again, each reply draws
// outside the subagent row's box, at the reply column, with the turn gap over it and its own footer
// under it, and closing the report puts every row back where it was.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { AGENT, OWN_REPLIES } from "../src/agent-session/acpmux/conversation/TurnAfterSubagent.gallery";
import { TRANSCRIPT_TURN_GAP } from "../src/agent-session/acpmux/transcriptGrid";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-turn-after-subagent.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.turn-after-subagent";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("turn after subagent", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "own-turn" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Two frames: the transcript has placed the rows the toggle changed (reduced motion: no tween). */
  const settled = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  type Box = { top: number; bottom: number; left: number; right: number };
  type Reply = {
    text: Box | null;
    insideSubagent: boolean;
    row: string | null;
    opens: boolean;
    gapAbove: number | null;
    next: string | null;
  };

  /** Where each of the agent's replies draws, against the subagent's row. */
  const measure = (page: Page) =>
    page.evaluate(
      ({ agent, replies }) => {
        const box = (element: Element | null | undefined) => {
          const rect = element?.getBoundingClientRect();
          return rect ? { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right } : null;
        };
        const subagent = document.querySelector(`.acpmux-row[data-row-id="subagentDone:${agent}"]`);
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].sort(
          (a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top,
        );
        /** The first paragraph whose words start with `words` (a reply's Markdown links its refs). */
        const textOf = (words: string) =>
          [...document.querySelectorAll(".acpmux-row p")].find((node) => node.textContent?.trim().startsWith(words)) ??
          null;
        const prompt = textOf("Started a subagent on it.");
        const promptRange = prompt ? document.createRange() : null;
        promptRange?.selectNodeContents(prompt!);
        const replyLeft = promptRange?.getClientRects()[0]?.left ?? null;
        const out = replies.map((reply) => {
          const node = textOf(reply.split("\n")[0]!.slice(0, 40));
          if (!node) return { text: null, insideSubagent: false, row: null, opens: false, gapAbove: null, next: null };
          const range = document.createRange();
          range.selectNodeContents(node);
          const first = range.getClientRects()[0] ?? null;
          const article = node.parentElement?.closest<HTMLElement>(".acpmux-row[data-row-id]") ?? null;
          const at = article ? rows.indexOf(article) : -1;
          let above: HTMLElement | undefined;
          for (let index = at - 1; index >= 0; index -= 1)
            if (rows[index]!.getBoundingClientRect().height > 0) {
              above = rows[index];
              break;
            }
          return {
            text: first ? { top: first.top, bottom: first.bottom, left: first.left, right: first.right } : null,
            insideSubagent: subagent?.contains(node) ?? false,
            row: article?.dataset.rowId ?? null,
            opens: article?.dataset.opensTurn === "true",
            gapAbove:
              article && above ? article.getBoundingClientRect().top - above.getBoundingClientRect().bottom : null,
            next: rows[at + 1]?.dataset.rowId ?? null,
          };
        });
        return {
          subagent: box(subagent),
          replyLeft,
          replies: out,
          tops: rows.map((row) => `${row.dataset.rowId} ${row.getBoundingClientRect().top.toFixed(1)}`),
        };
      },
      { agent: AGENT, replies: OWN_REPLIES },
    );

  const check = (state: string, result: Awaited<ReturnType<typeof measure>>) => {
    const why = `${state}; rows:\n${result.tops.join("\n")}`;
    expect(result.subagent, why).not.toBeNull();
    let previousTop = -Infinity;
    for (const [index, reply] of (result.replies as Reply[]).entries()) {
      const what = `${why}\nreply ${index + 1}: ${JSON.stringify(reply)}`;
      expect(reply.text, what).not.toBeNull();
      // Outside the subagent row's box, below it, at the reply column.
      expect(reply.insideSubagent, what).toBe(false);
      expect(reply.text!.top, what).toBeGreaterThanOrEqual(result.subagent!.bottom);
      expect(Math.abs(reply.text!.left - result.replyLeft!), what).toBeLessThanOrEqual(1);
      // Its own turn: the boundary mark, the turn gap over it, its own footer under it.
      expect(reply.opens, what).toBe(true);
      expect(Math.abs(reply.gapAbove! - TRANSCRIPT_TURN_GAP), what).toBeLessThanOrEqual(1);
      expect(reply.next, what).toBe(`backgroundEnd-own-${index + 1}`);
      expect(reply.text!.top, what).toBeGreaterThan(previousTop);
      previousTop = reply.text!.top;
    }
  };

  test("the agent's turns after a subagent row are its own, the report closed, opened and closed again", async () => {
    const page = await browser.newPage({ viewport: { width: 1000, height: 1300 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "own-turn", width: 900, theme: "Catppuccin Mocha", reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    const closed = await measure(page);
    check("closed", closed);
    // The background command's end draws as its own row above the subagent's.
    expect(
      closed.tops.some((line) => line.includes("subagentDone:")),
      closed.tops.join("\n"),
    ).toBe(true);

    const toggle = page.locator(`.acpmux-row[data-row-id="subagentDone:${AGENT}"] .cv-agentmsg__chevron`);
    await toggle.click();
    await page.waitForSelector(".cv-subagent-done__report");
    await settled(page);
    const open = await measure(page);
    check("open", open);
    // The report is inside the subagent's row; the first reply starts under the opened card.
    expect(open.subagent!.bottom).toBeGreaterThan(closed.subagent!.bottom);
    expect(open.replies[0]!.text!.top).toBeGreaterThan(closed.replies[0]!.text!.top);

    await toggle.click();
    await page.waitForFunction(() => !document.querySelector(".cv-subagent-done__report"));
    await settled(page);
    const again = await measure(page);
    check("closed again", again);
    // Closing puts every row back: no jump, no row left at the opened place.
    for (const [index, reply] of again.replies.entries())
      expect(Math.abs(reply.text!.top - closed.replies[index]!.text!.top)).toBeLessThanOrEqual(0.5);
    await page.close();
  });
});
