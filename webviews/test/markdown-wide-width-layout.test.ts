// The markdown viewer's text width on a big screen (user 2026-10-19: "text width to be much more
// flexible in case people want a super super wide text width (like they have a super big monitor)
// but they don't want it to be actually full width") and its code size ("code blocks' font size
// looks too big"). The real markdown page (gallery entry pages.markdown, variant wide-table) in a
// very wide viewport:
//
// - a chosen width is the column's width while the pane is wider, centered with equal margins;
// - a width wider than the pane fits the pane (no sideways page scroll), and wide tables and code
//   still scroll sideways in their own box;
// - only full width fills the pane;
// - code blocks and inline code are 85-90% of the body text, at the default and at a smaller body.
//
// The settings arrive as the page's settings stylesheet does (applyMarkdownLook: `:root` values).
// The app draws the page in WebKit; Chromium runs too. An engine that is not installed is skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-wide-width-layout.test.ts", async () => {
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
      console.warn(`markdown-wide-width-layout: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("markdown wide width", () => test("no engine", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
    await warmGalleryFrame(vite, "pages.markdown", {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: "wide-table" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, width: number): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 700 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 1; ; attempt++) {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.markdown", { variant: "wide-table" })}`);
      try {
        await page.waitForSelector(".md-prose .tableWrapper table td", { timeout: 60_000 });
        await page.waitForSelector(".md-prose .md-code pre code", { timeout: 60_000 });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };

  /** Sets `:root` values the way the settings stylesheet does. */
  const settings = (page: Page, css: string) =>
    page.evaluate((text) => {
      let style = document.getElementById("test-settings");
      if (!style) {
        style = document.createElement("style");
        style.id = "test-settings";
        document.head.append(style);
      }
      style.textContent = `:root { ${text} }`;
    }, css);

  /** The column's content box against the pane, and one character of the body font. */
  const layout = (page: Page) =>
    page.evaluate(() => {
      const doc = document.querySelector<HTMLElement>(".md-doc")!;
      const pane = document.querySelector<HTMLElement>(".md-scroll")!;
      const style = getComputedStyle(doc);
      // The CSS `ch` unit itself (a run of "0" glyphs can kern differently on some fonts).
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;width:100ch";
      doc.append(probe);
      const ch = probe.getBoundingClientRect().width / 100;
      probe.remove();
      const rect = doc.getBoundingClientRect();
      const paneRect = pane.getBoundingClientRect();
      return {
        ch,
        content: rect.width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
        padding: parseFloat(style.paddingLeft),
        left: rect.left - paneRect.left,
        right: paneRect.left + pane.clientWidth - rect.right,
        paneWidth: pane.clientWidth,
        pageScrollWidth: pane.scrollWidth,
        table: { client: document.querySelector<HTMLElement>(".md-prose .tableWrapper")!.clientWidth },
      };
    });

  /** Font sizes of the body, a code block and inline code, in CSS pixels. */
  const codeSizes = (page: Page) =>
    page.evaluate(() => {
      const prose = document.querySelector<HTMLElement>(".md-prose")!;
      let inline = prose.querySelector<HTMLElement>("p code");
      if (!inline) {
        const p = document.createElement("p");
        inline = document.createElement("code");
        inline.textContent = "x";
        p.append("text ", inline);
        prose.append(p);
      }
      const size = (element: Element) => parseFloat(getComputedStyle(element).fontSize);
      return {
        body: size(document.querySelector(".md-doc")!),
        paragraph: size(inline.parentElement!),
        block: size(document.querySelector(".md-prose .md-code pre code")!),
        inline: size(inline),
      };
    });

  for (const [engine] of engines)
    describe(`markdown wide width (${engine})`, () => {
      test("a 200ch column on a 3000px pane is 200ch wide and centered", async () => {
        const page = await open(engine, 3000);
        await settings(page, "--cmux-md-content-width: 200ch;");
        const box = await layout(page);
        expect(Math.abs(box.content - 200 * box.ch)).toBeLessThan(2);
        expect(box.content).toBeLessThan(box.paneWidth - 200);
        expect(Math.abs(box.left - box.right)).toBeLessThan(2);
        await page.close();
      });

      test("the default column keeps its reading width on a huge pane", async () => {
        const page = await open(engine, 3000);
        const box = await layout(page);
        expect(Math.abs(box.content - 72 * box.ch)).toBeLessThan(2);
        await page.close();
      });

      test("a width wider than the pane fits the pane, never scrolls the page sideways", async () => {
        const page = await open(engine, 1400);
        await settings(page, "--cmux-md-content-width: 1000ch;");
        const box = await layout(page);
        expect(box.content).toBeLessThanOrEqual(box.paneWidth - 2 * box.padding + 1);
        expect(box.pageScrollWidth).toBeLessThanOrEqual(box.paneWidth + 1);
        // The wide table still has its own sideways scroller inside the column.
        expect(box.table.client).toBeLessThanOrEqual(box.content + 1);
        await page.close();
      });

      test("only full width fills the pane", async () => {
        const page = await open(engine, 3000);
        await settings(page, "--cmux-md-content-width: 1000ch;");
        const wide = await layout(page);
        await settings(page, "--cmux-md-content-width: none;");
        const full = await layout(page);
        expect(Math.abs(full.content - (full.paneWidth - 2 * full.padding))).toBeLessThan(2);
        // 1000ch on 3000px fits the pane too, so the two match here; a 200ch column (about 1960px) does not.
        expect(Math.abs(wide.content - full.content)).toBeLessThan(2);
        await settings(page, "--cmux-md-content-width: 200ch;");
        const ultra = await layout(page);
        expect(ultra.content).toBeLessThan(full.content - 100);
        await page.close();
      });

      test("the Aa popover: a typed width and the preset menu change the column, and the popover stays open", async () => {
        // 300ch is about 3,050px at 16px: the pane is wider, so the column is exactly 300ch.
        const page = await open(engine, 4000);
        await page.click(".md-reading-button");
        const input = page.locator(".md-width-input");
        await input.waitFor();
        await input.fill("300");
        await input.press("Enter");
        // The typed width reaches the column; one that never does fails below.
        await page
          .waitForFunction(
            () => {
              const doc = document.querySelector<HTMLElement>(".md-doc")!;
              const style = getComputedStyle(doc);
              const probe = document.createElement("div");
              probe.style.cssText = "position:absolute;visibility:hidden;width:100ch";
              doc.append(probe);
              const ch = probe.getBoundingClientRect().width / 100;
              probe.remove();
              const content =
                doc.getBoundingClientRect().width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
              return Math.abs(content - 300 * ch) < 2;
            },
            null,
            { timeout: 5_000 },
          )
          .catch(() => {});
        let box = await layout(page);
        expect(Math.abs(box.content - 300 * box.ch)).toBeLessThan(2);
        expect(await input.inputValue()).toBe("300");
        expect(await page.locator(".md-width-presets").textContent()).toContain("Ultra Wide");
        // Out of range: the field shows the nearest end.
        await input.fill("99999");
        await input.press("Enter");
        expect(await input.inputValue()).toBe("1000");
        await page.click(".md-width-presets button");
        await page.getByRole("menuitemradio", { name: "Full Width" }).click();
        // The menu stays in the page until its exit animation ends (Base UI): past 100 ms on a loaded
        // WebKit runner, where a read at a fixed 100 ms still found its six items.
        await page.locator("[role=menuitemradio]").first().waitFor({ state: "detached" });
        box = await layout(page);
        expect(Math.abs(box.content - (box.paneWidth - 2 * box.padding))).toBeLessThan(2);
        expect(await page.locator(".md-width-input").count()).toBe(1);
        // A pick closes the preset menu (and only the menu: the popover stays).
        expect(await page.locator("[role=menuitemradio]").count()).toBe(0);
        await page.click(".md-width-presets button");
        await page.getByRole("menuitemradio", { name: "Comfortable" }).click();
        await page.locator("[role=menuitemradio]").first().waitFor({ state: "detached" });
        box = await layout(page);
        expect(Math.abs(box.content - 72 * box.ch)).toBeLessThan(2);
        await page.close();
      });

      // User 2026-10-31: "the markdown viewer can't expand?" A wide table was held to the 72ch
      // reading column on a wide pane, with half the pane empty beside it.
      test("a wide table uses the pane past the reading column, starting where the text starts", async () => {
        const page = await open(engine, 1800);
        const box = await page.evaluate(() => {
          const doc = document.querySelector<HTMLElement>(".md-doc")!;
          const pane = document.querySelector<HTMLElement>(".md-scroll")!;
          const prose = document.querySelector<HTMLElement>(".md-prose")!.getBoundingClientRect();
          const wrapper = document.querySelector<HTMLElement>(".md-prose .tableWrapper")!;
          const table = wrapper.querySelector("table")!.getBoundingClientRect();
          return {
            textLeft: prose.left,
            textRight: prose.right,
            tableLeft: table.left,
            boxRight: wrapper.getBoundingClientRect().right,
            paneRight: pane.getBoundingClientRect().left + pane.clientWidth,
            padding: parseFloat(getComputedStyle(doc).paddingLeft),
            pageScrollWidth: pane.scrollWidth,
            paneWidth: pane.clientWidth,
          };
        });
        expect(Math.abs(box.tableLeft - box.textLeft)).toBeLessThan(2);
        expect(box.boxRight).toBeGreaterThan(box.textRight + 100);
        expect(Math.abs(box.boxRight - (box.paneRight - box.padding))).toBeLessThan(2);
        expect(box.pageScrollWidth).toBeLessThanOrEqual(box.paneWidth + 1);
        await page.close();
      });

      // User 2026-10-31: faint text from behind the window read through the markdown viewer. Over a
      // see-through window the page background is transparent (`--cmux-surface-background`); the
      // viewer paints the theme's opaque surface (`--cmux-surface-solid`) instead.
      test("over a see-through window the page paints the opaque surface", async () => {
        const page = await open(engine, 1200);
        const background = await page.evaluate(() => {
          const root = document.documentElement;
          // The app's theme bootstrap rule (WebTheme.bootstrapScript), as the app injects it.
          const bootstrap = document.createElement("style");
          bootstrap.textContent = "html{background:var(--cmux-surface-background) !important}";
          document.head.append(bootstrap);
          root.style.setProperty("--cmux-surface-background", "rgba(30, 30, 46, 0)");
          root.style.setProperty("--cmux-surface-solid", "rgb(30, 30, 46)");
          return getComputedStyle(root).backgroundColor;
        });
        expect(background).toBe("rgb(30, 30, 46)");
        await page.close();
      });

      test("code is 85-90% of the body text, at the default and at a 14px body", async () => {
        const page = await open(engine, 1200);
        for (const css of ["", "--cmux-md-font-size: 14px;", "--cmux-md-font-size: 22px;"]) {
          await settings(page, css);
          const sizes = await codeSizes(page);
          expect(sizes.block / sizes.body).toBeGreaterThanOrEqual(0.85);
          expect(sizes.block / sizes.body).toBeLessThanOrEqual(0.9);
          expect(sizes.inline / sizes.paragraph).toBeGreaterThanOrEqual(0.85);
          expect(sizes.inline / sizes.paragraph).toBeLessThanOrEqual(0.9);
        }
        await page.close();
      });
    });
});
