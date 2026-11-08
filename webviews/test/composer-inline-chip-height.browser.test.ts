// A pasted image in the prompt's text is a small chip as tall as the line, so the composer keeps its
// one-line height and only typed text grows it (https://github.com/manaflow-ai/cmux/issues/38135: a
// pasted image drew a thumbnail two control rows tall and the composer grew well above one line).
// Measured on the real layout, in both of the lane's engines (WebKit is the app's), at both
// densities and the interface sizes: a one-line draft with a screenshot in it, two screenshots side
// by side, a file still loading in its tile, and saved files' name chips beside a video, each stays
// one text line tall.
// cmux-web-test-timeout: 600
import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-chip-height.browser.test.ts", async () => {
  setDefaultTimeout(600_000);

  const ENTRY = "agent-pane.composer";
  const SIZES: Record<string, Record<string, string | number>> = {
    default: {},
    compact: { density: "compact" },
    "interface-0.9": { interfaceScale: 0.9 },
    "interface-1.25": { interfaceScale: 1.25 },
    "zoom-1.5": { scale: 1.5 },
  };
  /// Each draft and the chips it waits for: a screenshot pasted mid-sentence, two pasted at the end,
  /// a pasted file whose upload never finishes (its loading tile stays in the text), and a zip and a
  /// notes file saved by the host (their name chips) beside a video's tile. `count`: how many of
  /// `ready` the draft shows once it is ready. `oneLine`: the draft fits one line at every size; the
  /// saved files' long names may wrap in a narrow composer, onto whole lines of text.
  const CASES: { variant: string; ready: string; count: number; oneLine: boolean }[] = [
    { variant: "attachment-inline-caret", ready: ".acpmux-md [data-inline-attachment] img", count: 1, oneLine: true },
    {
      variant: "attachment-inline-reorder",
      ready: ".acpmux-md [data-inline-attachment] img",
      count: 2,
      oneLine: true,
    },
    {
      variant: "attachment-loading",
      ready: ".acpmux-md .acpmux-md-inline-chip[data-state='loading'] .acpmux-md-inline-spinner",
      count: 1,
      oneLine: true,
    },
    {
      variant: "file-saved-as-path",
      ready: ".acpmux-md :is(.acpmux-attachment-link[data-saved], .acpmux-attachment-video)",
      count: 3,
      oneLine: false,
    },
  ];
  /// Sub-pixel rounding of the line box at fractional interface sizes.
  const TOLERANCE = 0.5;

  /// The prompt's line height as drawn, the height of its first paragraph, and each chip's box. The
  /// line is measured on a box one line tall beside the editor, in the same zoom: a computed
  /// `line-height` does not carry a zoom, the boxes do.
  const measure = (page: Page) =>
    page.evaluate(() => {
      const prompt = document.querySelector<HTMLElement>(".acpmux-md")!;
      const paragraph = prompt.querySelector<HTMLElement>("p") ?? prompt;
      const probe = document.createElement("div");
      probe.style.height = "var(--text-content--line-height)";
      prompt.parentElement!.append(probe);
      const lineHeight = probe.getBoundingClientRect().height;
      probe.remove();
      const chips = [...prompt.querySelectorAll<HTMLElement>("[data-inline-attachment]")].map((node) => {
        const box = node.getBoundingClientRect();
        return { height: box.height, kind: node.querySelector("img") ? "image" : "tile" };
      });
      return { lineHeight, paragraph: paragraph.getBoundingClientRect().height, chips };
    });

  const run = async (engine: "chromium" | "webkit", launch: () => Promise<Browser>) => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    const browser = await launch();
    const failures: string[] = [];
    const report: string[] = [];
    try {
      await vite.listen();
      await warmGalleryFrame(vite, ENTRY, engine === "chromium" ? { browser } : {});
      const port = (vite.httpServer!.address() as { port: number }).port;
      for (const [name, size] of Object.entries(SIZES)) {
        const context = await browser.newContext({
          viewport: { width: 1400, height: 760 },
          colorScheme: "dark",
          deviceScaleFactor: 2,
        });
        const page = await context.newPage();
        try {
          for (const { variant, ready, count, oneLine } of CASES) {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1400, frame: "component", ...size })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
              timeout: 90_000,
            });
            await page.waitForFunction(
              ([selector, n]) => document.querySelectorAll(selector as string).length >= (n as number),
              [ready, count] as const,
            );
            await page.waitForFunction(() =>
              [...document.querySelectorAll<HTMLImageElement>(".acpmux-md [data-inline-attachment] img")].every(
                (img) => img.complete,
              ),
            );
            const seen = await measure(page);
            report.push(`${engine} ${name} ${variant}: ${JSON.stringify(seen)}`);
            const where = `${engine} ${name} ${variant}`;
            // A line height that does not read as a size would pass every comparison below.
            expect(seen.lineHeight).toBeGreaterThan(10);
            if (!seen.chips.length) failures.push(`${where}: no chip in the text`);
            // The draft is lines of text with its chips: one line tall, or (a draft that wraps) a whole
            // number of the text's lines, never a line raised by a chip.
            const lines = Math.max(1, Math.round(seen.paragraph / seen.lineHeight));
            if ((oneLine && lines !== 1) || Math.abs(seen.paragraph - lines * seen.lineHeight) > TOLERANCE * lines)
              failures.push(
                `${where}: the draft is ${seen.paragraph.toFixed(2)}px tall, not ${oneLine ? "one" : "a whole number of"} ${seen.lineHeight.toFixed(2)}px line${oneLine ? "" : "s"}`,
              );
            for (const chip of seen.chips)
              if (chip.height > seen.lineHeight + TOLERANCE)
                failures.push(
                  `${where}: a ${chip.kind} chip is ${chip.height.toFixed(2)}px tall, past the ${seen.lineHeight.toFixed(2)}px line`,
                );
          }
        } finally {
          await context.close();
        }
      }
    } finally {
      console.log(report.join("\n"));
      await browser.close();
      await vite.close();
    }
    expect(failures).toEqual([]);
  };

  test("chromium: a pasted image keeps the composer one line tall", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test("webkit: a pasted image keeps the composer one line tall", () =>
    run("webkit", () => webkit.launch({ headless: true })));
});
