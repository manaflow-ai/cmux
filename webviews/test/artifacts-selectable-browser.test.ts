// Artifact text is selectable and copyable like chat text: the chosen file's path, its text and a
// revision's change carry `.selectable` (shared/desktop.css), the way chat messages do, and the
// page's controls (the file tree's rows, a revision's button) stay unselectable. Only the diff lines
// near the viewport are mounted (DiffLines.tsx), so a copy across lines that are not mounted reads
// them from the model, and select-all, whose range ends in the block standing in for the lines below
// the window, copies the whole change: the same text the browser copies by itself when every line is
// mounted, at 10,000 lines.
//
// A production build of test/browser/artifacts-visible-only.html (the real Artifacts page over one
// file of N lines whose newest revision adds every line), as bench/artifacts-visible-only.bench.ts
// serves it.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/artifacts-selectable-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("artifacts-selectable-browser.test.ts", async () => {
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: Array<(typeof engines)[number]> = [];
  for (const engine of engines)
    if (await probeEngineOrSkip(`artifacts-selectable-browser ${engine[0]}`, engine[0], engine[1])) runs.push(engine);
  if (runs.length === 0) return;
  setDefaultTimeout(300_000);

  const PATH = "notes/big.md";
  const LINE = ".artifacts-line";
  const SCROLLER = ".artifacts-history";
  let served: BenchPage;
  beforeAll(async () => {
    // bun test sets NODE_ENV=test, and Vite would build React's development JSX into the page.
    const env = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/artifacts-visible-only.html", { dev: false });
    } finally {
      process.env.NODE_ENV = env;
    }
  });
  afterAll(async () => {
    await served?.close();
  });

  /** The page at `n` lines, and the file's text. */
  async function open(browser: Browser, engine: string, n: number, height = 800) {
    const context = await browser.newContext({ viewport: { width: 1200, height } });
    if (engine === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const page = await context.newPage();
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction((line) => window.benchReady === true && !!document.querySelector(line), LINE);
    const text = await page.evaluate(() => window.benchFileText);
    // The newest revision has no parent: its change adds every line of the file.
    const added = text
      .slice(0, -1)
      .split("\n")
      .map((line) => `+${line}`);
    return { page, text, added };
  }

  /** What the clipboard holds after a copy of the page's selection. */
  async function copied(page: Page, engine: string): Promise<string> {
    if (engine === "chromium") {
      await page.evaluate(() => navigator.clipboard.writeText(""));
      await page.keyboard.press("Control+c");
      return page.evaluate(() => navigator.clipboard.readText());
    }
    // WebKit headless gives no clipboard read: copy, then paste into a field of the page's own, and
    // put the selection back.
    await page.evaluate(() => {
      document.execCommand("copy");
      const selection = document.getSelection()!;
      // Its anchor and focus, so a backward selection stays backward.
      const kept = selection.anchorNode
        ? ([selection.anchorNode, selection.anchorOffset, selection.focusNode!, selection.focusOffset] as const)
        : null;
      (window as unknown as { keptEnds: typeof kept }).keptEnds = kept;
      const area = document.createElement("textarea");
      area.id = "paste-here";
      area.style.cssText = "position:fixed;top:0;left:0;width:10px;height:10px";
      document.body.append(area);
      area.focus();
    });
    await page.keyboard.press("Control+v");
    return page.evaluate(() => {
      const area = document.getElementById("paste-here") as HTMLTextAreaElement;
      const text = area.value;
      area.remove();
      const kept = (window as unknown as { keptEnds: [Node, number, Node, number] | null }).keptEnds;
      if (kept) document.getSelection()!.setBaseAndExtent(...kept);
      return text;
    });
  }

  /** Select-all, as Ctrl+A on the page (Chromium) or the Edit menu runs it (WebKit headless binds no
   *  key to it here). */
  async function selectAll(page: Page, engine: string) {
    if (engine === "chromium") {
      const box = (await page.locator(".artifacts-text").boundingBox())!;
      await page.mouse.click(box.x + box.width / 2, box.y + 10);
      await page.keyboard.press("Control+a");
    } else await page.evaluate(() => document.execCommand("selectAll"));
  }

  /** Drags the pointer from one point to another. */
  async function drag(page: Page, from: { x: number; y: number }, to: { x: number; y: number }) {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move(to.x, to.y, { steps: 8 });
    await page.mouse.up();
  }

  for (const [engine, type] of runs) {
    test(`${engine}: with every line mounted, the browser's own select-all copy is the path, the file and its change`, async () => {
      const browser = await type.launch({ headless: true });
      try {
        const { page, text, added } = await open(browser, engine, 4);
        expect(await page.locator(LINE).count()).toBe(4);
        await selectAll(page, engine);
        expect(await copied(page, engine)).toBe(`${PATH}\n${text}${added.join("\n")}`);
      } finally {
        await browser.close();
      }
    });

    test(`${engine}: at 10,000 lines, select-all copies the same text, at the top and after a scroll`, async () => {
      const browser = await type.launch({ headless: true });
      try {
        const { page, text, added } = await open(browser, engine, 10_000);
        expect(added.length).toBe(10_000);
        const whole = `${PATH}\n${text}${added.join("\n")}`;
        await selectAll(page, engine);
        const mounted = await page.locator(LINE).count();
        expect(mounted).toBeLessThan(400);
        const first = await copied(page, engine);
        expect(first.length).toBe(whole.length);
        expect(first === whole).toBe(true);
        // The copy reads the text above the diff through the selection and puts the person's back: the
        // same ends, and a backward selection (from below the window up to the path) stays backward.
        const ends = () =>
          page.evaluate(() => {
            const selection = document.getSelection()!;
            const name = (node: Node | null) =>
              node?.nodeType === 3 ? node.parentElement!.className : (node as HTMLElement | null)?.dataset?.gap;
            return [
              name(selection.anchorNode),
              selection.anchorOffset,
              name(selection.focusNode),
              selection.focusOffset,
            ];
          });
        const forward = await ends();
        await copied(page, engine);
        expect(await ends()).toEqual(forward);
        await page.evaluate(() => {
          const selection = document.getSelection()!;
          const range = selection.getRangeAt(0);
          selection.setBaseAndExtent(range.endContainer, range.endOffset, range.startContainer, range.startOffset);
        });
        const backward = await ends();
        expect(backward[0]).toBe(forward[2]);
        expect(await copied(page, engine)).toBe(whole);
        expect(await ends()).toEqual(backward);
        // A scroll of a few viewports mounts other lines; the selection and its copy stay whole.
        const before = await page.locator(LINE).first().getAttribute("data-index");
        await page.evaluate(
          (scroller) => (document.querySelector<HTMLElement>(scroller)!.scrollTop += 4_000),
          SCROLLER,
        );
        await page.waitForFunction(
          ({ line, before }) => document.querySelector<HTMLElement>(line)?.dataset.index !== before,
          { line: LINE, before },
        );
        const again = await copied(page, engine);
        expect(again.length).toBe(whole.length);
        expect(again === whole).toBe(true);
        // No line mounted for the copy, and no control's label in it.
        expect(await page.locator(LINE).count()).toBeLessThan(400);
        expect(again).not.toContain("Revision 0");
        // Scrolled to the change's last line: the block below the lines has no height left, and the
        // selection still ends in it.
        await page.evaluate((scroller) => {
          const pane = document.querySelector<HTMLElement>(scroller)!;
          pane.scrollTop = pane.scrollHeight;
        }, SCROLLER);
        await page.waitForFunction((line) => !!document.querySelector(`${line}[data-index="9999"]`), LINE);
        const last = await copied(page, engine);
        expect(last.length).toBe(whole.length);
        expect(last === whole).toBe(true);
      } finally {
        await browser.close();
      }
    });

    test(`${engine}: a selection from above the change copies what the browser copies with every line mounted`, async () => {
      const N = 300;
      const browser = await type.launch({ headless: true });
      try {
        // Tall enough that every line mounts (the browser copies by itself), and the usual height.
        const tall = await open(browser, engine, N, N * 14 + 2_000);
        const short = await open(browser, engine, N);
        expect(await tall.page.locator(LINE).count()).toBe(N);
        expect(await short.page.locator(LINE).count()).toBeLessThan(N / 2);
        // From the chosen revision's label (above the change, not selectable: a script sets it) to
        // "Revision " (the next revision's, below it), or to "+const " in line 200.
        const select = (page: Page, into: boolean) =>
          page.evaluate(
            async ({ into, line }) => {
              const pane = document.querySelector<HTMLElement>(".artifacts-history")!;
              const row = async (index: number) => {
                for (let tries = 0; tries < 60; tries++) {
                  const found = document.querySelector<HTMLElement>(`${line}[data-index="${index}"]`);
                  if (found) return found;
                  pane.scrollTop += 300;
                  // raf-read: waits for the window to mount the lines a scroll brings in; it reads the DOM, not paint.
                  await new Promise((resolve) => requestAnimationFrame(resolve));
                }
                throw new Error(`line ${index} never mounted`);
              };
              const commits = document.querySelectorAll(".artifacts-commit");
              const trailers = commits[0]!.querySelector(".artifacts-trailers")!.firstChild!;
              const message = commits[1]!.querySelector(".artifacts-commit-message")!.firstChild!;
              const range = document.createRange();
              range.setStart(trailers, trailers.textContent!.indexOf(" "));
              if (into) range.setEnd((await row(200)).childNodes[1]!, 6);
              else range.setEnd(message, message.textContent!.indexOf(" ") + 1);
              const selection = document.getSelection()!;
              selection.removeAllRanges();
              selection.addRange(range);
            },
            { into, line: LINE },
          );
        for (const into of [false, true]) {
          await select(tall.page, into);
          const own = await copied(tall.page, engine);
          await select(short.page, into);
          const windowed = await copied(short.page, engine);
          expect(own.startsWith("+const line0")).toBe(true);
          expect(windowed.length).toBe(own.length);
          expect(windowed === own).toBe(true);
        }
      } finally {
        await browser.close();
      }
    });

    test(`${engine}: a drag in the file's text and in the change copies what it covers, across lines not mounted`, async () => {
      const browser = await type.launch({ headless: true });
      try {
        const { page, added } = await open(browser, engine, 10_000);
        // The file's text: from inside its second line to inside its fourth.
        const pre = (await page.locator(".artifacts-text").boundingBox())!;
        await drag(page, { x: pre.x + 40, y: pre.y + 30 }, { x: pre.x + 80, y: pre.y + 70 });
        const inFile = await page.evaluate(() => document.getSelection()!.toString());
        expect(inFile.split("\n").length).toBeGreaterThanOrEqual(2);
        expect(await copied(page, engine)).toBe(inFile);

        // The change: a drag from line 3 to line 8, then Shift-click on a line thousands below.
        await page.locator(LINE).nth(3).scrollIntoViewIfNeeded();
        const top = (await page.locator(LINE).nth(3).boundingBox())!;
        const bottom = (await page.locator(LINE).nth(8).boundingBox())!;
        await drag(
          page,
          { x: top.x + 60, y: top.y + top.height / 2 },
          { x: bottom.x + 90, y: bottom.y + bottom.height / 2 },
        );
        await page.evaluate(
          (scroller) => (document.querySelector<HTMLElement>(scroller)!.scrollTop += 70_000),
          SCROLLER,
        );
        await page.waitForFunction(
          (line) => Number(document.querySelectorAll<HTMLElement>(line)[2]?.dataset.index) > 4_000,
          LINE,
        );
        // A line in the middle of the history pane's visible part (not one in the overscan around it).
        const pane = (await page.locator(SCROLLER).boundingBox())!;
        await page.keyboard.down("Shift");
        await page.mouse.click(top.x + 50, pane.y + pane.height / 2);
        await page.keyboard.up("Shift");
        // Where the selection starts and ends, each as a line and a character of its row's text.
        const ends = await page.evaluate(() => {
          const selection = document.getSelection()!;
          const at = (node: Node, offset: number) => {
            const row = (node.nodeType === 1 ? (node as Element) : node.parentElement)!.closest<HTMLElement>(
              "[data-line]",
            )!;
            const before = document.createRange();
            before.setStart(row, 0);
            before.setEnd(node, offset);
            return { line: Number(row.dataset.index), char: before.toString().length };
          };
          return [at(selection.anchorNode!, selection.anchorOffset), at(selection.focusNode!, selection.focusOffset)];
        });
        const [from, to] = ends as [{ line: number; char: number }, { line: number; char: number }];
        expect(from.line).toBe(3);
        expect(to.line).toBeGreaterThan(4_000);
        const expected = [
          added[from.line]!.slice(from.char),
          ...added.slice(from.line + 1, to.line),
          added[to.line]!.slice(0, to.char),
        ].join("\n");
        const text = await copied(page, engine);
        expect(text.length).toBe(expected.length);
        expect(text === expected).toBe(true);
      } finally {
        await browser.close();
      }
    });

    test(`${engine}: a control's label cannot be selected`, async () => {
      const browser = await type.launch({ headless: true });
      try {
        const { page } = await open(browser, engine, 1_000);
        for (const control of [".artifacts-commit-button >> nth=1", ".artifacts-row >> nth=0"]) {
          await page.evaluate(() => document.getSelection()!.removeAllRanges());
          const box = (await page.locator(control).boundingBox())!;
          await drag(
            page,
            { x: box.x + 4, y: box.y + box.height / 2 },
            { x: box.x + box.width - 4, y: box.y + box.height / 2 },
          );
          expect(await page.evaluate(() => document.getSelection()!.toString())).toBe("");
        }
        // The text is marked as chat text is; the controls are not.
        const marks = await page.evaluate(() =>
          [".artifacts-path", ".artifacts-text", ".artifacts-line", ".artifacts-commit-button", ".artifacts-row"].map(
            (selector) => {
              const style = getComputedStyle(document.querySelector(selector)!);
              return style.userSelect || style.webkitUserSelect;
            },
          ),
        );
        expect(marks.slice(0, 3)).toEqual(["text", "text", "text"]);
        expect(marks.slice(3)).toEqual(["none", "none"]);
      } finally {
        await browser.close();
      }
    });
  }
});
