// A copy across the Feed's diff lines that are not mounted copies what the browser copies with every
// line mounted, byte for byte, the text above and below the lines included (DiffLines.tsx). The text a
// person cannot select there (the Decline button above, the poster line and the diff's file name over
// the lines, the Once, Deny and Allow buttons below) is left out, as the browser leaves it out of its
// own copy; the page's copy used to read that part with the range's own text, which holds it.
//
// Each selection is made the same way on two pages of the same 300-line diff: one tall enough that
// every line mounts (the browser copies by itself), and one 800 px tall (most lines not mounted).
//
// A production build of test/browser/feed-visible-only.html (the real Feed page over the mock
// provider), as bench/cloud-feed-visible-only.bench.ts serves it.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/feed-diff-copy-labels-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("feed-diff-copy-labels-browser.test.ts", async () => {
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: Array<(typeof engines)[number]> = [];
  for (const engine of engines)
    if (await probeEngineOrSkip(`feed-diff-copy-labels-browser ${engine[0]}`, engine[0], engine[1])) runs.push(engine);
  if (runs.length === 0) return;
  setDefaultTimeout(300_000);

  const N = 300;
  const LINE = ".feed-detail .feed-diff-line";
  const SCROLLER = ".feed-detail-scroll";
  /** Labels of controls and other unselectable text around the diff, none of them in the diff. */
  const UNSELECTABLE = ["Decline", "FeedModel.swift.diff", "Once", "Deny", "Allow"];
  let served: BenchPage;
  beforeAll(async () => {
    // bun test sets NODE_ENV=test, and Vite would build React's development JSX into the page.
    const env = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/feed-visible-only.html", { dev: false });
    } finally {
      process.env.NODE_ENV = env;
    }
  });
  afterAll(async () => {
    await served?.close();
  });

  async function open(browser: Browser, engine: string, height: number) {
    const context = await browser.newContext({ viewport: { width: 1200, height } });
    if (engine === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const page = await context.newPage();
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => window.benchReady === true);
    return page;
  }

  /** The selection's anchor and focus, by the element they are in and the offset. */
  const ends = (page: Page) =>
    page.evaluate(() => {
      const selection = document.getSelection()!;
      const name = (node: Node | null) => {
        const element = node?.nodeType === 3 ? node.parentElement! : (node as HTMLElement);
        return `${element.className}${element.dataset?.index ?? ""}`;
      };
      return [name(selection.anchorNode), selection.anchorOffset, name(selection.focusNode), selection.focusOffset];
    });

  /** What the clipboard holds after a copy of the page's selection, and the selection's ends just
   *  after the copy. */
  async function copied(page: Page, engine: string) {
    if (engine === "chromium") {
      await page.evaluate(() => navigator.clipboard.writeText(""));
      await page.keyboard.press("Control+c");
      const after = await ends(page);
      return { text: await page.evaluate(() => navigator.clipboard.readText()), after };
    }
    // WebKit headless gives no clipboard read: copy, then paste into a field of the page's own (which
    // takes the selection, so its ends are read before).
    await page.evaluate(() => document.execCommand("copy"));
    const after = await ends(page);
    await page.evaluate(() => {
      const area = document.createElement("textarea");
      area.id = "paste-here";
      area.style.cssText = "position:fixed;top:0;left:0;width:10px;height:10px";
      document.body.append(area);
      area.focus();
    });
    await page.keyboard.press("Control+v");
    const text = await page.evaluate(() => {
      const area = document.getElementById("paste-here") as HTMLTextAreaElement;
      const value = area.value;
      area.remove();
      return value;
    });
    return { text, after };
  }

  /** Select-all, as Ctrl+A in the pane (Chromium) or the Edit menu runs it (WebKit headless binds no
   *  key to it here). */
  async function selectAll(page: Page, engine: string) {
    if (engine === "chromium") {
      const box = (await page.locator(SCROLLER).boundingBox())!;
      await page.mouse.click(box.x + box.width / 2, box.y + 10);
      await page.keyboard.press("Control+a");
    } else await page.evaluate(() => document.execCommand("selectAll"));
  }

  /** The selection a drag makes: from above the lines (the title's start, or the detail's top, its
   *  toolbar) to "+    " in line 200, or from inside line 5 to the detail's end, below the answer
   *  buttons. The pane then scrolls, so the lines between the ends are not mounted. `backward` puts the
   *  anchor at the end. */
  const select = (page: Page, from: "title" | "top" | "line", backward = false) =>
    page.evaluate(
      async ({ from, backward, line, scroller }) => {
        const pane = document.querySelector<HTMLElement>(scroller)!;
        const row = async (index: number) => {
          pane.scrollTop = 0;
          for (let tries = 0; tries < 100; tries++) {
            const found = document.querySelector<HTMLElement>(`${line}[data-index="${index}"]`);
            if (found) return found;
            pane.scrollTop += 300;
            // raf-read: waits for the window to mount the lines a scroll brings in; it reads the DOM, not paint.
            await new Promise((resolve) => requestAnimationFrame(resolve));
          }
          throw new Error(`line ${index} never mounted`);
        };
        const range = document.createRange();
        if (from === "line") {
          range.setStart((await row(5)).firstChild!, 3);
          const detail = document.querySelector(".feed-detail")!;
          range.setEnd(detail, detail.childNodes.length);
        } else {
          const end = await row(200);
          if (from === "title") range.setStart(document.querySelector(".feed-detail-title")!.firstChild!, 0);
          else range.setStart(document.querySelector(".feed-detail")!, 0);
          range.setEnd(end.firstChild!, 5);
        }
        const selection = document.getSelection()!;
        if (backward)
          selection.setBaseAndExtent(range.endContainer, range.endOffset, range.startContainer, range.startOffset);
        else {
          selection.removeAllRanges();
          selection.addRange(range);
        }
        pane.scrollTop = from === "line" ? pane.scrollHeight : 0;
      },
      { from, backward, line: LINE, scroller: SCROLLER },
    );

  for (const [engine, type] of runs)
    test(`${engine}: a copy across lines not mounted is the browser's own copy with every line mounted, no control's label in it`, async () => {
      const browser = await type.launch({ headless: true });
      try {
        const tall = await open(browser, engine, N * 14 + 3_000);
        const short = await open(browser, engine, 800);
        expect(await tall.locator(LINE).count()).toBe(N);
        expect(await short.locator(LINE).count()).toBeLessThan(N / 2);
        // The text around the diff that the test expects left out is unselectable on the page.
        const marks = await short.evaluate(() =>
          [".feed-detail-toolbar button", ".feed-diff-name", ".feed-answer-row button", ".feed-detail-title"].map(
            (selector) => {
              const style = getComputedStyle(document.querySelector(selector)!);
              return style.userSelect || style.webkitUserSelect;
            },
          ),
        );
        expect(marks).toEqual(["none", "none", "none", "text"]);

        // Each selection, and the lines it crosses.
        const cases: Array<[string, (page: Page) => Promise<unknown>, number, number]> = [
          ["select-all", (page) => selectAll(page, engine), 0, N - 1],
          ["from the title into the lines", (page) => select(page, "title"), 0, 200],
          ["from the toolbar into the lines", (page) => select(page, "top"), 0, 200],
          ["from the lines to below them", (page) => select(page, "line"), 5, N - 1],
          ["from the lines to below them, backward", (page) => select(page, "line", true), 5, N - 1],
        ];
        /** How many of the lines from `first` to `last` are mounted. */
        const mountedOf = (page: Page, first: number, last: number) =>
          page.evaluate(
            ({ line, first, last }) =>
              [...document.querySelectorAll<HTMLElement>(line)].filter((row) => {
                const at = Number(row.dataset.index);
                return at >= first && at <= last;
              }).length,
            { line: LINE, first, last },
          );
        for (const [name, make, first, last] of cases) {
          await make(tall);
          const own = (await copied(tall, engine)).text;
          await make(short);
          const before = await ends(short);
          // The lines between the selection's ends are not all mounted: the page's own copy runs.
          expect(await mountedOf(short, first, last), name).toBeLessThan(last - first + 1);
          const { text: windowed, after } = await copied(short, engine);
          for (const label of UNSELECTABLE) expect(own.includes(label), `${name}: ${label}`).toBe(false);
          expect(own.includes("compute(150)"), name).toBe(true);
          expect(windowed.length, name).toBe(own.length);
          expect(windowed === own, name).toBe(true);
          // The copy reads the text around the lines through the selection and puts the person's back.
          expect(after, name).toEqual(before);
        }
      } finally {
        await browser.close();
      }
    });
});
