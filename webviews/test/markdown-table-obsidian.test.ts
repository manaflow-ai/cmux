// Markdown tables behave as Obsidian's (MARKDOWN-OBSIDIAN-PARITY, user 2026-10-19: "Highlighting the
// table in Markdown is very buggy ... I want to be able to resize the table better ... when we have
// transparency mode on ... the border and the tables intersect ... the color looks kind of
// different"). The real markdown page (gallery entry pages.markdown, variant table-editing):
//
// - a drag across cells selects whole cells and draws one even highlight on each, with no stray
//   text highlight; Shift-click extends the cell selection;
// - every column has a resize handle on its right edge: a drag sets the width, the width is kept
//   across a reload without touching the file, and a double-click fits the column to its content;
// - with translucent border and header colors (transparency mode) every border pixel has the same
//   color: crossings are not darker (no double alpha) and the header's background does not tint its
//   borders.
//
// The app draws the page in WebKit; Chromium runs too. An engine that is not installed is skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { PNG } from "pngjs";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-table-obsidian.test.ts", async () => {
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
      console.warn(`markdown-table-obsidian: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("markdown tables", () => test("no engine", () => {}));
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
      params: { variant: "table-editing" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const url = () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    return `http://127.0.0.1:${port}${galleryFrame("pages.markdown", { variant: "table-editing" })}`;
  };

  const load = async (page: Page) => {
    for (let attempt = 1; ; attempt++) {
      await page.goto(url());
      try {
        await page.waitForSelector(".md-prose table td", { timeout: 60_000 });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  };

  const open = async (engine: string, scale = 1): Promise<Page> => {
    const context = await browsers.get(engine)!.newContext({
      viewport: { width: 720, height: 520 },
      deviceScaleFactor: scale,
    });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await load(page);
    return page;
  };

  /** The center of the cell whose text is `text`. */
  const cell = async (page: Page, text: string) => {
    const box = (await page.locator(".md-prose :is(td, th)", { hasText: new RegExp(`^${text}$`) }).boundingBox())!;
    return { x: box.x + box.width / 2, y: box.y + box.height / 2, box };
  };

  const selectedTexts = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll(".md-prose .selectedCell")].map((element) => element.textContent?.trim()),
    );

  /** The RGBA at a device pixel of a screenshot. */
  const pixel = (png: PNG, x: number, y: number) => {
    const index = (png.width * y + x) * 4;
    return [png.data[index], png.data[index + 1], png.data[index + 2], png.data[index + 3]];
  };

  for (const [engine] of engines)
    describe(`markdown tables (${engine})`, () => {
      test("a drag across cells selects whole cells, each drawn with one even highlight", async () => {
        const page = await open(engine);
        const from = await cell(page, "Ada");
        const to = await cell(page, "Navy");
        await page.mouse.move(from.x, from.y);
        await page.mouse.down();
        await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2, { steps: 4 });
        await page.mouse.move(to.x, to.y, { steps: 4 });
        await page.mouse.up();
        expect(await selectedTexts(page)).toEqual(["Ada", "Engineer", "Core", "Grace", "Admiral", "Navy"]);

        // The highlight is the same in every selected cell, also over its text: no native text
        // highlight on top (it would double the tint over the words) and none on unselected cells.
        const shot = PNG.sync.read(await page.screenshot());
        const ada = await cell(page, "Ada");
        const navy = await cell(page, "Navy");
        const linus = await cell(page, "Linus");
        const corner = (c: typeof ada) => pixel(shot, Math.round(c.box.x + 3), Math.round(c.box.y + 3));
        expect(corner(ada)).toEqual(corner(navy));
        expect(corner(ada)).not.toEqual(corner(linus));
        const hidden = await page.evaluate(() => {
          const prose = document.querySelector(".md-prose")!;
          const text = document.querySelector(".md-prose td p, .md-prose td")!;
          return {
            hidesNative: prose.classList.contains("ProseMirror-hideselection"),
            nativeSelection: getComputedStyle(text, "::selection").backgroundColor,
          };
        });
        expect(hidden.hidesNative).toBe(true);
        expect(hidden.nativeSelection).toMatch(/rgba\(0, 0, 0, 0\)|transparent/);
        await page.context().close();
      });

      // User 2026-10-28 ("highlighting full table cells is still weird"): the app sets
      // --cmux-text-selection to the theme's terminal selection color, which is opaque. The cell
      // highlight was an ::after layer above the cell, so it painted that opaque color over the
      // words: flat gray blocks with the text gone. Native text selection keeps text readable and
      // lets the page show through; selected cells must too.
      test("with an opaque theme selection color, selected cells stay translucent and their text stays visible", async () => {
        const page = await open(engine);
        const opaque = [85, 87, 76];
        await page.evaluate((rgb) => {
          document.documentElement.style.setProperty("--cmux-text-selection", `rgb(${rgb.join(", ")})`);
        }, opaque);
        const from = await cell(page, "Ada");
        const to = await cell(page, "Navy");
        await page.mouse.move(from.x, from.y);
        await page.mouse.down();
        await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2, { steps: 4 });
        await page.mouse.move(to.x, to.y, { steps: 4 });
        await page.mouse.up();
        expect((await selectedTexts(page)).length).toBe(6);

        const shot = PNG.sync.read(await page.screenshot());
        const ada = (await cell(page, "Ada")).box;
        const linus = (await cell(page, "Linus")).box;
        const fill = pixel(shot, Math.round(ada.x + 3), Math.round(ada.y + 3));
        const unselected = pixel(shot, Math.round(linus.x + 3), Math.round(linus.y + 3));
        // Selected, but not a flat block of the opaque color: the page shows through it.
        expect(fill).not.toEqual(unselected);
        expect(fill.slice(0, 3)).not.toEqual(opaque);
        // The words are drawn over the highlight: inside the cell some pixels differ clearly from the fill.
        let strongest = 0;
        for (let y = Math.round(ada.y + 2); y < Math.round(ada.y + ada.height - 2); y++)
          for (let x = Math.round(ada.x + 2); x < Math.round(ada.x + ada.width - 2); x++) {
            const p = pixel(shot, x, y);
            strongest = Math.max(
              strongest,
              Math.abs(p[0] - fill[0]) + Math.abs(p[1] - fill[1]) + Math.abs(p[2] - fill[2]),
            );
          }
        expect(strongest).toBeGreaterThan(120);
        await page.context().close();
      });

      test("Shift-click extends the cell selection", async () => {
        const page = await open(engine);
        const from = await cell(page, "Ada");
        const to = await cell(page, "Kernel");
        await page.mouse.click(from.x, from.y);
        await page.keyboard.down("Shift");
        await page.mouse.click(to.x, to.y);
        await page.keyboard.up("Shift");
        expect((await selectedTexts(page)).length).toBe(9);
        await page.context().close();
      });

      test("a column's right edge resizes it; the width stays across a reload; double-click fits it", async () => {
        const page = await open(engine);
        const role = await cell(page, "Role");
        const before = role.box.width;
        const edge = { x: role.box.x + role.box.width - 1, y: role.y };
        await page.mouse.move(edge.x, edge.y);
        const handle = page.locator(".md-prose .md-col-resize");
        await handle.first().waitFor({ state: "visible", timeout: 5_000 });
        await page.mouse.down();
        await page.mouse.move(edge.x + 90, edge.y, { steps: 6 });
        await page.mouse.up();
        const after = (await cell(page, "Role")).box.width;
        expect(after).toBeGreaterThan(before + 80);
        expect(after).toBeLessThan(before + 100);
        // A view setting: the file is not edited.
        expect(await page.locator("[data-status]").first().getAttribute("data-status")).not.toBe("edited");
        // The page sends the width to the host (cmux.markdown.setTableWidths) after the drag, and the
        // gallery host stores it a task later: reload only once it has, or the reload races the write.
        await page.waitForFunction(() =>
          Object.keys(sessionStorage).some((key) => key.startsWith("cmux.gallery.markdown.tableWidths:")),
        );

        await load(page);
        const reloaded = (await cell(page, "Role")).box.width;
        expect(Math.abs(reloaded - after)).toBeLessThan(2);

        const edge2 = await cell(page, "Role");
        await page.mouse.move(edge2.box.x + edge2.box.width - 1, edge2.y);
        await handle.first().waitFor({ state: "visible", timeout: 5_000 });
        await page.mouse.dblclick(edge2.box.x + edge2.box.width - 1, edge2.y);
        const fitted = (await cell(page, "Role")).box.width;
        expect(Math.abs(fitted - before)).toBeLessThan(3);
        await page.context().close();
      });

      test("translucent borders composite to one color, also at crossings and around the header", async () => {
        const page = await open(engine, 2);
        // Transparency mode: the separator and the header fill are translucent over the window.
        await page.evaluate(() => {
          const style = document.documentElement.style;
          style.setProperty("--cmux-md-border-color", "rgba(0, 0, 255, 0.5)");
          style.setProperty("--cmux-md-table-border", "1px solid rgba(0, 0, 255, 0.5)");
          style.setProperty("--cmux-md-table-header-background", "rgba(0, 0, 0, 0.08)");
          (document.activeElement as HTMLElement | null)?.blur();
        });
        // A frame painted with the new colors, once any ease into them has run out.
        await page.waitForFunction(() =>
          document
            .getAnimations()
            .every(
              (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
            ),
        );
        await page.evaluate(() => window.cmuxPaintFrame());
        const shot = PNG.sync.read(await page.screenshot());
        const scale = 2;
        /** The strongest border pixel (lowest red) in a window around a CSS point. */
        const strongest = (x: number, y: number, radius = 3) => {
          let red = 255;
          for (let dy = -radius * scale; dy <= radius * scale; dy++)
            for (let dx = -radius * scale; dx <= radius * scale; dx++) {
              const [r, , b] = pixel(shot, Math.round(x * scale) + dx, Math.round(y * scale) + dy);
              // Border pixels are blue; text is gray or black and is skipped.
              if (b - r > 60) red = Math.min(red, r);
            }
          return red;
        };
        const name = (await cell(page, "Name")).box;
        const role = (await cell(page, "Role")).box;
        const ada = (await cell(page, "Ada")).box;
        const engineer = (await cell(page, "Engineer")).box;
        const grace = (await cell(page, "Grace")).box;
        const bodySegment = strongest(engineer.x, engineer.y + engineer.height / 2, 2);
        const samples = {
          headerSegment: strongest(role.x, role.y + role.height / 2, 2),
          headerBottom: strongest(name.x + name.width / 2, name.y + name.height, 2),
          crossing: strongest(grace.x + grace.width, grace.y),
          headerCrossing: strongest(ada.x + ada.width, ada.y),
          outerCorner: strongest(name.x, name.y),
        };
        for (const [where, red] of Object.entries(samples))
          expect({ where, delta: Math.abs(red - bodySegment) <= 6 }).toEqual({ where, delta: true });
        await page.context().close();
      });
    });
});
