// cmux-web-test-timeout: 420
// The + button and the text beside it, in every composer layout (Leo 2026-10-31: "composer still
// looks like shit with the + spacing indent to the text"). leo-workspace design/grid.md 5.1 and
// design/composer.md: + is a 28 px box 8 px in from the box's left edge, and the text (the
// placeholder, the caret and what is typed) starts one gap after it, `--acpmux-composer-lead-gap`
// (8 px), so the text column is 44 px in. The rows that hang off the box take its one left inset
// (8 px, the + box's left edge): the attachment chips in it, the project and machine pills over it,
// the quiet row's first chip under it (its pill; its mark then stands over the + glyph), and the
// suggestion rows New Tab opens under it.
//
// The chat pane at a normal and a narrow width, Home (an empty chat's welcome) and New Tab (its
// default page, a typed draft with its suggestions, a narrow pane), in Chromium on the gallery
// stage. Each layout's numbers and a 2x still, light and dark, go to
// webviews/artifacts/composer-plus-gap/ (the fleet step returns them as artifacts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-plus-text-gap.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-plus-text-gap: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer + to text gap", () => test("chromium", () => {}));
    return;
  }
  /** --acpmux-composer-lead-gap: from the + button's right edge to the text's start. */
  const GAP = 8;
  /** --acpmux-composer-inset: from the box's left edge to the + button's, and every row's start. */
  const INSET = 8;
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;

  type Layout = {
    name: string;
    entry: string;
    variant: string;
    width: number;
    /** Text typed into the prompt before measuring (a ProseMirror prompt or New Tab's textarea). */
    type?: string;
    /** A row the layout must draw for the inset check. */
    expect?: ("chips" | "pills" | "foot" | "suggestions")[];
  };
  const LAYOUTS: Layout[] = [
    { name: "chat", entry: "agent-pane.composer-row", variant: "claude-auto", width: 760, expect: ["foot"] },
    {
      name: "chat-typed",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      width: 760,
      type: "Fix the flaky upload test",
    },
    { name: "chat-image", entry: "agent-pane.composer", variant: "image-attached", width: 760, expect: ["chips"] },
    { name: "chat-narrow", entry: "agent-pane.narrow", variant: "controls", width: 280, expect: ["foot"] },
    { name: "home", entry: "agent-pane.new-chat-composer", variant: "claude", width: 760, expect: ["foot"] },
    { name: "new-tab", entry: "agent-pane.new-tab", variant: "minimal-default", width: 760, expect: ["pills", "foot"] },
    {
      name: "new-tab-suggestions",
      entry: "agent-pane.new-tab",
      variant: "suggestions-minimal-ff",
      width: 760,
      expect: ["suggestions"],
    },
    { name: "new-tab-narrow", entry: "agent-pane.narrow", variant: "new-tab-default", width: 280, expect: ["foot"] },
  ];

  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "composer-plus-gap");
  mkdirSync(outDir, { recursive: true });
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
    for (const entry of new Set(LAYOUTS.map((layout) => layout.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: LAYOUTS.find((layout) => layout.entry === entry)!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (layout: Layout, scheme: "light" | "dark"): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: layout.width, height: 600 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const theme = scheme === "light" ? "Apple System Colors Light" : "Apple System Colors";
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(layout.entry, { variant: layout.variant, theme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".nt-box, .acpmux-composer-box").first().waitFor();
    if (layout.type) {
      await page.locator(".nt-field, .acpmux-composer-box .ProseMirror").first().click();
      await page.keyboard.type(layout.type);
    }
    if (layout.expect?.includes("suggestions")) await page.locator(".nt-popover .nt-row").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  };

  type Measured = {
    box: { left: number; top: number; right: number; bottom: number } | null;
    plus: { left: number; right: number } | null;
    /** Where the placeholder's (or, with a draft, the typed text's) first character's box starts. */
    text: number | null;
    textSource: string;
    /** The + glyph, from the box's left edge. */
    plusGlyph: { left: number; center: number } | null;
    /** The rows that hang off the box, from its left edge: a row of boxes by its first box's left
        edge, a row of marks by its leading mark (a glyph or a character). */
    rows: {
      chips: number | null;
      pills: number | null;
      foot: { left: number; center: number; kind: string } | null;
      suggestions: { left: number; center: number; kind: string } | null;
    };
    clip: { x: number; y: number; width: number; height: number } | null;
  };
  const measure = (page: Page) =>
    page.evaluate((): Measured => {
      const shown = (element: Element | null | undefined) => {
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 ? rect : null;
      };
      const firstText = (element: Element | null | undefined) => {
        if (!element) return null;
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          const start = node.textContent.search(/\S/);
          range.setStart(node, start);
          range.setEnd(node, start + 1);
          const rect = range.getBoundingClientRect();
          if (rect.width > 0) return rect.left;
        }
        return null;
      };
      const card = document.querySelector(".nt-box") ?? document.querySelector(".acpmux-composer-box");
      const box = shown(card);
      const plus = shown(card?.querySelector(".acpmux-composer-plus .acpmux-picker-button"));
      let text: number | null = null;
      let textSource = "none";
      const area = card?.querySelector<HTMLTextAreaElement>("textarea.nt-field");
      if (area) {
        // A textarea draws its placeholder and its value from its content box's left edge.
        const style = getComputedStyle(area);
        text = area.getBoundingClientRect().left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
        textSource = area.value ? "textarea value" : "textarea placeholder";
      } else {
        const typed = firstText(card?.querySelector(".ProseMirror"));
        if (typed !== null) {
          text = typed;
          textSource = "typed";
        } else {
          text = firstText(card?.querySelector(".acpmux-md-placeholder"));
          textSource = "placeholder";
        }
      }
      const firstShown = (selector: string) => {
        for (const element of document.querySelectorAll(selector)) {
          const rect = shown(element);
          if (rect) return rect;
        }
        return null;
      };
      /** The leftmost drawn mark in `root`: a glyph (svg, img) or a text character, and what it is. */
      const leadingMark = (root: Element | null) => {
        if (!root) return null;
        let best: { left: number; center: number; kind: string } | null = null;
        const take = (left: number, center: number, kind: string) => {
          if (!best || left < best.left) best = { left, center, kind };
        };
        for (const glyph of root.querySelectorAll("svg, img")) {
          const rect = shown(glyph);
          if (rect) take(rect.left, rect.left + rect.width / 2, "glyph");
        }
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const start = node.textContent?.search(/\S/) ?? -1;
          if (start < 0 || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.setStart(node, start);
          range.setEnd(node, start + 1);
          const rect = range.getBoundingClientRect();
          if (rect.width > 0) take(rect.left, rect.left + rect.width / 2, "text");
        }
        return best as { left: number; center: number; kind: string } | null;
      };
      const plusGlyph = shown(card?.querySelector(".acpmux-composer-plus svg"));
      /** A row that holds boxes (attachment tiles, pills): its leftmost box's left edge, from the box's. */
      const boxRow = (selector: string) => {
        const rects = [...document.querySelectorAll(selector)].map(shown).filter((rect): rect is DOMRect => !!rect);
        return rects.length && box ? Math.min(...rects.map((rect) => rect.left)) - box.left : null;
      };
      /** A row of marks (the quiet row, the suggestions): its leading mark, from the box's left. */
      const markRow = (selector: string) => {
        const root = [...document.querySelectorAll(selector)].find((element) => shown(element)) ?? null;
        const mark = leadingMark(root);
        return mark && box ? { left: mark.left - box.left, center: mark.center - box.left, kind: mark.kind } : null;
      };
      const rows = {
        chips: boxRow(
          ".acpmux-composer-box > .acpmux-attachments .acpmux-attachment, .nt-box > .acpmux-attachments .acpmux-attachment",
        ),
        pills: boxRow(".nt-above :is(button, .acpmux-location-readonly)"),
        foot: markRow(".acpmux-composer-foot"),
        suggestions: markRow(".nt-popover .nt-row"),
      };
      // The still: the box and every row that hangs off it, with room around them.
      const parts = [
        box,
        firstShown(".nt-above"),
        firstShown(".acpmux-composer-foot"),
        firstShown(".nt-popover"),
      ].filter((rect): rect is DOMRect => rect !== null);
      const pad = 16;
      const clip = parts.length
        ? (() => {
            const x = Math.max(0, Math.min(...parts.map((rect) => rect.left)) - pad);
            const y = Math.max(0, Math.min(...parts.map((rect) => rect.top)) - pad);
            const right = Math.min(innerWidth, Math.max(...parts.map((rect) => rect.right)) + pad);
            const bottom = Math.min(innerHeight, Math.max(...parts.map((rect) => rect.bottom)) + pad);
            return { x, y, width: right - x, height: bottom - y };
          })()
        : null;
      return {
        box: box ? { left: box.left, top: box.top, right: box.right, bottom: box.bottom } : null,
        plus: plus ? { left: plus.left, right: plus.right } : null,
        plusGlyph:
          plusGlyph && box
            ? { left: plusGlyph.left - box.left, center: plusGlyph.left + plusGlyph.width / 2 - box.left }
            : null,
        text,
        textSource,
        rows,
        clip,
      };
    });

  const problems = (layout: Layout, m: Measured): string[] => {
    const out: string[] = [];
    const f = (n: number) => n.toFixed(2);
    if (!m.box) return ["the composer box is not drawn"];
    if (!m.plus) return ["the + button is not drawn in the box"];
    if (m.text === null) return ["the text's start is not drawn"];
    const lead = m.plus.left - m.box.left;
    if (Math.abs(lead - INSET) > TOLERANCE) out.push(`+ starts ${f(lead)} px into the box, not ${INSET}`);
    const gap = m.text - m.plus.right;
    if (Math.abs(gap - GAP) > TOLERANCE) out.push(`the text (${m.textSource}) starts ${f(gap)} px after +, not ${GAP}`);
    for (const row of layout.expect ?? []) {
      const at = m.rows[row];
      if (at === null || at === undefined) {
        out.push(`the ${row} row is not drawn`);
        continue;
      }
      if (typeof at === "number") {
        // A row of boxes starts on the box's inset, where + starts.
        if (Math.abs(at - INSET) > TOLERANCE) out.push(`the ${row} row starts ${f(at)} px into the box, not ${INSET}`);
      } else if (m.plusGlyph) {
        // A row of marks stands on the + glyph's column: a leading glyph centered on the + glyph's
        // center, leading text on the + glyph's left edge (design/grid.md 5.1, the quiet row).
        const off = at.kind === "glyph" ? at.center - m.plusGlyph.center : at.left - m.plusGlyph.left;
        if (Math.abs(off) > TOLERANCE)
          out.push(
            `the ${row} row's leading ${at.kind} sits ${f(at.kind === "glyph" ? at.center : at.left)} px into the box, the + glyph's column ${f(at.kind === "glyph" ? m.plusGlyph.center : m.plusGlyph.left)} px`,
          );
      }
    }
    return out;
  };

  for (const layout of LAYOUTS)
    test(`${layout.name} at ${layout.width} px: + ${INSET} px in, the text ${GAP} px after it, the rows on the box's inset`, async () => {
      let result: string[] = [];
      for (const scheme of ["light", "dark"] as const) {
        const page = await open(layout, scheme);
        const m = await measure(page);
        const stem = `${layout.name}-${scheme}`;
        writeFileSync(path.join(outDir, `${stem}.json`), `${JSON.stringify(m, null, 2)}\n`);
        if (m.clip) await page.screenshot({ path: path.join(outDir, `${stem}.png`), clip: m.clip });
        // The fleet step uploads what lands in FAST_CHECKS_OUT as the run's artifact.
        if (process.env.FAST_CHECKS_OUT) {
          const out = path.join(process.env.FAST_CHECKS_OUT, "composer-plus-gap");
          mkdirSync(out, { recursive: true });
          for (const ext of ["json", "png"]) {
            const file = path.join(outDir, `${stem}.${ext}`);
            if (existsSync(file)) copyFileSync(file, path.join(out, `${stem}.${ext}`));
          }
        }
        const gap = m.plus && m.text !== null ? m.text - m.plus.right : null;
        console.log(
          `composer-plus-gap ${JSON.stringify({ layout: layout.name, scheme, gap, lead: m.plus && m.box ? m.plus.left - m.box.left : null, plusGlyph: m.plusGlyph, rows: m.rows, textSource: m.textSource })}`,
        );
        // The geometry is the theme's to keep: measure the light page, still both.
        if (scheme === "light") result = problems(layout, m);
        await page.close();
      }
      expect(result).toEqual([]);
    });
});
