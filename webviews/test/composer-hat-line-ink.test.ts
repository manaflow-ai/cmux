// l10n-allow-file: gallery fixture names are test data.
// The composer hat's one-line header, opened over fourteen subagents and six background commands (Leo,
// 2026-11-27, ask-b6fc7a81c2: "dont put this garish blue in man we dont need it to be blue or
// highlighted ... overlapping text here what do we doooo"). Hovered or open, its words took the link
// accent on a filled chip; and its panel button sat one chevron column in from the row's end, a column
// the line header does not have, so it covered the deck's "+N more".
//
// Real Chromium (Playwright), the gallery's `agent-pane.composer-hat-line-deck` `trail-twenty-open`, at
// 360px and 900px: the open header's words are neither the accent nor the link colour and have no fill,
// hovered or not; and the panel button's box meets neither the words nor the deck's "+N more".
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-line-ink.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.composer-hat-line-deck";
  const VARIANT = "trail-twenty-open";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: VARIANT } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (width: number, widthName: string, scheme: "light" | "dark"): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width, height: 420 }, deviceScaleFactor: 2, colorScheme: scheme });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: widthName })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    const head = page.locator(".acpmux-running-tray[data-line] > .acpmux-running-tray__head");
    await head.waitFor();
    if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
    await page.waitForSelector(".acpmux-running-tray[data-line] > .acpmux-running-tray__open");
    await page.waitForSelector(".acpmux-hat-deck__rest");
    return page;
  };

  /** The words' colour and fill, the accent and link colours resolved on the same tray, and the boxes. */
  const read = (page: Page) =>
    page.evaluate(() => {
      const tray = document.querySelector<HTMLElement>(".acpmux-running-tray[data-line]")!;
      const title = tray.querySelector<HTMLElement>(":scope > .acpmux-running-tray__head > .acpmux-running-tray__title")!;
      const resolve = (value: string) => {
        const probe = document.createElement("span");
        probe.style.color = value;
        tray.append(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color;
      };
      const box = (node: Element | null) => {
        if (!node) return null;
        const rect = node.getBoundingClientRect();
        return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
      };
      const style = getComputedStyle(title);
      return {
        expanded: tray.querySelector(":scope > .acpmux-running-tray__head")!.getAttribute("aria-expanded"),
        color: style.color,
        background: style.backgroundColor,
        accent: resolve("var(--agent-accent)"),
        link: resolve("var(--agent-link, var(--agent-accent))"),
        text: resolve("var(--agent-text)"),
        rest: tray.querySelector(".acpmux-hat-deck__rest")?.textContent ?? null,
        boxes: {
          button: box(tray.querySelector(":scope > .acpmux-running-tray__open")),
          title: box(title.querySelector(".acpmux-summary-text") ?? title),
          rest: box(tray.querySelector(".acpmux-hat-deck__rest")),
          lastMark: box(tray.querySelector(".acpmux-hat-deck__mark:last-of-type")),
          head: box(tray.querySelector(":scope > .acpmux-running-tray__head")),
        },
      };
    });

  type Box = { left: number; right: number; top: number; bottom: number };
  const meets = (a: Box, b: Box) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;

  for (const scheme of ["light", "dark"] as const)
    for (const [width, widthName] of [
      [360, "narrow"],
      [900, "wide"],
    ] as const)
      test(`${scheme}, ${width}px: open, the words are ink with no chip, and the panel button clears "+N more"`, async () => {
        const page = await open(width, widthName, scheme);
        try {
          for (const hovered of [false, true]) {
            if (hovered) await page.hover(".acpmux-running-tray[data-line] > .acpmux-running-tray__head");
            const seen = await read(page);
            const report = `${hovered ? "hovered" : "open"}: ${JSON.stringify(seen)}`;
            expect(seen.expanded, report).toBe("true");
            expect(seen.rest, report).toMatch(/^\+\d+ more$/);
            // Where the theme's accent is the text colour itself (dark), ink and accent cannot differ.
            if (seen.accent !== seen.text) expect(seen.color, report).not.toBe(seen.accent);
            expect(seen.color, report).not.toBe(seen.link);
            expect(seen.color, report).toBe(seen.text);
            expect(seen.background, report).toBe("rgba(0, 0, 0, 0)");
            const { button, title, rest, head } = seen.boxes;
            expect(button, report).not.toBeNull();
            expect(meets(button!, rest!), `panel button over "+N more": ${report}`).toBe(false);
            expect(meets(button!, title!), `panel button over the words: ${report}`).toBe(false);
            // The button sits at the row's end, inside the header's box.
            expect(button!.right, report).toBeLessThanOrEqual(head!.right + 0.5);
            expect(rest!.right, report).toBeLessThanOrEqual(button!.left + 0.5);
          }
        } finally {
          await page.close();
        }
      });
});
