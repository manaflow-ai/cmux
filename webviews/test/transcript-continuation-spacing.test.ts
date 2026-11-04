// l10n-allow-file: public gallery fixture and geometry assertions.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { gridLength, MARK_MESSAGE, MARK_STATUS, transcriptGap } from "../src/agent-session/acpmux/transcriptGrid";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-continuation-spacing.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const entry = "agent-pane.continuation-spacing";
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, entry, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  async function open(variant = "shipped"): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 800 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForSelector('[data-row-id="continuation-footer-d"] .cv-turn-actions');
    await page.waitForFunction(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-row")].every(
        (node, index, nodes) =>
          index === 0 || node.getBoundingClientRect().top >= nodes[index - 1]!.getBoundingClientRect().bottom - 0.5,
      ),
    );
    return page;
  }
  const measure = (page: Page) =>
    page.evaluate(() => {
      const node = (id: string) => document.querySelector<HTMLElement>(`[data-row-id="continuation-${id}"]`)!;
      const box = (id: string) => node(id).getBoundingClientRect();
      const actions = (id: string) => node(id).querySelector(".cv-turn-actions")!.getBoundingClientRect();
      // The empty footer's first button: its glyph is centred in it (grid.md 4), and that glyph, not
      // the 28 hit box, is what keeps clear of both rows.
      const button = (
        node("footer-a").querySelector(".cv-turn-actions .cv-iconbtn") ??
        node("footer-a").querySelector(".cv-turn-actions")!
      ).getBoundingClientRect();
      const centre = (button.top + button.bottom) / 2;
      return {
        // Reply to reply: the footer between them draws nothing at rest and takes no room.
        same: box("b").top - box("a").bottom,
        glyphOverSame: centre - box("a").bottom,
        glyphUnderSame: box("b").top - centre,
        peer: box("peer").top - box("b").bottom,
        footerUnderReply: box("footer-c").top - box("c").bottom,
        user: box("user").top - actions("footer-c").bottom,
        paddings: ["footer-a", "footer-b", "footer-c", "footer-d"].map((id) =>
          parseFloat(getComputedStyle(node(id)).paddingBottom),
        ),
      };
    });
  // The virtual stack owns every gap between rows (#27580, design/grid.md 5.5): the same agent's next
  // reply takes the block gap, a prompt the turn gap, and a reply's footer row sits the footer gap
  // under it. Another agent's line is a status row (model.ts isStatusRow), so it sits the run gap
  // from the reply over it (#31879, design/transcript-spacing.md rule 4). The half gap between one
  // agent's replies (#26755) and the footer's centring drop inside its row (#29860) went with #27580;
  // rows carry no padding of their own.
  test("the same assistant's next reply takes the block gap, another agent's line the run gap; a prompt keeps the turn gap", async () => {
    const page = await open();
    await page.waitForFunction(
      () => document.querySelector('[data-row-id="continuation-b"]')!.getBoundingClientRect().top > 0,
    );
    const actual = await measure(page);
    expect(actual.same).toBeCloseTo(gridLength("gap-block"), 1);
    // grid.md 5.5: the hover row laid in the gap keeps its glyphs at least the foot gap from both rows.
    const halfGlyph = gridLength("transcript-icon-box") / 2;
    expect(actual.glyphOverSame - halfGlyph).toBeGreaterThanOrEqual(gridLength("gap-foot") - 0.5);
    expect(actual.glyphUnderSame - halfGlyph).toBeGreaterThanOrEqual(gridLength("gap-foot") - 0.5);
    expect(actual.peer).toBeCloseTo(transcriptGap(MARK_MESSAGE, MARK_STATUS), 1);
    expect(actual.footerUnderReply).toBeCloseTo(gridLength("gap-footer"), 1);
    expect(actual.user).toBeCloseTo(gridLength("gap-turn"), 1);
    expect(actual.paddings).toEqual([0, 0, 0, 0]);
    await page.close();
  });
  test("public gallery before/after capture", async () => {
    const output = process.env.CMUX_SPACING_CAPTURE;
    if (!output) return;
    await mkdir(output, { recursive: true });
    for (const variant of ["shipped", "two-thirds", "half-tucked"]) {
      const page = await open(variant);
      await page.screenshot({ path: path.join(output, `${variant}.png`) });
      await page.close();
    }
  });
});
