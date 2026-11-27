// cmux-web-test-timeout: 600
// A Harnesses row's message reads in full, beside or above its actions (first-run finding 6,
// Lawrence 2026-11-20: at the default window width "The network dropped. Check y…" and "Waiting for
// the network. The install goes on when you're …" were cut off). The row's detail line was one
// line with an ellipsis, and the network messages, with Retry and Setup guide beside them, did not
// fit. Measured in both of the lane's engines (WebKit is the app's) on the real page and its
// stylesheet cascade (the gallery's Harnesses entry), at the agent column of the default
// 1100 x 720 window (TestWindowPlacement.defaultSize; 437 px in the first-run VM shots), at the
// entry's narrow width and at 320 px, where the English message cannot fit beside two buttons in any
// font (the lane's Linux fonts are narrower than the app's), in English and in two languages with
// long (German) and wide (Japanese) text. A frame opened alone is as wide as its viewport (the
// gallery sizes its iframe), so the viewport is the pane.
//
// The German and Japanese stages must show German and Japanese: the message, the buttons and the
// page's language. The gallery had drawn every pane entry in English whatever its `locale`, so
// these cases had measured the English words three times (Lawrence 2026-11-21: "make the gallery
// switch the Harnesses page's language so the German and Japanese cases measure real translated text").
import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { readCatalog } from "../scripts/pages/catalog.mjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("harnesses-row-text.browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  // A WebKit that cannot launch here (no host libraries on a fleet worker) skips its test; on
  // GitHub Actions it fails the file (probeEngineOrSkip).
  const webkitRuns = await probeEngineOrSkip("harnesses-row-text.browser.test.ts", "webkit", webkit);

  const ENTRY = "agent-pane.harnesses";
  /** The agent column of the default window, the entry's narrow width, a narrow pane. */
  const WIDTHS = [437, 360, 320];
  const LOCALES = ["en", "de", "ja"];
  /** A message may wrap, but stays a sentence: no column of single words. */
  const MAX_LINES = 3;
  const CASES = [
    {
      variant: "install-network-dropped",
      key: "harnesses.install.networkDropped",
      labels: ["harnesses.retry", "harnesses.setupGuide"],
    },
    { variant: "install-waiting-network", key: "harnesses.install.waitingNetwork", labels: [] },
  ];
  /** How long a stage may take to show the row's message (the play installs once the page draws). */
  const SHOWN_MS = 20_000;

  type Localizations = Record<string, { stringUnit?: { value?: string } }>;
  const catalog = readCatalog(path.resolve(import.meta.dir, "../src/agent-session/acpmux/Localizable.xcstrings.d")) as {
    strings: Record<string, { localizations?: Localizations }>;
  };
  /** The words the row shows in `locale`, as the page's catalog has them. */
  const words = (key: string, locale: string) => {
    const value = catalog.strings[key]?.localizations?.[locale]?.stringUnit?.value;
    if (!value) throw new Error(`no ${locale} text for ${key}`);
    return value;
  };

  type Box = { left: number; right: number; top: number; bottom: number };
  type Row = {
    lang: string;
    text: string;
    scrollWidth: number;
    clientWidth: number;
    scrollHeight: number;
    clientHeight: number;
    lines: number;
    row: Box;
    detail: Box;
    actions: (Box & { label: string; scrollWidth: number; clientWidth: number })[];
  };

  const measure = (page: Page): Promise<Row> =>
    page.evaluate(() => {
      const row = document.querySelector('[data-harness-row="opencode"]')!;
      const detail = row.querySelector<HTMLElement>(".acpmux-harness-detail")!;
      const box = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
      };
      const lineHeight = parseFloat(getComputedStyle(detail).lineHeight);
      return {
        lang: document.documentElement.lang,
        text: detail.textContent ?? "",
        scrollWidth: detail.scrollWidth,
        clientWidth: detail.clientWidth,
        scrollHeight: detail.scrollHeight,
        clientHeight: detail.clientHeight,
        lines: Math.round(detail.getBoundingClientRect().height / lineHeight),
        row: box(row),
        detail: box(detail),
        actions: [...row.querySelectorAll<HTMLElement>("button")].map((button) => ({
          label: button.textContent ?? "",
          scrollWidth: button.scrollWidth,
          clientWidth: button.clientWidth,
          ...box(button),
        })),
      };
    });

  const overlaps = (a: Box, b: Box) =>
    a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;

  const run = async (engine: string, launch: () => Promise<Browser>) => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    const port = (vite.httpServer!.address() as { port: number }).port;
    const browser = await launch();
    const failures: string[] = [];
    try {
      await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: CASES[0]!.variant } });
      for (const { variant, key, labels } of CASES)
        for (const locale of LOCALES) {
          const shown = words(key, locale);
          const buttons = labels.map((label) => words(label, locale));
          const page = await browser.newPage({ viewport: { width: WIDTHS[0]!, height: 900 } });
          try {
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, locale })}`);
            await page.waitForFunction(
              (text) =>
                document.querySelector('[data-harness-row="opencode"] .acpmux-harness-detail')?.textContent === text,
              shown,
              { timeout: SHOWN_MS },
            );
            for (const width of WIDTHS) {
              const where = `${engine} ${variant} ${locale} ${width}px`;
              await page.setViewportSize({ width, height: 900 });
              // Two frames: the resize lays out, then paints.
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const row = await measure(page);
              if (row.lang !== locale) failures.push(`${where}: the page's language is ${JSON.stringify(row.lang)}`);
              if (JSON.stringify(row.actions.map((action) => action.label)) !== JSON.stringify(buttons))
                failures.push(
                  `${where}: the buttons read ${JSON.stringify(row.actions.map((action) => action.label))}, not ${JSON.stringify(buttons)}`,
                );
              if (row.scrollWidth > row.clientWidth + 1)
                failures.push(
                  `${where}: "${row.text}" is cut off (${row.scrollWidth} px of text in ${row.clientWidth} px)`,
                );
              if (row.scrollHeight > row.clientHeight + 1)
                failures.push(
                  `${where}: "${row.text}" is cut off below (${row.scrollHeight} px in ${row.clientHeight} px)`,
                );
              if (row.lines > MAX_LINES) failures.push(`${where}: "${row.text}" takes ${row.lines} lines`);
              for (const action of row.actions) {
                if (action.left < row.row.left - 0.5 || action.right > row.row.right + 0.5)
                  failures.push(`${where}: ${action.label} runs out of the row`);
                if (action.scrollWidth > action.clientWidth + 1) failures.push(`${where}: ${action.label} is cut off`);
                if (overlaps(action, row.detail)) failures.push(`${where}: ${action.label} covers the message`);
              }
            }
          } catch (error) {
            const text = await page
              .evaluate(
                () => document.querySelector('[data-harness-row="opencode"] .acpmux-harness-detail')?.textContent,
              )
              .catch(() => undefined);
            failures.push(
              `${engine} ${variant} ${locale}: ${String(error).split("\n")[0]} (the row says ${JSON.stringify(text)})`,
            );
          } finally {
            await page.close();
          }
        }
    } finally {
      await browser.close();
      await vite.close();
    }
    expect(failures).toEqual([]);
  };

  test("chromium: a harness row's network message reads in full, its actions in the row", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test.if(webkitRuns)("webkit: a harness row's network message reads in full, its actions in the row", () =>
    run("webkit", () => webkit.launch({ headless: true })),
  );
});
