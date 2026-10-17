// cmux-web-test-timeout: 240
// Rich HTML/JSX paste must remain editable text. Milkdown's default HTML parser turns an
// unrecognized HTML fragment into a non-editable atom; clicking it and typing then replaces the
// whole pasted fragment.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-html-paste-edit.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      throw new Error(`composer-html-paste-edit: cannot launch ${engine[0]}`);
    }
  }

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

  async function newChat(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    await page.goto(base());
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").waitFor();
    return page;
  }

  for (const [engine] of engines)
    test(`${engine}: a pasted HTML fragment remains editable at the clicked text`, async () => {
      const page = await newChat(engine);
      const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
      await prompt.click();
      await page.evaluate(() => {
        const field = document.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable='true']")!;
        const data = new DataTransfer();
        data.setData("text/plain", "<div>\n  Hello\n</div>");
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      });
      await page.waitForFunction(() =>
        document.querySelector(".acpmux-composer-prompt [contenteditable='true']")?.textContent?.includes("Hello"),
      );
      const pasted = await prompt.innerText();
      expect(pasted).toContain("<div>");
      expect(pasted).toContain("Hello");
      const atom = prompt.locator("[contenteditable='false']").first();
      if (await atom.count()) await atom.click();
      else await prompt.click();
      await page.keyboard.type("X");
      const text = await prompt.innerText();
      expect(text).toContain("<div>");
      expect(text).toContain("Hello");
      expect(text).toContain("X");
      await page.close();
    });

  for (const [engine] of engines)
    test(`${engine}: inline JSX remains editable text`, async () => {
      const page = await newChat(engine);
      const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
      await prompt.click();
      await page.evaluate(() => {
        const field = document.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable='true']")!;
        const data = new DataTransfer();
        data.setData("text/plain", "const el = <><span>Hello</span></>;");
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      });
      await page.waitForFunction(() =>
        document.querySelector(".acpmux-composer-prompt [contenteditable='true']")?.textContent?.includes("Hello"),
      );
      expect(await prompt.locator("[contenteditable='false']").count()).toBe(0);
      await prompt.click();
      await page.keyboard.type("X");
      const text = await prompt.innerText();
      expect(text).toContain("const el =");
      expect(text).toContain("<>");
      expect(text).toContain("X");
      await page.close();
    });
});
