// l10n-allow-file: clipboard fixture messages.
// Real browser copy events, including a highlighted code card whose shadow DOM is not cloned.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-markdown-copy-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("transcript-markdown-copy-browser", "chromium", chromium))) return;
  setDefaultTimeout(120_000);
  const origin = "http://localhost:4173";
  let browser: Browser;
  let page: Page;

  beforeAll(async () => {
    const bundle = await build({
      stdin: {
        contents: [
          'import { installSelectionCopy } from "./src/agent-session/acpmux/conversation/selectionCopy";',
          'import { menuPartRef } from "./src/agent-session/acpmux/conversation/menuParts";',
          'menuPartRef({ code: "if ready:\\n    run()\\n", codeLanguage: "python" })(document.getElementById("code"));',
          'document.getElementById("highlight").attachShadow({mode:"open"}).innerHTML = "<pre>if ready:\\n    run()</pre>";',
          "installSelectionCopy();",
        ].join("\n"),
        resolveDir: path.resolve(import.meta.dir, ".."),
        loader: "ts",
      },
      bundle: true,
      format: "iife",
      platform: "browser",
      write: false,
      logLevel: "silent",
    });
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin });
    page = await context.newPage();
    await page.route(`${origin}/`, (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><main>
        <article><div class="cv-md"><h2 id="first">Start here</h2><p>One</p></div><button class="cv-iconbtn">Copy message</button></article>
        <article><div class="cv-user__text"><div class="cv-md"><ul><li>Keep lists</li><li>And <strong>bold</strong></li></ul></div></div><time>10:30 AM</time></article>
        <article><div class="cv-md"><div id="code" class="cv-codeblock"><header>Python <button>Copy code</button></header><div id="highlight"></div></div><p id="last">Finish here</p></div></article>
        </main>`,
      }),
    );
    await page.goto(`${origin}/`);
    await page.addScriptTag({ content: bundle.outputFiles[0]!.text });
  });

  afterAll(async () => {
    await browser?.close();
  });

  test("copy across three messages pastes headings, lists and fenced code as Markdown", async () => {
    await page.evaluate(() => {
      const selection = document.getSelection()!;
      selection.setBaseAndExtent(
        document.getElementById("first")!.firstChild!,
        0,
        document.getElementById("last")!.firstChild!,
        11,
      );
    });
    await page.keyboard.press("ControlOrMeta+c");
    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toBe(
      "## Start here\n\nOne\n\n- Keep lists\n- And **bold**\n\n```python\nif ready:\n    run()\n```\n\nFinish here",
    );
  });

  test("backward selection clips both ends without changing the range", async () => {
    const before = await page.evaluate(() => {
      const selection = document.getSelection()!;
      selection.setBaseAndExtent(
        document.getElementById("last")!.firstChild!,
        6,
        document.getElementById("first")!.firstChild!,
        6,
      );
      return { anchor: selection.anchorOffset, focus: selection.focusOffset };
    });
    await page.keyboard.press("ControlOrMeta+c");
    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toStartWith("## here\n\n");
    expect(text).toEndWith("\n\nFinish");
    expect(
      await page.evaluate(() => ({
        anchor: document.getSelection()!.anchorOffset,
        focus: document.getSelection()!.focusOffset,
      })),
    ).toEqual(before);
  });
});
