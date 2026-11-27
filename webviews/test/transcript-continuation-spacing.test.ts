// l10n-allow-file: public gallery fixture and geometry assertions.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { gridLength, TRANSCRIPT_FOOTER_CONTROL } from "../src/agent-session/acpmux/transcriptGrid";
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
      return {
        // Reply to reply: each finished reply keeps its action row under it, the footer gap below
        // it, and the same agent's next reply comes the block gap after that row (Leo, 2026-11-14:
        // "the copy sometimes disappears entirely? which causes big shifts. it happens often when
        // scrolling up and stuff loads": these replies come before any prompt, as a history page
        // that starts mid-chat draws them, and their rows were missing until the prompt paged in).
        same: box("b").top - box("footer-a").bottom,
        rowUnderReply: box("footer-a").top - box("a").bottom,
        replyFooters: ["footer-a", "footer-b"].map((id) => ({
          actions: Boolean(node(id).querySelector(".cv-turn-actions:not(.cv-turn-actions--empty)")),
          height: box(id).height,
        })),
        // Another agent's line opens its own turn under that turn's "Worked for" head (66beef47be6,
        // #49052): the head is the row under the footer, so the gap is measured to it.
        peer:
          document.querySelector('[data-row-id="worked-continuation-peer"]')!.getBoundingClientRect().top -
          box("footer-b").bottom,
        footerUnderReply: box("footer-c").top - box("c").bottom,
        user: box("user").top - actions("footer-c").bottom,
        paddings: ["footer-a", "footer-b", "footer-c", "footer-d"].map((id) =>
          parseFloat(getComputedStyle(node(id)).paddingBottom),
        ),
      };
    });
  // The virtual stack owns every gap between rows (#27580, design/grid.md 5.5): the same agent's next
  // reply takes the block gap, a prompt the turn gap, and a reply's footer row sits the footer gap
  // under it; every finished reply keeps that row, those before the first prompt too. Another agent's
  // line under a footer row keeps the block gap (transcriptGrid.ts footer-to-received); after a bare
  // reply it is a status row (model.ts isStatusRow) and sits the run gap
  // from the reply over it (#31879, design/transcript-spacing.md rule 4). The half gap between one
  // agent's replies (#26755) and the footer's centring drop inside its row (#29860) went with #27580;
  // rows carry no padding of their own.
  test("each finished reply keeps its action row; the same assistant's next reply and another agent's line take the block gap; a prompt keeps the turn gap", async () => {
    const page = await open();
    await page.waitForFunction(
      () => document.querySelector('[data-row-id="continuation-b"]')!.getBoundingClientRect().top > 0,
    );
    const actual = await measure(page);
    expect(actual.same).toBeCloseTo(gridLength("gap-block"), 1);
    expect(actual.rowUnderReply).toBeCloseTo(gridLength("gap-footer"), 1);
    expect(actual.replyFooters).toEqual([
      { actions: true, height: TRANSCRIPT_FOOTER_CONTROL },
      { actions: true, height: TRANSCRIPT_FOOTER_CONTROL },
    ]);
    // Under a reply's footer row the turn another agent's line opens keeps the block gap
    // (transcriptGrid.ts footer-to-received), its "Worked for" head first (66beef47be6).
    expect(actual.peer).toBeCloseTo(gridLength("gap-block"), 1);
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
