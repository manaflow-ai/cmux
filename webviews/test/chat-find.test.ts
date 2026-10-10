// Find in Chat on the real agent pane (src/agent-session/acpmux, `?mock`: the in-page mock daemon
// and its seeded worked turn), driven the way the app drives it: the `chat.find` page action that
// Find (Cmd-F) sends to an agent pane, then the bar's own keys.
// - the bar opens with the query and counts the transcript's matches;
// - the matches draw as custom highlights, with the current one apart;
// - Enter and Shift-Enter step through the matches, wrapping, and the current one scrolls into view;
// - Escape closes the bar and clears the highlights.
//
// Headless Chromium from Playwright; skipped where it is not installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-find.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  let installed = true;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    installed = false;
    console.warn("chat-find: skipping (run `bunx playwright install chromium`)");
  }

  let server: ChildProcess | null = null;
  let browser: Browser | null = null;
  let base = "";

  beforeAll(async () => {
    if (!installed) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(
      path.join(webviews, "node_modules/.bin/vp"),
      ["dev", "--config", "vite.config.acpmux-pane.mjs", "--port", String(port), "--strictPort"],
      { cwd: webviews, stdio: ["ignore", "pipe", "pipe"] },
    );
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    browser = await chromium.launch({ headless: true });
  }, 60_000);

  afterAll(async () => {
    await browser?.close();
    server?.kill();
  });

  /** The bar's count, the highlights drawn and the current match's text. */
  async function state(page: Page) {
    return page.evaluate(() => {
      const highlights = (CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights;
      const active = [...(highlights.get("acpmux-find-active") ?? [])];
      return {
        open: document.querySelector(".acpmux-find") !== null,
        count: document.querySelector(".acpmux-find__count")?.textContent ?? "",
        others: highlights.get("acpmux-find")?.size ?? 0,
        active: active.map((range) => range.toString()),
        // The current match is inside the transcript's viewport.
        inView: active.every((range) => {
          const box = range.getBoundingClientRect();
          const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          return box.top >= view.top && box.bottom <= view.bottom;
        }),
      };
    });
  }

  async function openChat(page: Page) {
    await page.goto(`${base}/?mock`);
    // The seeded worked turn's reply is drawn.
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-scroll [data-row-id]").length > 1, null, {
      timeout: 30_000,
    });
  }

  describe("Find in Chat", () => {
    test("chat.find opens the bar, counts and highlights matches, steps, and closes", async () => {
      if (!installed) return;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await openChat(page);
      const query = await page.evaluate(() => {
        // A word of the seeded transcript's text, so the counts below are the page's, not ours.
        const text = document.querySelector(".acpmux-scroll [data-row-id]")?.textContent ?? "";
        return (text.match(/[A-Za-z]{5,}/) ?? [""])[0];
      });
      expect(query).not.toBe("");

      const opened = await page.evaluate(
        (text) =>
          typeof window.cmuxAcpmuxActions?.["chat.find"] === "function"
            ? window.cmuxAcpmuxActions["chat.find"]({ text }).then(() => true)
            : false,
        query,
      );
      expect(opened).toBe(true);
      await page.waitForSelector(".acpmux-find__field");
      expect(await page.evaluate(() => (document.activeElement as HTMLInputElement | null)?.value)).toBe(query);

      const first = await state(page);
      const total = Number(/of (\d+)/.exec(first.count)?.[1] ?? 0);
      expect(first.count).toMatch(/^1 of \d+$/);
      expect(total).toBeGreaterThan(0);
      expect(first.active).toEqual([expect.stringMatching(new RegExp(`^${query}$`, "i"))]);

      // Enter steps forward; Shift-Enter steps back, wrapping past the first match.
      await page.keyboard.press("Enter");
      expect((await state(page)).count).toBe(`${Math.min(2, total)} of ${total}`);
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.press("Shift+Enter");
      const last = await state(page);
      expect(last.count).toBe(`${total} of ${total}`);
      expect(last.inView).toBe(true);

      // A query that is nowhere says so.
      await page.fill(".acpmux-find__field", "zzqqxxnotintranscript");
      const none = await state(page);
      expect(none.count).toBe("No results");
      expect(none.active).toEqual([]);
      expect(none.others).toBe(0);

      await page.keyboard.press("Escape");
      const closed = await state(page);
      expect(closed.open).toBe(false);
      expect(closed.active).toEqual([]);
      expect(closed.others).toBe(0);
      await page.close();
    });
  });
});
