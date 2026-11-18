// l10n-allow-file: test fixtures.
// A New Tab suggestion row's title runs to the row's end before it truncates (user, CleanShot 8.07.33 PM:
// "Search the web for i have been trying to make new workspaces spawn at the top, but it alw…" stopped
// with a third of the row empty, while the Ask row above reached "Send ↵"). The title had
// `max-width: 60%` of the row, whatever the row had room for. Every row kind, narrow and wide.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-row-truncation.test.ts", async () => {
  const LONG =
    "i have been trying to make new workspaces spawn at the top, but it always lands at the bottom of the list, " +
    "below every pinned row, and then i have to drag it up again every single time i open one";
  setDefaultTimeout(120_000);
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
    await warmViteServer(vite, "/test/browser/new-tab-picker.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Each row whose title is cut: the room it leaves between its end and the row's end (the action, or
  /// the row's trailing padding).
  async function cutRows(width: number, text: string) {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width, height: 800 } });
    try {
      await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html?longSuggestions`);
      const editor = page.locator(".nt-field .ProseMirror");
      await editor.waitFor();
      await editor.focus();
      await page.keyboard.type(text);
      await page.waitForFunction(() => document.querySelectorAll('.nt-rows [role="option"]').length > 1);
      return await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>('.nt-rows [role="option"]')].flatMap((row) => {
          const title = row.querySelector<HTMLElement>(".nt-row-title");
          if (!title) return [];
          const box = row.getBoundingClientRect();
          const action = row.querySelector<HTMLElement>(".nt-row-action");
          const end = action
            ? action.getBoundingClientRect().left
            : box.right - parseFloat(getComputedStyle(row).paddingRight);
          return [
            {
              cut: title.scrollWidth > title.clientWidth + 1,
              title: title.textContent ?? "",
              left: Math.round(end - title.getBoundingClientRect().right),
              row: Math.round(box.width),
            },
          ];
        }),
      );
    } finally {
      await page.close();
    }
  }

  describe("New Tab suggestion rows", () => {
    for (const width of [520, 1400]) {
      test(`a long web search runs to the row's end before it truncates (${width}px)`, async () => {
        const rows = await cutRows(width, LONG);
        const search = rows.find((row) => row.title.startsWith("Search the web for"));
        expect(rows.map((row) => row.title.slice(0, 30))).toContainEqual(expect.stringMatching(/^Search the web for/));
        expect(search!.cut).toBe(true);
        // Two flex gaps at most (title to detail, detail to action): never a share of the row.
        expect(search!.left).toBeLessThanOrEqual(20);
      });

      test(`every row kind's long title runs to the row's end (${width}px)`, async () => {
        const rows = await cutRows(width, "workspaces");
        const cut = rows.filter((row) => row.cut);
        expect(cut.length).toBeGreaterThanOrEqual(2);
        for (const row of cut)
          expect({ title: row.title.slice(0, 40), left: row.left <= 20 }).toEqual({
            title: row.title.slice(0, 40),
            left: true,
          });
      });
    }
  });
});
