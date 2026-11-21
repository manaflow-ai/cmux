// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The live line's words start on the reply's text column in every state it takes, and its dots
// stand evenly between its segments.
//
// Leo, 2026-11-03: "this is also misaligned with the left text right now for some reason...
// there's sometimes weird indenting?", on "Thinking · 53s total · 912 tokens" and "Ran leo-forward …"
// starting right of the reply above them; then "this aint aligned also the total is redundant" and
// "same here it's annoying to look at", on "Ran cat … 0s  · 39s total  · 1K tokens" with a wider gap
// before each dot. #34370 put the live line on the icon column; this holds it there for each state.
//
// Measured in Chromium on gallery entry agent-pane.long-subagent-wait, one variant per state
// (Thinking, a finished command, a finished step, Writing, Waiting on 3 subagents), light and dark:
// - the live line's first glyph is at the x of the first reply's first glyph;
// - every dot in the line has the same room before it as after it.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-live-line-left-edge-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.long-subagent-wait";
  const VARIANTS = ["thinking", "ran-command", "finished-step", "writing", "waiting-on-subagents"];
  const THEMES = ["Apple System Colors Light", "Catppuccin Mocha"];
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript live line left edge", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0]! } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measured = {
    reply: number | null;
    live: { x: number; text: string } | null;
    dots: { before: number; after: number }[];
  };

  const measure = async (variant: string, theme: string): Promise<Measured> => {
    const page = await browser.newPage({ viewport: { width: 800, height: 900 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760, theme, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      return await page.evaluate(() => {
        /** The client rects of every laid-out text run in `scope`, in order. */
        const runs = (scope: Element) => {
          const out: { left: number; right: number; text: string; node: Node }[] = [];
          const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.textContent?.trim()) continue;
            // The shimmer's lit layer repeats the words over them; measure the words themselves.
            if (
              (node.parentElement as HTMLElement | null)?.closest(
                ".cv-shimmer__lit, [aria-hidden='true']:not(.cv-worked__sep)",
              )
            )
              continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            const rect = range.getBoundingClientRect();
            if (rect.width > 0) out.push({ left: rect.left, right: rect.right, text: node.textContent.trim(), node });
          }
          return out;
        };
        const reply = document.querySelector(".acpmux-row.acpmux-assistant .cv-md");
        const line = document.querySelector(".acpmux-row .cv-worked.cv-worked--live");
        const words = line ? runs(line) : [];
        const dots: Measured["dots"] = [];
        words.forEach((run, index) => {
          if (run.text !== "·" || index === 0 || index === words.length - 1) return;
          dots.push({ before: run.left - words[index - 1]!.right, after: words[index + 1]!.left - run.right });
        });
        return {
          reply: reply ? (runs(reply)[0]?.left ?? null) : null,
          live: words[0] ? { x: words[0].left, text: words.map((run) => run.text).join(" ") } : null,
          dots,
        };
      });
    } finally {
      await page.close();
    }
  };

  for (const theme of THEMES)
    for (const variant of VARIANTS)
      test(`${variant} (${theme}): the live line starts on the reply's text column, its dots evenly spaced`, async () => {
        const { reply, live, dots } = await measure(variant, theme);
        expect(reply).not.toBeNull();
        expect(live).not.toBeNull();
        expect({ text: live!.text, offset: Math.abs(live!.x - reply!) <= TOLERANCE ? 0 : live!.x - reply! }).toEqual({
          text: live!.text,
          offset: 0,
        });
        expect(live!.text).not.toContain("total");
        expect(dots.filter((dot) => Math.abs(dot.before - dot.after) > 1)).toEqual([]);
      });
});
