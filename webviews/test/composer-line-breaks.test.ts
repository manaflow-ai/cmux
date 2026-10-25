// cmux-web-test-timeout: 300
// Leo 2026-10-21: "HOW ARE WE MAKING LINE BREAKS THAT COPY OVER TO OTHER TEXT BOXES AS <br />?"
// Milkdown writes an empty paragraph as the markdown placeholder `<br />`, and its copy put that
// markdown on the clipboard as text/plain, so a prompt with a blank line pasted elsewhere (or back
// into the composer, where markup-looking plain text goes in as typed) showed a literal `<br />`.
// Copy puts the lines as plain text with `\n`; a paste takes the plain text (an HTML-only paste
// as its text, `<br>` and `<p>` as line breaks), never tags as text; the sent prompt and a copy
// of its transcript message hold the same lines.
//
// Real Chromium and WebKit (the app's engine) from Playwright; CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-line-breaks.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-line-breaks.test.ts", async () => {
  setDefaultTimeout(120_000);
  // Blank lines between paragraphs and single newlines inside one.
  const TEXT = "First paragraph\n\nSecond, line one\nSecond, line two\n\nThird";
  const LINES = TEXT.split("\n");
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      // GitHub Actions installs both engines (requireBrowserLane fails the file there first); a
      // fleet host without one runs the other.
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-line-breaks: cannot launch ${engine[0]}`);
      console.warn(`composer-line-breaks: skipping ${engine[0]} (cannot launch here)`);
    }
  }
  if (!engines.length) throw new Error("composer-line-breaks: no browser engine launches");

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const base = () => `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const FIELD = ".acpmux-composer-prompt [contenteditable='true']";

  async function newChat(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 700 } });
    await page.addInitScript(() => {
      // The async clipboard's writes, as the page made them (a copy button's text).
      const copied: string[] = [];
      Object.defineProperty(window, "__copied", { value: copied });
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: {
          writeText: async (text: string) => {
            copied.push(text);
          },
          readText: async () => copied.at(-1) ?? "",
        },
      });
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    await page.goto(base());
    await page.locator(FIELD).waitFor();
    await page.locator(FIELD).click();
    return page;
  }

  /// Dispatches a paste of `types` on the prompt, as the system clipboard would hand it over.
  const paste = (page: Page, types: Record<string, string>) =>
    page.evaluate(
      ({ field, types }) => {
        const target = document.querySelector<HTMLElement>(field)!;
        const data = new DataTransfer();
        for (const [type, value] of Object.entries(types)) data.setData(type, value);
        target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { field: FIELD, types },
    );

  /// What the prompt holds: its lines, its HTML, and its value as the agent would get it.
  const prompt = (page: Page) =>
    page.evaluate((field) => {
      const editable = document.querySelector<HTMLElement>(field)!;
      const handle = (editable.closest(".acpmux-md-field") as HTMLElement & { acpmuxMarkdownField?: any })
        .acpmuxMarkdownField!;
      return {
        plain: handle.plainText() as string,
        shown: editable.innerText,
        html: editable.innerHTML,
        agent: handle.agentText(handle.value()) as string,
      };
    }, FIELD);

  /// Selects the whole prompt and copies it: what the copy puts on the clipboard.
  const copyPrompt = (page: Page) =>
    page.evaluate((field) => {
      const editable = document.querySelector<HTMLElement>(field)!;
      const handle = (editable.closest(".acpmux-md-field") as HTMLElement & { acpmuxMarkdownField?: any })
        .acpmuxMarkdownField!;
      handle.focus();
      handle.selectAll();
      const data = new DataTransfer();
      editable.dispatchEvent(new ClipboardEvent("copy", { clipboardData: data, bubbles: true, cancelable: true }));
      return { plain: data.getData("text/plain"), html: data.getData("text/html") };
    }, FIELD);

  const expectLines = async (page: Page) => {
    await page.waitForFunction((field) => document.querySelector(field)?.textContent?.includes("Third"), FIELD);
    const seen = await prompt(page);
    expect(seen.plain).toBe(TEXT);
    expect(seen.plain).not.toContain("<br");
    expect(seen.shown).not.toContain("<br");
    expect(seen.agent).toBe(TEXT);
    // Every line shows on its own line, the blank ones too.
    expect(seen.shown.replace(/\n+$/, "").split("\n").filter(Boolean)).toEqual(LINES.filter(Boolean));
    return seen;
  };

  for (const [engine] of engines) {
    test(`${engine}: (a) a plain paste with blank lines shows its lines and sends them as they were`, async () => {
      const page = await newChat(engine);
      await paste(page, { "text/plain": TEXT });
      await expectLines(page);
      await page.keyboard.press("Enter");
      const bubble = page.locator(".cv-user__bubble", { hasText: "First paragraph" });
      await bubble.waitFor({ timeout: 15_000 });
      expect(await bubble.innerText()).not.toContain("<br");
      // (c) The transcript message's copy is the prompt's text with `\n`.
      const row = page.locator(".acpmux-row", { has: bubble });
      await row.hover();
      await row.locator('.cv-user__actions button[aria-label="Copy"]').click();
      await page.waitForFunction(() => ((window as unknown as { __copied: string[] }).__copied ?? []).length > 0);
      const copied = await page.evaluate(() => (window as unknown as { __copied: string[] }).__copied.at(-1)!);
      expect(copied).toBe(TEXT);
      expect(copied).not.toContain("<br");
      await page.close();
    });

    test(`${engine}: (b) a copy from the composer is the lines as plain text, a blank line too`, async () => {
      const page = await newChat(engine);
      await paste(page, { "text/plain": TEXT });
      await expectLines(page);
      const copied = await copyPrompt(page);
      expect(copied.plain).toBe(TEXT);
      expect(copied.plain).not.toContain("<br");
      // The HTML is a secondary type: real markup, never an escaped tag a plain paste would show.
      expect(copied.html).not.toContain("&lt;br");
      // Typed with Shift-Return, a blank line copies as one too.
      await page.evaluate((field) => {
        const handle = (document.querySelector(field)!.closest(".acpmux-md-field") as any).acpmuxMarkdownField;
        handle.reset("");
      }, FIELD);
      await page.locator(FIELD).click();
      await page.keyboard.type("one");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("two");
      const typed = await copyPrompt(page);
      expect(typed.plain).toBe("one\n\ntwo");
      expect((await prompt(page)).agent).not.toContain("<br");
      // And pasting that copy back gives the same lines, not a `<br />` line.
      await page.evaluate((field) => {
        const handle = (document.querySelector(field)!.closest(".acpmux-md-field") as any).acpmuxMarkdownField;
        handle.reset("");
      }, FIELD);
      await page.locator(FIELD).click();
      await paste(page, { "text/plain": copied.plain, "text/html": copied.html });
      await expectLines(page);
      await page.close();
    });

    test(`${engine}: (d) pasted HTML with <br /> and <p> is clean text, never tags`, async () => {
      const page = await newChat(engine);
      const html =
        "<meta charset='utf-8'><p>First paragraph</p><p><br /></p><p>Second, line one<br />Second, line two</p><p></p><p>Third</p>";
      // HTML alone: its text, each <br> and paragraph a line.
      await paste(page, { "text/html": html.replace("<p><br /></p>", "") });
      await page.waitForFunction((field) => document.querySelector(field)?.textContent?.includes("Third"), FIELD);
      let seen = await prompt(page);
      expect(seen.plain).not.toContain("<br");
      expect(seen.plain).not.toContain("<p");
      expect(seen.agent).not.toContain("<br");
      expect(seen.plain.split("\n").filter(Boolean)).toEqual(LINES.filter(Boolean));
      // HTML with plain text: the plain text, as it was.
      await page.evaluate((field) => {
        const handle = (document.querySelector(field)!.closest(".acpmux-md-field") as any).acpmuxMarkdownField;
        handle.reset("");
      }, FIELD);
      await page.locator(FIELD).click();
      await paste(page, { "text/html": html, "text/plain": TEXT });
      seen = await expectLines(page);
      // Markdown's empty-line placeholder in plain text (an older copy) is a blank line, not a tag.
      await page.evaluate((field) => {
        const handle = (document.querySelector(field)!.closest(".acpmux-md-field") as any).acpmuxMarkdownField;
        handle.reset("");
      }, FIELD);
      await page.locator(FIELD).click();
      await paste(page, { "text/plain": "one\n\n<br />\n\ntwo" });
      await page.waitForFunction((field) => document.querySelector(field)?.textContent?.includes("two"), FIELD);
      seen = await prompt(page);
      expect(seen.plain).toBe("one\n\ntwo");
      expect(seen.agent).not.toContain("<br");
      // Pasted source keeps its characters and lines: a `<br />` in code, and two blank lines.
      const source = "return <div>a<br />b</div>;\n\n\nnext";
      await page.evaluate((field) => {
        const handle = (document.querySelector(field)!.closest(".acpmux-md-field") as any).acpmuxMarkdownField;
        handle.reset("");
      }, FIELD);
      await page.locator(FIELD).click();
      await paste(page, { "text/plain": source });
      await page.waitForFunction((field) => document.querySelector(field)?.textContent?.includes("next"), FIELD);
      seen = await prompt(page);
      expect(seen.plain).toBe(source);
      await page.close();
    });
  }
});
