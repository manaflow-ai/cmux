// Every top-level transcript row draws its glyph in one icon column and starts its words at one x:
// a tool row, this agent's send (the envelope), another agent's message (its harness's logo, or the
// bot) and the group of waiting messages (its chevron). The glyphs share one slot (left edge and
// width) and one center line, the message rows' glyphs draw at one size, and every row's first
// word starts at the same x (design/chat-transcript.md "One icon column"). Leo, 2026-10-31, on a
// Codex sender's logo above a "Sent to" envelope that sat in different columns at different sizes:
// "the alignment i feel like we might as well".
//
// CMUX_ICON_COLUMN_ARTIFACT_DIR=DIR also writes each theme's 2x still and measurements to DIR.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-icon-column.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.agent-message-row";
  const VARIANT = "icon-column";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  /** How far apart two edges or centers may be, in CSS px. */
  const TOLERANCE = 0.5;
  /** How far apart the message rows' glyphs' drawn size may be, in CSS px. */
  const INK_TOLERANCE = 1.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript icon column", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = {
    kind: string;
    label: string;
    slotLeft: number;
    slotWidth: number;
    /** The glyph element's box center (the svg or image), from the row's left edge. */
    glyphCenter: number;
    /** The drawn glyph's larger side (an svg's geometry box, an image's box). */
    ink: number;
    textLeft: number;
  };

  /** Measures the transcript's top-level rows, from each row's left edge (its `.acpmux-row`). */
  const measure = (page: Page): Promise<Row[]> =>
    page.evaluate(() => {
      const ROW = ".cv-tool, .cv-received > .cv-disclosure__line, .cv-pending__line";
      const ICON = ":scope > .cv-tool__icon, .cv-received__mark, .cv-pending__icon";
      const visible = (element: Element) => {
        const box = element.getBoundingClientRect();
        return box.width > 0 && box.height > 0 && getComputedStyle(element).visibility !== "hidden";
      };
      const rows = [...document.querySelectorAll<HTMLElement>(ROW)].filter(
        (row) =>
          visible(row) &&
          // Top level only: not a step inside an opened group, a waiting group's body or a panel.
          !row.parentElement?.closest(ROW) &&
          !row.closest(".cv-pending__body, .cv-disclosure__panel, .cv-steps"),
      );
      return rows.map((row) => {
        const origin = (row.closest(".acpmux-row") ?? row).getBoundingClientRect().left;
        const slot = row.querySelector<HTMLElement>(ICON);
        if (!slot) throw new Error(`a row with no icon slot: ${row.className}`);
        const slotBox = slot.getBoundingClientRect();
        // The drawn mark itself (an svg or an img), not a wrapper span around it (AgentIdentity's),
        // whose box is its line height; a text-only mark (a chief's initial) falls back to its span.
        const glyph =
          [...slot.querySelectorAll<Element>("svg, img")].find(visible) ??
          [...slot.querySelectorAll<Element>("span")].find(visible) ??
          slot;
        const glyphBox = glyph.getBoundingClientRect();
        let ink = Math.max(glyphBox.width, glyphBox.height);
        if (glyph instanceof SVGSVGElement) {
          const bbox = glyph.getBBox();
          const matrix = glyph.getScreenCTM();
          if (matrix && bbox.width > 0) {
            const a = new DOMPoint(bbox.x, bbox.y).matrixTransform(matrix);
            const b = new DOMPoint(bbox.x + bbox.width, bbox.y + bbox.height).matrixTransform(matrix);
            ink = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
          }
        }
        // The first word after the glyph: the first text the row draws outside its icon slot.
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        let textLeft = Number.NaN;
        let label = "";
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (slot.contains(node) || !node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const first = [...range.getClientRects()].find((rect) => rect.width > 0);
          if (!first) continue;
          textLeft = first.left - origin;
          label = row.textContent?.trim().slice(0, 40) ?? "";
          break;
        }
        const kind = row.matches(".cv-received > .cv-disclosure__line")
          ? "received"
          : row.matches(".cv-agentmsg__line")
            ? "sent"
            : row.matches(".cv-pending__line")
              ? "waiting"
              : "tool";
        return {
          kind,
          label,
          slotLeft: slotBox.left - origin,
          slotWidth: slotBox.width,
          glyphCenter: (glyphBox.left + glyphBox.right) / 2 - origin,
          ink,
          textLeft,
        };
      });
    });

  const px = (value: number) => `${Math.round(value * 100) / 100}px`;

  /** What breaks one icon column and one text inset, as sentences; empty when the rows keep it. */
  const problems = (rows: Row[]) => {
    const found: string[] = [];
    const lead = rows[0]!;
    const near = (a: number, b: number, tolerance = TOLERANCE) => Math.abs(a - b) <= tolerance;
    for (const row of rows.slice(1)) {
      const name = `the ${row.kind} row "${row.label}"`;
      if (!near(row.slotLeft, lead.slotLeft))
        found.push(`${name}'s icon slot starts at ${px(row.slotLeft)}, the ${lead.kind} row's at ${px(lead.slotLeft)}`);
      if (!near(row.slotWidth, lead.slotWidth))
        found.push(`${name}'s icon slot is ${px(row.slotWidth)} wide, the ${lead.kind} row's ${px(lead.slotWidth)}`);
      if (!near(row.glyphCenter, lead.glyphCenter))
        found.push(
          `${name}'s glyph centers at ${px(row.glyphCenter)}, the ${lead.kind} row's at ${px(lead.glyphCenter)}`,
        );
      if (!near(row.textLeft, lead.textLeft))
        found.push(`${name}'s words start at ${px(row.textLeft)}, the ${lead.kind} row's at ${px(lead.textLeft)}`);
    }
    const messages = rows.filter((row) => row.kind === "sent" || row.kind === "received");
    const inks = messages.map((row) => row.ink);
    if (inks.length > 1 && Math.max(...inks) - Math.min(...inks) > INK_TOLERANCE)
      found.push(
        `the message rows' glyphs draw at different sizes: ${messages.map((row) => `${row.kind} "${row.label}" ${px(row.ink)}`).join(", ")}`,
      );
    return found;
  };

  for (const theme of THEMES)
    test(`messages and tool rows share one icon column and one text inset (${theme.name})`, async () => {
      const artifacts = process.env.CMUX_ICON_COLUMN_ARTIFACT_DIR;
      const page = await browser.newPage({ viewport: { width: 760, height: 520 }, deviceScaleFactor: 2 });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 560, theme: theme.name })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        await page.evaluate(() => document.fonts.ready);
        await page.locator(".cv-received").first().waitFor();
        const rows = await measure(page);
        const lines = rows.map(
          (row) =>
            `  ${row.kind.padEnd(8)} slot ${px(row.slotLeft)}+${px(row.slotWidth)} glyph center ${px(row.glyphCenter)} ink ${px(row.ink)} text ${px(row.textLeft)} "${row.label}"`,
        );
        console.log(`${theme.name}:\n${lines.join("\n")}`);
        const found = problems(rows);
        if (artifacts) {
          await mkdir(artifacts, { recursive: true });
          await writeFile(
            path.join(artifacts, `icon-column-${theme.file}.json`),
            JSON.stringify({ theme: theme.name, rows, problems: found }, null, 2),
          );
          await page.screenshot({ path: path.join(artifacts, `icon-column-${theme.file}.png`), fullPage: true });
        }
        expect(rows.map((row) => row.kind)).toEqual(expect.arrayContaining(["tool", "sent", "received"]));
        expect(rows.filter((row) => row.kind === "received").length).toBeGreaterThanOrEqual(2);
        expect(found).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
