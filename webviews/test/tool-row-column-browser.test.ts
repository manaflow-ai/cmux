// Tool rows share one column (Leo, 2026-10-31: "WHY IS THERE PRETOOLUSE", "WHY IS IT ALGINED SO
// [...] SHIT", "WHY IS IT RENDERED SO SHIT", "why are these indented for no reason"): a commands
// group holding a call a hook blocked, one that failed and one that went on in the background,
// beside lone rows. Every row's glyph and words start at the same x, a line under a row starts at
// its words, a verb is followed by one space, a hook's block reads "blocked by hook" with no
// "PreToolUse" until it is opened, and no status word is cut. All displayed content is synthetic.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("tool-row-column-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/tool-row-column.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["dark", "light"] as const)
    for (const width of [760, 420] as const) {
      test(`${theme} ${width}px: tool rows share one glyph and text column, and a hook's block reads plainly`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 700 }, deviceScaleFactor: 2 });
        try {
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}/test/browser/tool-row-column.html?theme=${theme}&width=${width}`);
          await page.locator(".cv-steps .cv-tool").nth(2).waitFor();
          await page.evaluate(() => document.fonts.ready);
          const m = await page.evaluate(() => {
            const column = document.querySelector("[data-fixture-column]")!.getBoundingClientRect();
            const rows = [...document.querySelectorAll<HTMLElement>("[data-fixture-column] .cv-tool")].map((row) => {
              const icon = row.querySelector(".cv-tool__icon")!.getBoundingClientRect();
              const words = row.querySelector(".cv-tool__text, .cv-command__text")!;
              // The words' first glyph: a range over the first text, so a span's padding never counts.
              const walker = document.createTreeWalker(words, NodeFilter.SHOW_TEXT);
              let first = walker.nextNode();
              while (first && !first.textContent!.trim()) first = walker.nextNode();
              const range = document.createRange();
              range.setStart(first!, first!.textContent!.search(/\S/));
              range.setEnd(first!, first!.textContent!.search(/\S/) + 1);
              const box = row.getBoundingClientRect();
              const status = row.querySelector(".cv-command__failed, .cv-tool__failed");
              const statusBox = status?.getBoundingClientRect();
              return {
                text: row.textContent,
                iconLeft: icon.left - column.left,
                textLeft: range.getBoundingClientRect().left - column.left,
                right: box.right - column.right,
                status: status?.textContent?.trim(),
                statusClipped: statusBox ? statusBox.right > box.right + 0.5 || statusBox.width < 1 : false,
                wordsClipped: (() => {
                  const statusParent = status?.closest(".cv-tool__text, .cv-command__text");
                  return statusParent
                    ? statusParent.scrollWidth > statusParent.clientWidth + 0.5 &&
                        status!.getBoundingClientRect().right > statusParent.getBoundingClientRect().right + 0.5
                    : false;
                })(),
              };
            });
            // "Ran <command>": the command starts one space after the verb, never in a wide column.
            const verbGaps = [...document.querySelectorAll<HTMLElement>(".cv-command__text")].flatMap((words) => {
              const code = words.querySelector(".cv-command__line");
              if (!code) return [];
              const walker = document.createTreeWalker(words, NodeFilter.SHOW_TEXT);
              const verb = walker.nextNode()!;
              const range = document.createRange();
              range.selectNodeContents(verb);
              const ran = verb.textContent!.trimEnd();
              range.setEnd(verb, ran.length);
              return [code.getBoundingClientRect().left - range.getBoundingClientRect().right];
            });
            // A line under a row (a failure's cause) starts at the row's words.
            const under = [...document.querySelectorAll<HTMLElement>("[data-fixture-column] .cv-tool-error")].map(
              (line) =>
                line.getBoundingClientRect().left + parseFloat(getComputedStyle(line).paddingLeft) - column.left,
            );
            return {
              rows,
              verbGaps,
              under,
              columnText: document.querySelector("[data-fixture-column]")!.textContent ?? "",
            };
          });
          console.log(`TOOL_ROW_COLUMN ${JSON.stringify({ theme, width, ...m })}`);
          expect(errors).toEqual([]);
          // The lone read, the group line, its three steps, the lone failed command, the lone block.
          expect(m.rows.length).toBe(7);
          const icon = m.rows[0]!.iconLeft;
          const text = m.rows[0]!.textLeft;
          for (const row of m.rows) {
            expect(Math.abs(row.iconLeft - icon), `icon x: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(Math.abs(row.textLeft - text), `text x: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(row.right, `right edge: ${row.text}`).toBeLessThanOrEqual(0.5);
            expect(row.statusClipped, `status cut: ${row.text}`).toBe(false);
            expect(row.wordsClipped, `status cut in its words: ${row.text}`).toBe(false);
          }
          // A hook's block: its plain status on the row, no "PreToolUse" and no line of its words.
          expect(m.columnText).not.toContain("PreToolUse");
          expect(m.columnText).not.toContain("fixture guard");
          expect(m.rows.filter((row) => row.status === "blocked by hook").length).toBe(2);
          // The failed calls keep their word, and the lone one its cause at the words' x.
          expect(m.rows.some((row) => row.status === "Exit 1")).toBe(true);
          expect(m.under.length).toBeGreaterThan(0);
          for (const left of m.under) expect(Math.abs(left - text)).toBeLessThanOrEqual(0.5);
          expect(m.verbGaps.length).toBeGreaterThan(0);
          for (const gap of m.verbGaps) {
            expect(gap).toBeGreaterThan(0);
            expect(gap).toBeLessThan(8);
          }
          // Opened, the blocked call shows the hook's words as its output, without the envelope.
          await page.locator('[data-tool-id="blocked-lone"]').click();
          await page.locator(".cv-shell, pre").first().waitFor();
          const opened = await page.evaluate(() => document.querySelector("[data-fixture-column]")!.textContent ?? "");
          expect(opened).toContain("the fixture guard needs a passing review");
          expect(opened).not.toContain("PreToolUse");
          expect(opened).not.toContain("hook error");
        } finally {
          await page.close();
        }
      });
    }
});
