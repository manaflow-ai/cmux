// Inbox rows among tool rows share the tool rows' icon column (Leo, 2026-11-01, on an inbox line
// whose glyph sat right of the tool rows': "i wanted this to be left aligned with the other tool
// calls"), and a folded group of threads is a sibling of the tool rows (Leo, 2026-11-01, on its
// bare chevron indented past that column on a taller line: "let's just make this look better").
// Measured in the page, never from each row's own box, so a row-level inset counts: every inbox
// line's glyph center and first word's x equal a tool row's; a group's head also has a tool row's
// height, icon-to-word gap and type size; its chevron is hidden at rest and shown on hover.
// design/chat-transcript.md "One icon column".
//
// CMUX_INBOX_ROW_ARTIFACT_DIR=DIR also writes each theme's 2x still and measurements to DIR.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("inbox-row-icon-column.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.inbox-notice";
  const VARIANT = "icon-column";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  /** How far apart two edges or centers may be, in CSS px. */
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("inbox row icon column", () => test("browser", () => {}));
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
    kind: "tool" | "line" | "group";
    label: string;
    glyphCenter: number;
    textLeft: number;
    /** From the icon slot's right edge to the first word. */
    gap: number;
    height: number;
    fontSize: number;
  };

  /** Every top-level tool row, inbox line and inbox group head, in page px. */
  const measure = (page: Page): Promise<Row[]> =>
    page.evaluate(() => {
      const visible = (element: Element) => {
        const box = element.getBoundingClientRect();
        return box.width > 0 && box.height > 0 && getComputedStyle(element).visibility !== "hidden";
      };
      // A group's head (MessageGroupHead.tsx; before it, the waiting group's and the delivered batch's
      // chevron lines).
      const GROUP = ".cv-message-group__head, .cv-pending__line, .cv-lane-batch__toggle";
      const LINE = ".cv-received > .cv-disclosure__line";
      const TOOL = ".cv-tools .cv-tool";
      const rows = [...document.querySelectorAll<HTMLElement>(`${TOOL}, ${LINE}, ${GROUP}`)].filter(
        (row) =>
          visible(row) &&
          // Top level only: not a step of an opened tool group or a line inside an opened inbox group.
          !row.closest(".cv-steps, .cv-inbox__body, .cv-pending__body, .cv-lane-batch__body, .cv-disclosure__panel") &&
          !(row.matches(TOOL) && !row.matches(GROUP) && row.closest(".cv-inbox")) &&
          // A head inside a waiting group's line is that group's row; measure the head.
          !(row.matches(".cv-pending__line") && row.querySelector(".cv-message-group__head")),
      );
      return rows.map((row) => {
        const kind = row.matches(GROUP) ? "group" : row.matches(LINE) ? "line" : "tool";
        const slot = row.querySelector<HTMLElement>(":scope > .cv-tool__icon, .cv-received__mark, .cv-pending__icon");
        if (!slot) throw new Error(`a row with no icon slot: ${row.className}`);
        const glyph =
          [...slot.querySelectorAll<Element>("svg, img")].find(visible) ??
          [...slot.querySelectorAll<Element>("span")].find(visible) ??
          slot;
        const glyphBox = glyph.getBoundingClientRect();
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        let textLeft = Number.NaN;
        let fontSize = Number.NaN;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (slot.contains(node) || !node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const first = [...range.getClientRects()].find((rect) => rect.width > 0);
          if (!first) continue;
          textLeft = first.left;
          fontSize = Number.parseFloat(getComputedStyle(node.parentElement!).fontSize);
          break;
        }
        return {
          kind,
          label: row.textContent?.trim().slice(0, 40) ?? "",
          glyphCenter: (glyphBox.left + glyphBox.right) / 2,
          textLeft,
          gap: textLeft - slot.getBoundingClientRect().right,
          height: row.getBoundingClientRect().height,
          fontSize,
        };
      });
    });

  const px = (value: number) => `${Math.round(value * 100) / 100}px`;
  const near = (a: number, b: number) => Math.abs(a - b) <= TOLERANCE;

  /** What breaks the shared column, as sentences; empty when every inbox row keeps it. */
  const problems = (rows: Row[]) => {
    const found: string[] = [];
    const tool = rows.find((row) => row.kind === "tool");
    if (!tool) return ["no tool row drew"];
    for (const row of rows) {
      if (row.kind === "tool") continue;
      const name = `the inbox ${row.kind} "${row.label}"`;
      if (!near(row.glyphCenter, tool.glyphCenter))
        found.push(`${name}'s glyph centers at x ${px(row.glyphCenter)}, the tool row's at ${px(tool.glyphCenter)}`);
      if (!near(row.textLeft, tool.textLeft))
        found.push(`${name}'s title starts at x ${px(row.textLeft)}, the tool row's at ${px(tool.textLeft)}`);
      if (row.kind !== "group") continue;
      if (!near(row.height, tool.height))
        found.push(`${name} is ${px(row.height)} tall, the tool row ${px(tool.height)}`);
      if (!near(row.gap, tool.gap))
        found.push(`${name}'s words start ${px(row.gap)} after its icon slot, the tool row's ${px(tool.gap)}`);
      if (!near(row.fontSize, tool.fontSize))
        found.push(`${name}'s type is ${px(row.fontSize)}, the tool row's ${px(tool.fontSize)}`);
    }
    return found;
  };

  for (const theme of THEMES)
    test(`inbox lines and groups share the tool rows' icon column, and a group is a tool row (${theme.name})`, async () => {
      const artifacts = process.env.CMUX_INBOX_ROW_ARTIFACT_DIR;
      const page = await browser.newPage({ viewport: { width: 760, height: 620 }, deviceScaleFactor: 2 });
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
        await page.locator(".cv-pending").first().waitFor();
        await page.mouse.move(0, 0);
        const rows = await measure(page);
        console.log(
          `${theme.name}:\n${rows
            .map(
              (row) =>
                `  ${row.kind.padEnd(6)} glyph ${px(row.glyphCenter)} text ${px(row.textLeft)} gap ${px(row.gap)} h ${px(row.height)} type ${px(row.fontSize)} "${row.label}"`,
            )
            .join("\n")}`,
        );
        const found = problems(rows);

        // The group's chevron: hidden at rest, shown on hover.
        const head = page.locator(".cv-message-group__head").first();
        const chevron = head.locator(".cv-tool__chevron");
        const shown = async () =>
          chevron.evaluate((element) => {
            const style = getComputedStyle(element);
            return style.visibility !== "hidden" && Number(style.opacity) > 0.5;
          });
        const hasHead = (await head.count()) > 0;
        const atRest = hasHead ? await shown() : undefined;
        let hovered: boolean | undefined;
        if (hasHead) {
          await head.hover();
          // The reveal fades in after its delay; wait for it rather than a fixed time.
          hovered = await page
            .waitForFunction(
              () => {
                const element = document.querySelector(".cv-message-group__head .cv-tool__chevron");
                return !!element && Number(getComputedStyle(element).opacity) > 0.5;
              },
              undefined,
              { timeout: 5_000 },
            )
            .then(
              () => true,
              () => false,
            );
        }
        if (artifacts) {
          await mkdir(artifacts, { recursive: true });
          await writeFile(
            path.join(artifacts, `inbox-row-${theme.file}.json`),
            JSON.stringify({ theme: theme.name, rows, problems: found, chevron: { atRest, hovered } }, null, 2),
          );
          await page.mouse.move(0, 0);
          await page.screenshot({ path: path.join(artifacts, `inbox-row-${theme.file}.png`), fullPage: true });
        }
        expect(rows.filter((row) => row.kind === "line").length).toBeGreaterThanOrEqual(2);
        // A delivered group of one sender, one of several, and the waiting group.
        expect(rows.filter((row) => row.kind === "group").length).toBe(3);
        expect(found).toEqual([]);
        expect(hasHead).toBe(true);
        expect({ atRest, hovered }).toEqual({ atRest: false, hovered: true });
      } finally {
        await page.close();
      }
    });
});
