// Keys typed right after Cmd-N all land in the New Tab field (cx-kql5h; nxdog93: "hello world 123"
// arrived as "ello world 123" and " world 123"). The page renders again while a new tab opens (a
// snapshot, the catalog, the window taking focus), and each render handed the screen a new
// readiness callback, which ran its open-time focus again: it selected what was typed, and the next
// key replaced it. The field keeps every key, whatever renders between them, on both screens.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

await requireBrowserLane("new-tab-typing.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-typing: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab typing", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/new-tab-typing.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("shell typing keeps Markdown punctuation literal and restores formatting when shell mode ends", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage();
    try {
      await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-typing.html`);
      const editor = page.locator(".nt-field .ProseMirror");
      await editor.focus();
      // Real keyboard input exercises CommonMark's input rules; handle.type() only parses a value.
      await page.keyboard.type("!");
      await page.locator(".nt-shell-glyph").waitFor();
      const command = "echo _x_ __y__ **z** `date` [a](b)";
      await page.keyboard.type(command);
      await page.keyboard.press("Control+b");
      await page.keyboard.type(" more");
      await page.keyboard.press("Enter");
      expect(await page.evaluate(() => window.newTabShellCommands)).toEqual([`${command} more`]);
      expect(await editor.locator("em, strong, code, a").count()).toBe(0);
      await page.keyboard.press("Escape");
      await page.keyboard.press("Control+a");
      await page.keyboard.type("**normal prompt**");
      // Leaving shell mode restores normal prompt formatting.
      expect(await editor.locator("strong").textContent()).toBe("normal prompt");
    } finally {
      await page.close();
    }
  });

  for (const screen of ["default", "classic"]) {
    test(`the ${screen} New Tab field keeps every key while the page renders between them`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-typing.html?screen=${screen}`);
      const classic = screen === "classic";
      const field = page.locator(classic ? "input.acpmux-newtab-field" : ".nt-field");
      await field.first().waitFor();
      // The default field is the composer's Markdown field (#26567): its contenteditable takes the keys.
      await page.waitForFunction((classic) => {
        const active = document.activeElement;
        return classic
          ? active instanceof HTMLInputElement
          : active instanceof HTMLElement && active.isContentEditable && !!active.closest(".nt-field");
      }, classic);
      // A key at a time, with the page rendering again before each, as the bead's keys came.
      for (const key of "hello world 123") {
        await page.evaluate(() => window.rerenderHost?.());
        await page.keyboard.type(key);
      }
      await page.evaluate(() => window.rerenderHost?.());
      const typed = classic
        ? await field.first().inputValue()
        : await page.evaluate(() =>
            document.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField?.value(),
          );
      expect(typed).toBe("hello world 123");
      await page.close();
    });
  }
});
