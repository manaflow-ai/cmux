// cmux-web-test-timeout: 300
// The New Tab composer's location icons and dropdown chevrons stay centered on their labels across
// densities (2026-11-23: "can we make sure all of the icons are the same size? double check pls").
// The unified card introduced optically matched silhouettes on 2026-11-25. The gallery measures
// both the SVG box and its ink (the drawn path and its stroke) in Chromium:
// - the unified card's bare folder and laptop draw comparable ink in fixed optical boxes;
// - a picked project's badge scales with density, with the same visual weight at default density;
// - the GitHub mark (GitHubIcons.tsx, chip) draws in the folder icon's box at that footprint;
// - every chip's chevron draws the same ink at the composer's chevron size;
// - the start failure's Details chevron is that chevron turned right, centered on Details.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Ink = { box: number; width: number; height: number; centerY: number; github: boolean };
type Chip = { label: string; labelCenterY: number; picture: boolean; glyph: Ink | null; chevron: Ink | null };

await requireBrowserLane("newtab-chip-icon-sizes.test.ts", async () => {
  setDefaultTimeout(240_000);
  const NEW_TAB = "agent-pane.new-tab-icon-column";
  const GITHUB = "agent-pane.github-folders";
  const FAILURE = "agent-pane.newtab-start-failure";
  const DENSITIES = [0.75, 1, 1.5];
  const THEME = "Apple System Colors";
  // The chip chevron's ink at Default: ComposerPickers.tsx ChevronIcon in a 12 px box (6.8 by 3.3 of
  // its 16 grid, plus its 1.25 line). Details draws it turned right.
  const CHEVRON = { box: 12, long: 6.04, short: 3.41 };
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, NEW_TAB, { browser, params: { variant: "no-project" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, density: number, ready: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 360 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme: THEME })}`);
    await page.waitForSelector(ready, { timeout: 60_000 });
    await page.evaluate((density) => {
      const root = document.documentElement.style;
      root.setProperty("--cmux-density-scale", String(density));
      root.setProperty("--cmux-density-text-scale", String(density));
      // The start failure's gallery draws it outside a composer, where the chevron token falls back to this.
      if (!document.querySelector(".nt-composer, .acpmux-composer"))
        root.setProperty("--acpmux-density", String(density));
    }, density);
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  };

  // In the page: each control's leading glyph and trailing chevron as drawn ink, in CSS px. A control
  // with one svg (Details) reads it as its glyph.
  const measure = (selector: string): Chip[] => {
    const ink = (element: Element | null | undefined): Ink | null => {
      if (!(element instanceof SVGSVGElement)) return null;
      const rect = element.getBoundingClientRect();
      if (rect.width === 0) return null;
      const view = element.viewBox.baseVal;
      const bounds = element.getBBox();
      const lines = [...element.querySelectorAll("path, circle, rect, line, polyline")].map((shape) => {
        const style = getComputedStyle(shape);
        return style.stroke === "none" ? 0 : Number.parseFloat(style.strokeWidth) || 0;
      });
      const line = Math.max(0, ...lines);
      const scale = rect.width / view.width;
      const top = rect.top + (bounds.y - view.y - line / 2) * scale;
      const height = (bounds.height + line) * scale;
      return {
        box: Math.round(rect.height * 100) / 100,
        width: Math.round((bounds.width + line) * scale * 100) / 100,
        height: Math.round(height * 100) / 100,
        centerY: top + height / 2,
        github: element.hasAttribute("data-github-mark"),
      };
    };
    return [...document.querySelectorAll(selector)]
      .filter((control) => control.getBoundingClientRect().width > 0)
      .map((control) => {
        // A chip's label is a block one line tall: its box is its line. Details' words are the
        // summary's own text, read as a range.
        const span = control.querySelector(".acpmux-location-label");
        const words = [...control.childNodes].find(
          (node) => node.nodeType === Node.TEXT_NODE && (node.textContent ?? "").trim() !== "",
        );
        const range = document.createRange();
        range.selectNodeContents(words ?? control);
        const text = span ? span.getBoundingClientRect() : range.getBoundingClientRect();
        const first = control.firstElementChild;
        const glyph = first?.matches("svg") ? first : first?.querySelector(":scope > svg");
        const last = control.lastElementChild;
        const chevron =
          last && last !== first ? (last.matches("svg") ? last : last.querySelector(":scope > svg")) : null;
        return {
          label: ((span ?? words ?? control).textContent ?? "").trim(),
          labelCenterY: (text.top + text.bottom) / 2,
          picture: Boolean(first?.matches(".acpmux-project-badge")),
          glyph: ink(glyph),
          chevron: ink(chevron),
        };
      });
  };

  const near = (actual: number, expected: number, where: string, tolerance = 0.06) =>
    expect(Math.abs(actual - expected), `${where}: ${actual} vs ${expected}`).toBeLessThanOrEqual(tolerance);
  const footprint = (glyph: Ink) => glyph.width * glyph.height;

  for (const variant of ["no-project", "project"])
    for (const density of DENSITIES)
      test(`New Tab ${variant}, density ${density}: optical glyph sizes and scaled chevrons, each centered on its label`, async () => {
        const page = await open(NEW_TAB, variant, density, ".nt-above .acpmux-location-button .ui-ghost-icon");
        try {
          const chips = await page.evaluate(measure, ".nt-above .acpmux-location-button");
          const where = `${variant} ${density}: ${JSON.stringify(chips)}`;
          const folder = chips[0];
          const mac = chips.find((chip) => chip.label === "This Mac");
          expect(folder?.glyph, where).toBeTruthy();
          expect(mac?.glyph, where).toBeTruthy();
          // The unified card fixes the bare folder and laptop at their measured sizes.
          // The picked project's badge keeps its density-scaled 16 px glyph.
          const badgeScale = variant === "project" ? density : 1;
          expect(folder!.picture, where).toBe(variant === "project");
          near(folder!.glyph!.box, variant === "project" ? 16 * density : 16.25, where, 0.01);
          near(mac!.glyph!.box, 16.22, where, 0.01);
          // Compare default-density ink areas across both shapes.
          const weight = footprint(mac!.glyph!) / (footprint(folder!.glyph!) / badgeScale ** 2);
          expect(weight, where).toBeGreaterThanOrEqual(0.9);
          expect(weight, where).toBeLessThanOrEqual(1.1);
          // Both location chips draw a glyph and a chevron, so the checks below run on each.
          expect(chips.filter((chip) => chip.glyph && chip.chevron).length, where).toBeGreaterThanOrEqual(2);
          for (const chip of chips) {
            if (!chip.glyph || !chip.chevron) continue;
            // A project's picture drops 0.08 of its name's size (newtab/screen.css --acpmux-location-mark-drop).
            const drop = chip.picture ? 13 * density * 0.08 : 0;
            near(chip.glyph.centerY - drop, chip.labelCenterY, `${chip.label} glyph off its label; ${where}`, 0.5);
            near(chip.chevron.box, CHEVRON.box * density, `${chip.label} chevron box; ${where}`, 0.01);
            near(chip.chevron.width, CHEVRON.long * density, `${chip.label} chevron width; ${where}`);
            near(chip.chevron.height, CHEVRON.short * density, `${chip.label} chevron height; ${where}`);
            // The down chevron's optical correction (composerLocation.css) keeps it within a px of the label.
            near(chip.chevron.centerY, chip.labelCenterY, `${chip.label} chevron off its label; ${where}`, 1);
          }
        } finally {
          await page.close();
        }
      });

  test("a picked GitHub repository draws its mark in the folder icon's box, at the laptop's weight", async () => {
    const page = await open(GITHUB, "ready-picked", 1, "[data-github-mark]");
    try {
      const chips = await page.evaluate(measure, ".acpmux-location-button");
      const where = JSON.stringify(chips);
      const github = chips.find((chip) => chip.glyph?.github);
      const mac = chips.find((chip) => chip.label === "This Mac");
      expect(github?.label, where).toBe("acme/api");
      expect(mac?.glyph, where).toBeTruthy();
      // The strip's glyph box, as the laptop's height, never the mark's own fixed 12 px.
      near(github!.glyph!.box, mac!.glyph!.box, where, 0.01);
      const weight = footprint(github!.glyph!) / footprint(mac!.glyph!);
      expect(weight, where).toBeGreaterThanOrEqual(0.9);
      expect(weight, where).toBeLessThanOrEqual(1.1);
      near(github!.glyph!.centerY, github!.labelCenterY, `GitHub mark off its label; ${where}`, 0.5);
    } finally {
      await page.close();
    }
  });

  for (const density of DENSITIES)
    test(`the start failure's Details chevron is the chips' chevron, centered on Details, density ${density}`, async () => {
      const page = await open(FAILURE, "not-installed-elsewhere", density, ".acpmux-start-failure summary svg");
      try {
        const details = await page.evaluate(measure, ".acpmux-start-failure summary");
        const where = `${density}: ${JSON.stringify(details)}`;
        expect(details[0]?.label, where).toBe("Details");
        const chevron = details[0]!.glyph!;
        near(chevron.box, CHEVRON.box * density, where, 0.01);
        near(chevron.width, CHEVRON.short * density, where);
        near(chevron.height, CHEVRON.long * density, where);
        near(chevron.centerY, details[0]!.labelCenterY, `Details chevron off its label; ${where}`, 0.5);
        // Details reads at the sentence's size.
        const sizes = await page.evaluate(() =>
          [".acpmux-start-failure [role=alert]", ".acpmux-start-failure summary"].map((selector) => {
            const element = document.querySelector(selector);
            return element ? getComputedStyle(element).fontSize : null;
          }),
        );
        expect(sizes[1], where).toBe(sizes[0]);
        // The line keeps its height: the chevron overhangs it evenly at a larger density.
        const line = await page.evaluate(() => {
          const notice = document.querySelector(".acpmux-start-failure")!;
          const summary = document.querySelector(".acpmux-start-failure summary")!.getBoundingClientRect();
          return { line: Number.parseFloat(getComputedStyle(notice).lineHeight), summary: summary.height };
        });
        expect(line.summary, `${where}: ${JSON.stringify(line)}`).toBeLessThanOrEqual(line.line + 0.01);
        // Opened, Details keeps its size.
        await page.click(".acpmux-start-failure summary");
        await page.waitForSelector(".acpmux-start-failure details[open]");
        const opened = await page.evaluate(
          () => getComputedStyle(document.querySelector(".acpmux-start-failure summary")!).fontSize,
        );
        expect(opened, where).toBe(sizes[0] ?? "");
      } finally {
        await page.close();
      }
    });
});
