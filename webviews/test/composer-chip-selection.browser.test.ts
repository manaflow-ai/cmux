// l10n-allow-file: browser fixture prompts, not shipped UI.
// A drag across a tool's badge in the composer (`@computer-use`) treats it as one character, as
// Codex does (Lucas, 2026-11-23/24: "when trying to select text it looks very weird", "the selection
// still doesn't work great and consistently"): a drag that ends on the badge's left half or out past
// it takes it whole, one that ends on its right half leaves it out, a press on it starts at its nearer
// end, and a drag from a selected badge never moves the draft (WebKit had taken it for a drag and
// drop). Real mouse drags in both of the lane's engines (WebKit is the app's), read back as the
// selection's offsets into the draft's text and the badge's selected mark.
// cmux-web-test-timeout: 600
import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-chip-selection.browser.test.ts", async () => {
  setDefaultTimeout(600_000);

  const ENTRY = "agent-pane.composer-chip-caret";
  const VARIANT = "tool-chip-selection";
  const DRAFT = "ask @computer-use now please";
  const WORD_FROM = "ask ".length;
  const WORD_TO = "ask @computer-use".length;
  const WIDTH = 900;

  /// The badge's box (its front and its title end drawn as one), the field's left, and the line's middle.
  const geometry = (page: Page) =>
    page.evaluate(() => {
      const parts = [...document.querySelectorAll(".acpmux-md .is-titled-start, .acpmux-md .is-titled[data-title]")];
      const rects = parts.flatMap((part) => [...part.getClientRects()]);
      const left = Math.min(...rects.map((rect) => rect.left));
      const right = Math.max(...rects.map((rect) => rect.right));
      const line = document.querySelector(".acpmux-md p")!.getBoundingClientRect();
      const field = document.querySelector(".acpmux-md")!.getBoundingClientRect();
      return { left, right, y: (line.top + line.bottom) / 2, fieldLeft: field.left, lineRight: line.right };
    });

  /// The selection's offsets into the draft's text, the text, and whether the badge is marked selected.
  const state = (page: Page) =>
    page.evaluate(() => {
      const element = document.querySelector(".acpmux-md-field") as HTMLElement & {
        acpmuxMarkdownField?: { text(): { value: string; selectionStart: number; selectionEnd: number } };
      };
      const { value, selectionStart, selectionEnd } = element.acpmuxMarkdownField!.text();
      const selected = document.querySelector(".acpmux-md .is-titled[data-title]")?.hasAttribute("data-selected");
      return {
        value,
        from: Math.min(selectionStart, selectionEnd),
        to: Math.max(selectionStart, selectionEnd),
        selected,
      };
    });

  /// The end of the draft's text: just inside the last letter, so the press lands on the line.
  const textEnd = async (page: Page) => {
    const end = await page.evaluate(() => {
      const range = document.createRange();
      const paragraph = document.querySelector(".acpmux-md p")!;
      range.selectNodeContents(paragraph);
      const rects = [...range.getClientRects()];
      return rects[rects.length - 1]!.right;
    });
    return end - 1;
  };

  const drag = async (page: Page, fromX: number, toX: number, y: number) => {
    await page.mouse.move(fromX, y);
    await page.mouse.down();
    await page.mouse.move(toX, y, { steps: 12 });
    await page.mouse.up();
  };

  const run = async (engine: "chromium" | "webkit", launch: () => Promise<Browser>) => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    const browser = await launch();
    const failures: string[] = [];
    try {
      await vite.listen();
      await warmGalleryFrame(vite, ENTRY, engine === "chromium" ? { browser } : {});
      const port = (vite.httpServer!.address() as { port: number }).port;
      const context = await browser.newContext({
        viewport: { width: WIDTH, height: 400 },
        colorScheme: "dark",
        deviceScaleFactor: 2,
      });
      const page = await context.newPage();
      try {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: WIDTH, frame: "component" })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        await page.waitForFunction(() => document.querySelectorAll(".acpmux-md .is-titled[data-title]").length === 1);
        const box = await geometry(page);
        const end = await textEnd(page);
        const leftHalf = box.left + (box.right - box.left) * 0.25;
        const rightHalf = box.left + (box.right - box.left) * 0.75;
        // Out past the field on the left, where the composer's + button stands.
        const outside = box.fieldLeft - 20;

        const cases: {
          name: string;
          from: number;
          to: number;
          want: { from: number; to: number; selected: boolean };
        }[] = [
          {
            name: "from the text's end out past the field",
            from: end,
            to: outside,
            want: { from: 0, to: DRAFT.length, selected: true },
          },
          {
            name: "from the text's end to the badge's left half",
            from: end,
            to: leftHalf,
            want: { from: WORD_FROM, to: DRAFT.length, selected: true },
          },
          {
            name: "from the text's end to the badge's right half",
            from: end,
            to: rightHalf,
            want: { from: WORD_TO, to: DRAFT.length, selected: false },
          },
          {
            name: "from the badge's right half out past the field",
            from: rightHalf,
            to: outside,
            want: { from: 0, to: WORD_TO, selected: true },
          },
          {
            name: "from the badge's left half to the text's end",
            from: leftHalf,
            to: end,
            want: { from: WORD_FROM, to: DRAFT.length, selected: true },
          },
          // The badge is selected from the case before: a drag from it selects, never moves the draft.
          {
            name: "from the selected badge's right half to the text's end",
            from: rightHalf,
            to: end,
            want: { from: WORD_TO, to: DRAFT.length, selected: false },
          },
        ];
        for (const each of cases) {
          await drag(page, each.from, each.to, box.y);
          await page
            .waitForFunction(
              ([from, to]) => {
                const element = document.querySelector(".acpmux-md-field") as HTMLElement & {
                  acpmuxMarkdownField?: { text(): { selectionStart: number; selectionEnd: number } };
                };
                const { selectionStart, selectionEnd } = element.acpmuxMarkdownField!.text();
                return Math.min(selectionStart, selectionEnd) === from && Math.max(selectionStart, selectionEnd) === to;
              },
              [each.want.from, each.want.to] as const,
              { timeout: 5_000 },
            )
            .catch(() => undefined);
          const seen = await state(page);
          if (seen.value !== DRAFT)
            failures.push(`${engine}, ${each.name}: the draft became ${JSON.stringify(seen.value)}`);
          if (seen.from !== each.want.from || seen.to !== each.want.to)
            failures.push(
              `${engine}, ${each.name}: selected ${seen.from}..${seen.to}, want ${each.want.from}..${each.want.to}`,
            );
          if (Boolean(seen.selected) !== each.want.selected)
            failures.push(`${engine}, ${each.name}: the badge is ${seen.selected ? "" : "not "}marked selected`);
        }
      } finally {
        await context.close();
      }
    } finally {
      await browser.close();
      await vite.close();
    }
    expect(failures).toEqual([]);
  };

  test("chromium: a drag across a tool's badge takes it as one character", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test("webkit: a drag across a tool's badge takes it as one character", () =>
    run("webkit", () => webkit.launch({ headless: true })));
});
