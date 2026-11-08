// l10n-allow-file: browser fixture prompts, not shipped UI.
// A selection that holds a cmux link chip copies as the page's own text with each chip as its link
// (conversation/selectionCopy.ts; review of #38166, F1): a sent prompt keeps its line ends and its
// runs of spaces, which its bubble's `white-space: pre-wrap` lays out, and a selection of a chip's
// title alone copies its link (F3). Only a real layout shows the whitespace: jsdom has no innerText.
//
// Real Chromium from Playwright. Locally: CMUX_BROWSER_TESTS=1 bun test test/cmux-link-chip-copy-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cmux-link-chip-copy-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("cmux-link-chip-copy-browser", "chromium", chromium))) return;
  const WORKSPACE = "cmux-nightly://workspace/ws_16c92e4354fcaf05540386720d78e251";
  setDefaultTimeout(120_000);
  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    const bundle = await build({
      stdin: {
        contents:
          'import { chipSelectionText } from "./src/agent-session/acpmux/conversation/selectionCopy";\n' +
          "(window as unknown as Record<string, unknown>).chipSelectionText = chipSelectionText;",
        resolveDir: webviews,
        loader: "ts",
      },
      bundle: true,
      format: "iife",
      platform: "browser",
      write: false,
      logLevel: "silent",
    });
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage();
    // A sent prompt as UserBubble draws it: the bubble's pre-wrap, the typed text's span inside it.
    await page.setContent(
      `<!doctype html><body><div class="cv-user" style="white-space: pre-wrap; width: 600px">` +
        `<span class="cv-user__typed" id="typed">Line one\n\n  indented   twice <a data-cmux-link="workspace" href="${WORKSPACE}"><svg width="14" height="14" aria-hidden="true"></svg><span id="title">Retry fix</span></a>\nlast  line</span>` +
        `</div><p id="plain" style="white-space: pre-wrap">no   chip\nhere</p></body>`,
    );
    await page.addScriptTag({ content: bundle.outputFiles[0]!.text });
  });
  afterAll(async () => {
    await browser?.close();
  });

  /// The copy of a selection of `selector`'s contents (or of `title`'s text alone): what the page's
  /// own copy reads, and what chipSelectionText gives.
  const copyOf = (selector: string) =>
    page.evaluate((selector) => {
      const range = document.createRange();
      range.selectNodeContents(document.querySelector(selector)!);
      const selection = document.getSelection()!;
      selection.removeAllRanges();
      selection.addRange(range);
      const page = selection.toString();
      const chip = (window as unknown as { chipSelectionText(range: Range): string | null }).chipSelectionText(range);
      return {
        page,
        chip,
        kept: selection.rangeCount === 1 && selection.getRangeAt(0).toString() === range.toString(),
      };
    }, selector);

  test("a prompt's selection keeps its line ends and spaces, its chip as its link", async () => {
    const { page: own, chip, kept } = await copyOf("#typed");
    // The page's own copy, with the chip's title swapped for its link: nothing else changes.
    expect(own).toBe("Line one\n\n  indented   twice Retry fix\nlast  line");
    expect(chip).toBe(`Line one\n\n  indented   twice ${WORKSPACE}\nlast  line`);
    // The person's selection is theirs again after the copy.
    expect(kept).toBe(true);
  });

  test("a selection of the chip's title alone copies its link", async () => {
    const { chip } = await copyOf("#title");
    expect(chip).toBe(WORKSPACE);
  });

  test("a selection with no chip is the page's own copy", async () => {
    const { chip } = await copyOf("#plain");
    expect(chip).toBeNull();
  });
});
