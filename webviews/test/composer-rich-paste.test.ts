// cmux-web-test-timeout: 240
// l10n-allow-file: test fixtures.
// A paste into the composer draws its lists, headings and code as the blocks typing makes (Leo,
// 2026-11-05: "we don't even render bullet points properly in our thing when we're pasting that stuff
// in"): Markdown copied from Claude or ChatGPT, and HTML from Notes, Docs, Slack or a web page. Prose
// and code without those blocks still go in as their lines, and Paste as Plain Text stays plain.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-rich-paste.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-rich-paste: cannot launch ${engine[0]}`);
      console.warn(`composer-rich-paste: skipping ${engine[0]} (cannot launch here)`);
    }
  }
  if (!engines.length) throw new Error("composer-rich-paste: no browser engine launches");

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
          // A message's Copy writes its Markdown and HTML together (richClipboard.ts).
          write: async (items: ClipboardItem[]) => {
            copied.push(await (await items[0]!.getType("text/plain")).text());
            Object.assign(window, { __copiedHtml: await (await items[0]!.getType("text/html")).text() });
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

  /// The prompt's blocks, by tag and text.
  const blocks = (page: Page) =>
    page.evaluate(
      (field) =>
        [
          ...document
            .querySelector<HTMLElement>(field)!
            .querySelectorAll(":scope > p, ul > li, ol > li, h1, h2, h3, pre"),
        ].map((node) => `${node.tagName}:${(node.textContent ?? "").trim()}`),
      FIELD,
    );
  const settled = (page: Page, text: string) =>
    page.waitForFunction(({ field, text }) => document.querySelector(field)?.textContent?.includes(text), {
      field: FIELD,
      text,
    });

  for (const [engine] of engines) {
    test(`${engine}: Markdown copied from a chat pastes as a list, its lines kept`, async () => {
      const page = await newChat(engine);
      await paste(page, { "text/plain": "Two steps:\nfirst this\n\n- one\n- **two**\n\n1. alpha\n2. beta" });
      await settled(page, "beta");
      const shown = await blocks(page);
      expect(shown).toContain("LI:one");
      expect(shown).toContain("LI:two");
      expect(shown).toContain("LI:beta");
      expect(await page.locator(`${FIELD} ul`).count()).toBe(1);
      expect(await page.locator(`${FIELD} ol`).count()).toBe(1);
      expect(await page.locator(`${FIELD} strong`).innerText()).toBe("two");
      const seen = await prompt(page);
      // The intro's two lines stay two lines, as a plain paste's do.
      expect(seen.plain.split("\n").slice(0, 2)).toEqual(["Two steps:", "first this"]);
      expect(seen.agent).toContain("- one\n- **two**");
      expect(seen.agent).toContain("1. alpha\n2. beta");
      await page.close();
    });

    test(`${engine}: HTML from Notes or a web page pastes as its heading, list and code block`, async () => {
      const page = await newChat(engine);
      await paste(page, {
        "text/html":
          "<meta charset='utf-8'><h2 style='color:white'>Plan</h2><ul class='ul1'><li><b>ship</b></li><li>a_b</li></ul><pre><code class='language-ts'>const a = 1;</code></pre>",
        "text/plain": "Plan\nship\na_b\nconst a = 1;",
      });
      await settled(page, "const a");
      const shown = await blocks(page);
      expect(shown).toContain("H2:Plan");
      expect(shown).toContain("LI:ship");
      // Text's own Markdown characters stay text.
      expect(shown).toContain("LI:a_b");
      expect(shown).toContain("PRE:const a = 1;");
      await page.close();
    });

    test(`${engine}: Paste as Plain Text keeps a list's Markdown as typed lines`, async () => {
      const page = await newChat(engine);
      await page.locator(FIELD).press("Meta+Shift+V");
      // The menu's Paste as Plain Text goes through the host, so its paste can come late: the field
      // keeps it plain for the composer's whole window (pastedChips.ts PLAIN_PASTE_MS).
      // fixed-wait: the time since ⌘⇧V is the behavior here (a late paste, past the old 1 s window).
      await page.waitForTimeout(1500);
      await paste(page, { "text/plain": "- one\n- two" });
      await settled(page, "two");
      expect(await page.locator(`${FIELD} li`).count()).toBe(0);
      expect((await prompt(page)).plain).toBe("- one\n- two");
      // The next ordinary paste is rich again.
      await paste(page, { "text/plain": "\n- three\n- four" });
      await settled(page, "four");
      expect(await page.locator(`${FIELD} li`).count()).toBe(2);
      await page.close();
    });

    test(`${engine}: a message's Copy writes its Markdown and HTML, and that paste comes back as a list`, async () => {
      const page = await newChat(engine);
      await paste(page, { "text/plain": "- one\n- two" });
      await settled(page, "two");
      await page.keyboard.press("Enter");
      const bubble = page.locator(".cv-user__bubble", { hasText: "one" });
      await bubble.waitFor({ timeout: 15_000 });
      const row = page.locator(".acpmux-row", { has: bubble });
      await row.hover();
      await row.locator('.cv-user__actions button[aria-label="Copy"]').click();
      await page.waitForFunction(() => ((window as unknown as { __copied: string[] }).__copied ?? []).length > 0);
      const copied = await page.evaluate(() => ({
        plain: (window as unknown as { __copied: string[] }).__copied.at(-1)!,
        html: (window as unknown as { __copiedHtml: string }).__copiedHtml,
      }));
      expect(copied.plain).toBe("- one\n- two");
      expect(copied.html).toMatch(/<ul>\s*<li>one<\/li>\s*<li>two<\/li>\s*<\/ul>/);
      await page.locator(FIELD).click();
      await paste(page, { "text/plain": copied.plain, "text/html": copied.html });
      await settled(page, "two");
      expect(await blocks(page)).toEqual(["LI:one", "LI:two"]);
      await page.close();
    });

    test(`${engine}: a copied message with a picture keeps its image Markdown, as before`, async () => {
      const page = await newChat(engine);
      const source = "- before\n\n![chart](https://example.com/chart.png)\n\n- after";
      await paste(page, {
        "text/plain": source,
        "text/html":
          "<ul><li>before</li></ul><p><img src='https://example.com/chart.png' alt='chart'></p><ul><li>after</li></ul>",
      });
      await settled(page, "after");
      expect((await prompt(page)).plain).toContain("![chart](https://example.com/chart.png)");
      await page.close();
    });

    test(`${engine}: prose and a script with a # comment still paste as their lines`, async () => {
      const page = await newChat(engine);
      const source = "# install\nbrew install cmux\n\nthen run it";
      await paste(page, { "text/plain": source });
      await settled(page, "run it");
      expect(await page.locator(`${FIELD} h1`).count()).toBe(0);
      expect((await prompt(page)).plain).toBe(source);
      await page.close();
    });
  }
});
