// A keystroke in the markdown page lays out its block's line, not the document. The pane
// (`.md-scroll`) was a size container (`container-type: inline-size`, for the wide table breakout's
// 100cqw), and Chromium laid out every block of the document on each keystroke inside it: 83 ms a
// key at 10,000 lines, 8 ms at 1,000 (bench/markdown-keystroke.bench.ts). The breakout reads the
// pane's width from `--md-pane-width` now (MarkdownPage.tsx `paneWidth`).
//
// The real page (markdown-page.html) on the dev server, through the stand-in host the bench uses,
// at 1,000 and 10,000 lines in Chromium: 10 characters typed into a paragraph in the middle, under
// a trace. Per key, the elements restyled and the area painted are the same at both sizes, and the
// layout time grows by less than a fixed bound (it grew tenfold with the container).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Browser, Page } from "playwright";
import { chromium } from "../bench/browsers";
import { serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-keystroke-layout-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let browser: Browser | null = null;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    describe.skip("markdown keystroke layout", () => test("no chromium", () => {}));
    return;
  }
  let served: BenchPage | undefined;
  beforeAll(async () => {
    served = await serveBenchPage("/markdown-page.html", { dev: true });
  }, 120_000);
  afterAll(async () => {
    await browser?.close();
    await served?.close();
  });

  const TOP = "layout-top";
  const BOTTOM = "layout-bottom";
  const NEEDLE = "middle-paragraph";
  const KEYS = 10;
  /** Painted frames in a row with nothing under the pane changed before the page counts as settled. */
  const QUIET_FRAMES = 3;

  /** About `lines` lines: each part a heading, a paragraph, an ordered list and a table. */
  const fixture = (lines: number) => {
    const part = (i: number, middle: boolean) =>
      `## Section ${i}\n\nParagraph ${i} has **bold** and a [link](#section-${i})${middle ? ` ${NEEDLE}` : ""} in ` +
      `a sentence long enough to wrap once in a 72 character column.\n\n` +
      `1. first step ${i}\n2. second step ${i}\n\n| name | size |\n| --- | ---: |\n| row ${i} | ${i} |\n\n`;
    const parts = Math.ceil(lines / (part(0, false).split("\n").length - 1));
    const body = Array.from({ length: parts }, (_, i) => part(i, i === Math.floor(parts / 2))).join("");
    return `# ${TOP}\n\n${body}${BOTTOM}\n`;
  };

  /** The stand-in host (bench/markdown-keystroke.bench.ts's): the file comes from `/__fixture`. */
  function installHost(): void {
    type Envelope = { t: string; id?: number; op?: string };
    let nextSub = 1;
    const postMessage = async (message: Envelope): Promise<unknown> => {
      if (message.t === "sub") return { t: "ok", id: message.id, value: { sub: nextSub++ } };
      if (message.t !== "call") return null;
      if (message.op === "cmux.markdown.config") {
        const text = await (await fetch("/__fixture", { cache: "no-store" })).text();
        return { t: "ok", id: message.id, value: { path: "/test/layout.md", text, hash: `h${text.length}` } };
      }
      return { t: "ok", id: message.id, value: {} };
    };
    (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
  }

  /** Resolves once the fonts are in and the pane has painted QUIET_FRAMES frames in a row with no
   *  change under it (no slice, decoration, observer write or scroll left to land in the trace). */
  async function settle(page: Page): Promise<void> {
    await page.evaluate(
      (quiet) =>
        new Promise<void>((resolve) => {
          const pane = document.querySelector(".md-scroll")!;
          let changed = false;
          const observer = new MutationObserver(() => (changed = true));
          observer.observe(pane, { subtree: true, childList: true, attributes: true, characterData: true });
          const scrolled = () => (changed = true);
          pane.addEventListener("scroll", scrolled);
          let still = 0;
          window.cmuxAfterPaint(() => {
            still = changed || document.fonts.status !== "loaded" ? 0 : still + 1;
            changed = false;
            if (still < quiet) return true;
            observer.disconnect();
            pane.removeEventListener("scroll", scrolled);
            resolve();
            return false;
          });
        }),
      QUIET_FRAMES,
    );
  }

  async function open(lines: number): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1200, height: 900 } });
    await installPaintedFrames(page);
    await page.route("**/__fixture", (route) =>
      route.fulfill({ status: 200, contentType: "text/markdown", body: fixture(lines) }),
    );
    await page.addInitScript(installHost);
    await page.goto(served!.url);
    await page.waitForFunction(
      (bottom) => !!document.querySelector(".md-prose")?.lastElementChild?.textContent?.includes(bottom),
      BOTTOM,
      { timeout: 180_000, polling: 200 },
    );
    await settle(page);
    return page;
  }

  type Work = { restyled: number; layoutMs: number; paintArea: number };

  /** KEYS characters typed after NEEDLE under a trace: per key, restyled elements, layout ms, painted px². */
  async function typeTraced(page: Page): Promise<Work> {
    // The caret goes after NEEDLE; the editor takes it on the selectionchange that follows.
    await page.evaluate((needle) => {
      const selected = new Promise((resolve) => document.addEventListener("selectionchange", resolve, { once: true }));
      const prose = document.querySelector<HTMLElement>(".md-prose")!;
      const walker = document.createTreeWalker(prose, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const at = node.textContent!.indexOf(needle);
        if (at < 0) continue;
        node.parentElement!.scrollIntoView({ block: "center" });
        prose.focus();
        getSelection()!.collapse(node, at + needle.length);
        return selected;
      }
      throw new Error(`no ${needle} in the document`);
    }, NEEDLE);
    await settle(page);
    type Ev = { name: string; ph: string; pid: number; tid: number; dur?: number; args?: Record<string, any> };
    await browser!.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] });
    for (let key = 0; key < KEYS; key++) {
      await page.keyboard.press("x");
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    }
    const events = (JSON.parse((await browser!.stopTracing()).toString()) as { traceEvents: Ev[] }).traceEvents;
    const mains = new Set(
      events
        .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
        .map((e) => `${e.pid}:${e.tid}`),
    );
    const work: Work = { restyled: 0, layoutMs: 0, paintArea: 0 };
    for (const e of events) {
      if (!mains.has(`${e.pid}:${e.tid}`) || e.ph !== "X") continue;
      if (e.name === "UpdateLayoutTree") work.restyled += Number(e.args?.elementCount ?? 0);
      else if (e.name === "Layout") work.layoutMs += (e.dur ?? 0) / 1000;
      else if (e.name === "Paint") {
        const clip = e.args?.data?.clip as number[] | undefined;
        if (clip?.length === 8)
          work.paintArea +=
            (Math.max(clip[0]!, clip[2]!, clip[4]!, clip[6]!) - Math.min(clip[0]!, clip[2]!, clip[4]!, clip[6]!)) *
            (Math.max(clip[1]!, clip[3]!, clip[5]!, clip[7]!) - Math.min(clip[1]!, clip[3]!, clip[5]!, clip[7]!));
      }
    }
    return { restyled: work.restyled / KEYS, layoutMs: work.layoutMs / KEYS, paintArea: work.paintArea / KEYS };
  }

  test("the pane is no size container, and the table breakout follows its width", async () => {
    const page = await open(100);
    const read = () =>
      page.evaluate(() => {
        const pane = document.querySelector<HTMLElement>(".md-scroll")!;
        return {
          container: getComputedStyle(pane).containerType,
          width: pane.style.getPropertyValue("--md-pane-width"),
          client: pane.clientWidth,
        };
      });
    const first = await read();
    expect(first.container).toBe("normal");
    expect(first.width).toBe(`${first.client}px`);
    await page.setViewportSize({ width: 900, height: 900 });
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const resized = await read();
    expect(resized.width).toBe(`${resized.client}px`);
    expect(resized.client).toBeLessThan(first.client);
    await page.close();
  });

  test("a keystroke's restyle, paint and layout do not grow with the document", async () => {
    const small = await open(1_000);
    const smallWork = await typeTraced(small);
    await small.close();
    const large = await open(10_000);
    const largeWork = await typeTraced(large);
    await large.close();
    console.log(
      `markdown-keystroke-layout: 1,000 lines ${JSON.stringify(smallWork)}, 10,000 ${JSON.stringify(largeWork)}`,
    );
    expect(largeWork.restyled).toBeLessThanOrEqual(5);
    expect(largeWork.restyled).toBeLessThanOrEqual(smallWork.restyled * 1.2 + 1);
    expect(largeWork.paintArea).toBeLessThanOrEqual(smallWork.paintArea * 1.2);
    // With the size container: 83 ms at 10,000 lines against 8 at 1,000.
    expect(largeWork.layoutMs).toBeLessThanOrEqual(smallWork.layoutMs + 15);
  });
});
