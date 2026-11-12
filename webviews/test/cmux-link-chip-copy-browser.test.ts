// l10n-allow-file: browser fixture prompts and replies, not shipped UI.
// A selection that holds a cmux link chip copies as the page's own text with each chip as its link
// (conversation/chipCopy.ts; review of #38166): a sent prompt keeps its line ends and its runs of
// spaces, which its bubble's `white-space: pre-wrap` lays out; a selection of a chip's title alone
// copies its link; and a chip copies as its link beside every other copy path: a code block (plain,
// or highlighted in a shadow root) keeps its indentation, an equation its TeX (mathCopy.ts), a table
// its cells; the text a quote or the message menu reads has the link too. Each mixed copy is the
// page's own copy of the same selection (read before the transcript's copy listeners are installed)
// with the chip's title as its link. Only a real layout shows the whitespace (jsdom has no innerText).
//
// Real Chromium from Playwright, its clipboard read on a localhost page.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/cmux-link-chip-copy-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserContext, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cmux-link-chip-copy-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("cmux-link-chip-copy-browser", "chromium", chromium))) return;
  const webkitRuns = await probeEngineOrSkip("cmux-link-chip-copy-browser webkit", "webkit", webkit);
  setDefaultTimeout(120_000);
  const WORKSPACE = "cmux-nightly://workspace/ws_16c92e4354fcaf05540386720d78e251";
  const TITLE = "Retry fix";
  const chip = `<a data-cmux-link="workspace" href="${WORKSPACE}"><svg width="14" height="14" aria-hidden="true"></svg><span class="cv-cmux-link__title">${TITLE}</span></a>`;
  const ORIGIN = "http://localhost:4173";
  // The transcript's shapes: a sent prompt (UserBubble), replies (`.cv-md`) with a plain code block,
  // a highlighted one (Pierre's lines in a shadow root), an equation (Math.tsx) and a table.
  const PAGE =
    `<!doctype html><body>` +
    `<div class="cv-user" style="white-space: pre-wrap; width: 600px"><span class="cv-user__typed" id="typed">Line one\n\n  indented   twice ${chip}\nlast  line</span></div>` +
    `<p id="plain" style="white-space: pre-wrap">no   chip\nhere</p>` +
    `<div class="cv-md" id="code"><p>See ${chip} now</p><div class="cv-codeblock"><pre>  if (a) {\n    b();\n  }</pre></div><p>done</p></div>` +
    `<div class="cv-md" id="shadow"><p>See ${chip} now</p><div class="cv-codeblock"><div class="cv-codeblock__body" id="host"></div></div><p>done</p></div>` +
    `<div class="cv-md" id="math"><p>See ${chip} and <span class="cv-math" data-tex="x^2"><span aria-hidden="true">x²</span></span> here</p></div>` +
    `<div id="across"><div class="cv-md"><p>Open ${chip} first</p></div><div class="cv-md"><p>Then <span class="cv-math" data-tex="y^2"><span aria-hidden="true">y²</span></span> after</p></div></div>` +
    `<div class="cv-md" id="table"><table><tbody><tr><td>Where</td><td>${chip}</td></tr><tr><td>Then</td><td>ship  it</td></tr></tbody></table></div>` +
    `<script>document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<pre><div data-line>  x = 1;</div><div data-line>    y = 2;</div></pre>';</script>` +
    `</body>`;
  let browser: Browser;
  let context: BrowserContext;
  let page: Page;
  let handlers: string;
  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    const bundle = await build({
      stdin: {
        contents: [
          'import { chipSelectionText, installSelectionCopy } from "./src/agent-session/acpmux/conversation/selectionCopy";',
          'import { installMathCopy } from "./src/agent-session/acpmux/conversation/mathCopy";',
          'import { selectionText } from "./src/agent-session/acpmux/conversation/chipCopy";',
          "Object.assign(window, { chipSelectionText, installSelectionCopy, installMathCopy, selectionText });",
        ].join("\n"),
        resolveDir: webviews,
        loader: "ts",
      },
      bundle: true,
      format: "iife",
      platform: "browser",
      write: false,
      logLevel: "silent",
    });
    handlers = bundle.outputFiles[0]!.text;
    browser = await chromium.launch({ headless: true });
    context = await browser.newContext();
    await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: ORIGIN });
    page = await context.newPage();
    await page.route(`${ORIGIN}/`, (route) => route.fulfill({ contentType: "text/html", body: PAGE }));
    await page.goto(`${ORIGIN}/`);
    await page.addScriptTag({ content: handlers });
  });
  afterAll(async () => {
    await browser?.close();
  });

  type Api = {
    chipSelectionText(range: Range): string | null;
    selectionText(selection: Selection): string;
    installSelectionCopy(): void;
    installMathCopy(): void;
  };

  /// Selects `selector`'s contents (or, with `title`, the chip title's text alone in it).
  const select = (selector: string, title = false) =>
    page.evaluate(
      ({ selector, title }) => {
        const range = document.createRange();
        const root = document.querySelector(selector)!;
        range.selectNodeContents(title ? root.querySelector(".cv-cmux-link__title")!.firstChild! : root);
        const selection = document.getSelection()!;
        selection.removeAllRanges();
        selection.addRange(range);
      },
      { selector, title },
    );

  /// What Cmd-C puts on the clipboard for the selection of `selector`.
  const copied = async (selector: string) => {
    await select(selector);
    await page.evaluate(() => navigator.clipboard.writeText(""));
    await page.keyboard.press("Control+c");
    return page.evaluate(() => navigator.clipboard.readText());
  };

  // The page's own copy of each selection, before the transcript's listeners exist: what base gave
  // with the chip's title where its link was.
  const own = new Map<string, string>();
  test("the page's own copy, before the transcript's copy listeners", async () => {
    for (const selector of ["#typed", "#code", "#shadow", "#across", "#table tbody"])
      own.set(selector, await copied(selector));
    expect(own.get("#code")).toContain("  if (a) {\n    b();\n  }");
    expect(own.get("#shadow")).toContain("  x = 1;\n    y = 2;");
    await page.evaluate(() => {
      const api = window as unknown as Api;
      api.installSelectionCopy();
      api.installMathCopy();
    });
  });

  const asLink = (text: string) => text.replace(TITLE, WORKSPACE);

  test("a prompt's selection keeps its line ends and spaces, its chip as its link", async () => {
    expect(await copied("#typed")).toBe(`Line one\n\n  indented   twice ${WORKSPACE}\nlast  line`);
    expect(await copied("#typed")).toBe(asLink(own.get("#typed")!));
    // The person's selection is theirs again after the copy.
    const kept = await page.evaluate(() => document.getSelection()!.getRangeAt(0).toString());
    expect(kept).toContain(TITLE);
  });

  test("a selection of the chip's title alone copies its link", async () => {
    await select("#typed", true);
    const text = await page.evaluate(() =>
      (window as unknown as Api).chipSelectionText(document.getSelection()!.getRangeAt(0)),
    );
    expect(text).toBe(WORKSPACE);
  });

  test("a selection with no chip is the page's own copy", async () => {
    await select("#plain");
    const text = await page.evaluate(() =>
      (window as unknown as Api).chipSelectionText(document.getSelection()!.getRangeAt(0)),
    );
    expect(text).toBeNull();
  });

  test("a chip and a code block: the code keeps its whitespace, the chip is its link", async () => {
    const text = await copied("#code");
    expect(text).toBe(asLink(own.get("#code")!));
    expect(text).toContain(WORKSPACE);
    expect(text).toContain("  if (a) {\n    b();\n  }");
  });

  test("a chip and highlighted code (a shadow root): its lines and the chip's link", async () => {
    const text = await copied("#shadow");
    expect(text).toBe(asLink(own.get("#shadow")!));
    expect(text).toContain("  x = 1;\n    y = 2;");
  });

  test("a chip and an equation: the TeX and the chip's link", async () => {
    const text = await copied("#math");
    expect(text).toBe(`See ${WORKSPACE} and $x^2$ here`);
  });

  test("across messages, a chip and an equation: the chip's link, the math as the page copies it", async () => {
    // mathCopy.ts declines a selection across replies; the chip still copies as its link.
    const text = await copied("#across");
    expect(text).toContain(WORKSPACE);
    expect(text).not.toContain(TITLE);
    expect(text).toBe(asLink(own.get("#across")!));
  });

  test("reading a backward selection over a chip keeps it backward", async () => {
    // As selectionReplyTarget reads it before checking the direction: the anchor stays after the focus.
    const [anchor, focus] = await page.evaluate(() => {
      const typed = document.getElementById("typed")!;
      const selection = document.getSelection()!;
      const last = typed.lastChild!;
      selection.setBaseAndExtent(last, 3, typed.firstChild!, 2);
      (window as unknown as Api).selectionText(selection);
      const at = (node: Node | null, offset: number) => {
        const range = document.createRange();
        range.setStart(node!, offset);
        return range;
      };
      const anchorAt = at(selection.anchorNode, selection.anchorOffset);
      const focusAt = at(selection.focusNode, selection.focusOffset);
      return [
        [selection.anchorNode === last, selection.anchorOffset],
        [
          selection.focusNode === typed.firstChild,
          selection.focusOffset,
          anchorAt.compareBoundaryPoints(Range.START_TO_START, focusAt),
        ],
      ];
    });
    expect(anchor).toEqual([true, 3]);
    expect(focus).toEqual([true, 2, 1]);
  });

  test("a chip in a table: the cells as the page copies them, the chip as its link", async () => {
    const text = await copied("#table tbody");
    expect(text).toBe(asLink(own.get("#table tbody")!));
    expect(text).toContain(WORKSPACE);
    expect(text).toContain("ship");
  });

  test("a whole table with a chip: the reply's Markdown table, the chip as its link", async () => {
    expect(await copied("#table")).toBe(`| Where | ${WORKSPACE} |\n| --- | --- |\n| Then | ship it |`);
  });

  test("the text a quote or the message menu reads has the chip's link, and reading it twice is the same", async () => {
    await select("#code");
    const [first, second, kept] = await page.evaluate(() => {
      const api = window as unknown as Api;
      const selection = document.getSelection()!;
      return [api.selectionText(selection), api.selectionText(selection), selection.toString()];
    });
    expect(first).toContain(WORKSPACE);
    expect(first).toContain("  if (a) {\n    b();\n  }");
    expect(second).toBe(first);
    expect(kept).toContain(TITLE);
  });

  // The app's engine: WebKit reads a highlighted block only through a selection inside its shadow
  // root, and calls that selection collapsed; its clipboard is not readable headless, so this reads
  // chipText's answer, which the copy puts on the clipboard.
  if (webkitRuns)
    test("WebKit: a chip with plain and highlighted code reads the code's lines and the link", async () => {
      const other = await webkit.launch({ headless: true });
      try {
        const wk = await other.newPage();
        await wk.setContent(PAGE);
        await wk.addScriptTag({ content: handlers });
        for (const [selector, code] of [
          ["#code", "  if (a) {\n    b();\n  }"],
          ["#shadow", "  x = 1;\n    y = 2;"],
        ] as const) {
          const text = await wk.evaluate((selector) => {
            const range = document.createRange();
            range.selectNodeContents(document.querySelector(selector)!);
            return (window as unknown as Api).chipSelectionText(range);
          }, selector);
          expect(text).toContain(`See ${WORKSPACE} now`);
          expect(text).toContain(code);
          expect(text).not.toContain(TITLE);
        }
      } finally {
        await other.close();
      }
    });
});
