// cmux-web-test-timeout: 300
// l10n-allow-file: the stand-in chat's text, not shipped UI.
// What a transcript row's own change restyles: that row's neighbourhood, never the page (Leo 2026-11-16: "how about
// speeding up the scrolling up of chats?" / "as in i scroll up and it loads the stuff"). A row that mounts while a
// long chat is flung up marks its own scrollers' edges (`data-fade-top` / `data-fade-bottom`), and a composer rule,
// `.acpmux-composer-box:has(.acpmux-md-field:is([data-fade-top], [data-fade-bottom])) .acpmux-composer-inner >
// :not(...)`, had Chromium restyle every element in the page for each mark: a `:has()` before a combinator whose last
// compound names no class or attribute leaves it no narrower set to check again than the whole document. That was
// about 2,300 elements a fling frame on a 100k-row chat and 2.6-3.0 s of style over a 24-frame fling
// (bench/transcript-scroll-up-style.bench.ts); test/css-invalidation-scope.test.ts rejects the shape by its text, and
// this file measures it.
//
// The production pane (a vite build) in Chromium on the papercut stand-in daemon, a chat of TURNS finished turns.
// Chromium's own trace counts the elements restyled (UpdateLayoutTree elementCount, as
// pane-has-restyle.browser.test.ts reads it) until two frames have painted after the change. About 25 s, most of it
// the build.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/transcript-row-restyle.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Change = "fade-mark" | "append";

await requireBrowserLane("transcript-row-restyle.test.ts", async () => {
  setDefaultTimeout(280_000);
  const TURNS = 400;
  const RUNS = 5;

  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  let page: Page | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, { turns: TURNS, running: false, production: {} });
    page = await pane.open({ width: 1100, height: 800 });
  }, 280_000);
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  /** Makes `change` on the last transcript row (or undoes it), then waits two painted frames. */
  const apply = (change: Change, undo: boolean) =>
    page!.evaluate(
      async ({ change, undo }) => {
        const rows = document.querySelectorAll(".acpmux-scroll .acpmux-row");
        const row = rows[rows.length - 1]!;
        if (change === "fade-mark") row.toggleAttribute("data-fade-bottom", !undo);
        else if (undo) document.querySelectorAll("[data-row-restyle-probe]").forEach((node) => node.remove());
        else {
          const node = document.createElement("span");
          node.textContent = "probe";
          node.setAttribute("data-row-restyle-probe", "");
          (row.querySelector(".cv-md") ?? row).append(node);
        }
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      },
      { change, undo },
    );

  /** The median over RUNS of the elements Chromium restyled (every UpdateLayoutTree's elementCount) for `change`. */
  async function restyled(change: Change) {
    const counts: number[] = [];
    for (let run = 0; run < RUNS; run++) {
      await browser!.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] });
      await apply(change, false);
      const raw = JSON.parse((await browser!.stopTracing()).toString()) as {
        traceEvents: { name: string; ph: string; args?: { elementCount?: number; data?: { elementCount?: number } } }[];
      };
      let total = 0;
      for (const event of raw.traceEvents)
        if (event.name === "UpdateLayoutTree" && (event.ph === "X" || event.ph === "E"))
          total += Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
      counts.push(total);
      await apply(change, true);
    }
    const pageElements = await page!.evaluate(() => document.getElementsByTagName("*").length);
    const median = [...counts].sort((a, b) => a - b)[Math.floor(counts.length / 2)]!;
    console.log(`transcript-row-restyle ${change} ${JSON.stringify({ counts, median, pageElements })}`);
    return median;
  }

  test("a scroll-edge mark inside a transcript row restyles far fewer elements than the page holds", async () => {
    // Before: 1,915, the page's 1,406 elements and some twice. After: 437, the rows that the outputs list's edge rule
    // (`:has(> [data-fade-*])`, session-info/outputsEdge.css) has Chromium check again.
    expect(await restyled("fade-mark")).toBeLessThan(700);
  });

  test("an element appended to a transcript row restyles only around it", async () => {
    // 22 before, 13 after: the element, its row's few and the pane's narrow rules.
    expect(await restyled("append")).toBeLessThan(100);
  });
});
