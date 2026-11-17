// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// An older page landing while the reader scrolls up restyles the rows it adds, not the rows already
// on screen (Leo, 2026-11-16: "how about speeding up the scrolling up of chats?" / "as in i scroll up
// and it loads the stuff").
//
// Each row an older page adds also adds its entry to the rail beside the transcript (threadMinimap),
// a few levels under the pane's `.acpmux-main`, which `:has()` rules of the pane's chrome ask about.
// Chromium answers an insert there by restyling, in the whole pane, every element any non-subject
// `:has()` rule could style past its `:has()`: one invalidation set for all of them. The transcript's
// rules put every icon (`.acpmux-tray-pull__tab:has([data-popup-open]) ... > svg[data-icon]`), every
// prompt's bubble (`.cv-user__body:has(> .cv-user__actions--pending) > .cv-user__bubble`) and every
// prompt's action row (`.cv-user:is(:not(:has(.cv-user__pending)), ...) > .cv-user__actions`) in
// that set: 355 elements outside one inserted row and its rail entry on this page, 29 without them
// (the pane's chrome). Flinging up the 100,000-row chat, with the composer's own rule (below) out,
// elements restyled outside the mounted ones went from about 390 a frame to about 180
// (bench/transcript-scroll-up-style-ablate.scratch.ts on lane/scroll-up-row-style-2). Those rules now
// ask marks their owners set (ui/popupWithin.ts, PendingSteer.tsx, UserBubble.tsx).
//
// The page is the pane's dev entry talking to a stand-in acpmux (support/papercutChat.ts) holding a
// 2,000-row chat, flung up once so older pages have landed; then one row and one rail entry, clones
// of the top ones, are inserted in one frame, and Chromium's own trace counts what it restyled
// (UpdateLayoutTree elementCount) less what was inserted.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";

await requireBrowserLane("transcript-insert-restyle.test.ts", async () => {
  setDefaultTimeout(500_000);
  /// The composer's own whole-subtree `:has()` (composerLocation.css, its fade rule) restyles the whole
  /// pane on the same insert; lane/scroll-up-composer-has takes it out. Until then this test takes it
  /// out of the page, so it measures the transcript's rules alone; once that lands this finds nothing.
  const COMPOSER_RULE =
    ".acpmux-composer-box[data-composer-grid]:has(.acpmux-md-field:is([data-fade-top], [data-fade-bottom]))";

  /// Elements restyled outside what was inserted: the pane's own chrome (its stage, dock and composer,
  /// about 30 here) answers the insert, the transcript's rows must not.
  const OUTSIDE_LIMIT = 80;
  if (!(await probeEngineOrSkip("transcript-insert-restyle.test.ts", "chromium", chromium))) return;
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  test("an older row landing restyles what it adds, not the rows on screen", async () => {
    const turns = 1_000;
    const pane = await papercutPane(() => browser!, {
      turns,
      running: false,
      lead: [],
      attachPage: 160,
      session: { turnCount: turns },
      daemonIndexes: true,
      askedPageSize: true,
    });
    try {
      const page = await pane.open({ width: 1100, height: 800 });
      const removed = await page.evaluate((selector) => {
        let count = 0;
        const walk = (list: CSSRuleList) => {
          for (let i = list.length - 1; i >= 0; i--) {
            const rule = list[i]!;
            if (rule instanceof CSSStyleRule && rule.selectorText.includes(selector)) {
              const parent = rule.parentRule as CSSGroupingRule | null;
              if (parent) parent.deleteRule(i);
              else rule.parentStyleSheet!.deleteRule(i);
              count += 1;
            } else if ("cssRules" in rule) walk((rule as CSSGroupingRule).cssRules);
          }
        };
        for (const sheet of Array.from(document.styleSheets))
          try {
            walk(sheet.cssRules);
          } catch {}
        return count;
      }, COMPOSER_RULE);
      // One fling up: older pages land, the rail fills, every row kind on screen.
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
      const steps = Array.from({ length: 60 }, (_, frame) => -[1500, 2400, 1900, 3000, 2100][frame % 5]!);
      await page.evaluate(traceUpwardAnchors, { steps, restFrames: 0 });
      await page.mouse.move(2, 2);
      const settle = () =>
        page.evaluate(
          () =>
            new Promise((resolve) =>
              requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 300))),
            ),
        );
      await settle();
      const census = await page.evaluate(() => ({
        rows: document.querySelectorAll(".acpmux-scroll .acpmux-row").length,
        rowElements: document.querySelectorAll(".acpmux-scroll .acpmux-row *").length,
        railEntries: document.querySelectorAll(".acpmux-minimap__entry").length,
        prompts: document.querySelectorAll(".cv-user__bubble").length,
        icons: document.querySelectorAll(".acpmux-main svg[data-icon]").length,
      }));

      const outside: number[] = [];
      for (let run = 0; run < 3; run++) {
        await browser!.startTracing(page, {
          categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"],
        });
        const inserted = await page.evaluate(() => {
          let elements = 0;
          for (const selector of [".acpmux-scroll .acpmux-row", ".acpmux-minimap__entry"]) {
            const top = document.querySelector(selector)!;
            const clone = top.cloneNode(true) as HTMLElement;
            clone.setAttribute("data-insert-probe", "");
            top.before(clone);
            elements += 1 + clone.getElementsByTagName("*").length;
          }
          void document.body.offsetHeight;
          return elements;
        });
        const trace = JSON.parse((await browser!.stopTracing()).toString()) as {
          traceEvents: { name: string; ph: string; args?: any }[];
        };
        let restyled = 0;
        for (const event of trace.traceEvents)
          if (event.name === "UpdateLayoutTree" && (event.ph === "X" || event.ph === "E"))
            restyled += Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
        outside.push(restyled - inserted);
        await page.evaluate(() => document.querySelectorAll("[data-insert-probe]").forEach((node) => node.remove()));
        await settle();
      }
      const median = [...outside].sort((a, b) => a - b)[1]!;
      console.log(
        `TRANSCRIPT-INSERT-RESTYLE ${JSON.stringify({ removedComposerRules: removed, census, outside, median })}`,
      );

      expect(census.rows).toBeGreaterThan(20);
      expect(census.railEntries).toBeGreaterThan(20);
      expect(census.prompts).toBeGreaterThan(10);
      expect(median, "elements restyled outside one inserted row and its rail entry").toBeLessThan(OUTSIDE_LIMIT);
    } finally {
      await pane.close();
    }
  });
});
