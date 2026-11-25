// The unread "New" mark over a row with no "Worked for" divider (look B, unread.css), such as a
// "Background task finished" line, draws its own rule centred in the gap between the rows, and "New"
// sits on that rule's centre line: the space above the rule equals the space under it, and no row
// moves. manaflow-ai/cmux#51747 (user, 2026-11-22, on a rule pinned under the action icons with
// "New" hanging below it at the next row's top: "we need to make sure space top and space down is
// the same").
//
// Real Chromium from Playwright on the gallery stage `agent-pane.since-divider`.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-since-centered-in-gap.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.since-divider";
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "line-task" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Box = { top: number; bottom: number };
  type Shot = { above: Box; next: Box; rules: Box[]; tag?: Box };

  async function measure(page: Page, variant: string): Promise<Shot> {
    await page.goto(url(variant));
    await page.locator(".cv-task-line").waitFor();
    return await page.evaluate(() => {
      const box = (node: Element) => {
        const r = node.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom };
      };
      // The line's row is the stage's 0 px `.acpmux-row` with no task line in it; the row above is
      // the reply before it, the next row the task line's.
      const next = document.querySelector(".acpmux-system")!;
      const lineRow = next.previousElementSibling!;
      const above = lineRow.previousElementSibling!;
      const rules = [...document.querySelectorAll<HTMLElement>(".cv-since__rule")]
        .filter((rule) => rule.getClientRects().length > 0 && getComputedStyle(rule).opacity !== "0")
        .map(box);
      const tag = document.querySelector(".cv-since[data-shown] .cv-since__tag");
      return { above: box(above), next: box(next), rules, tag: tag ? box(tag) : undefined };
    });
  }

  const mid = (b: Box) => (b.top + b.bottom) / 2;

  test("New over a Background task finished line: rule centred in the gap, through New's centre", async () => {
    const page = await browser.newPage({ viewport: { width: 640, height: 400 }, reducedMotion: "reduce" });
    try {
      const plain = await measure(page, "no-line-task");
      const lit = await measure(page, "line-task");
      // No layout shift: the rows sit where they sit with no mark at all.
      expect(lit.above).toEqual(plain.above);
      expect(lit.next).toEqual(plain.next);
      // One rule, the mark's own.
      expect(lit.rules).toHaveLength(1);
      const rule = lit.rules[0]!;
      // Equal space above and below: the rule lies in the middle of the gap between the rows.
      expect(Math.abs(rule.top - lit.above.bottom - (lit.next.top - rule.bottom))).toBeLessThanOrEqual(1);
      // "New" on the rule's centre line, not hanging under it.
      expect(lit.tag).toBeDefined();
      expect(Math.abs(mid(lit.tag!) - mid(rule))).toBeLessThanOrEqual(1);
    } finally {
      await page.close();
    }
  });
});
