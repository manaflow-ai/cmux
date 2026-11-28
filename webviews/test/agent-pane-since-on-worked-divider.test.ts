// The unread "New" mark over the next turn's "Worked for" line (look B, unread.css) lights that
// line's own divider and draws no rule of its own: one line, where the divider always is, and no row
// moves. Leo, 2026-11-22 (manaflow-ai/cmux#51002), on a New rule drawn a few pixels above the
// toggle's divider: "they should be in the same place.. just put the new stuff where the divider
// should be in the first place." The mark's own rule sat at the bottom of the line's words, while the
// toggle's divider sits a foot gap lower (.cv-worked.has-divider.is-toggle), so two lines showed.
//
// Real Chromium from Playwright on the gallery stage `agent-pane.since-divider`, whose Worked for
// line carries the transcript's own toggle classes.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-since-on-worked-divider.test.ts", async () => {
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
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "line-worked" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Shot = {
    worked: { top: number; bottom: number };
    divider: { top: number; height: number; color: string };
    accent: string;
    rules: { top: number; height: number }[];
    tag?: { top: number; bottom: number };
    /// The tag is painted, not cut by the row's paint containment: the point at its centre hits it.
    tagHit?: boolean;
    /// The computed font sizes of the line's words and of the tag ("2 new messages", "New").
    font: { worked: string; tag?: string };
  };

  async function measure(page: Page, variant: string): Promise<Shot> {
    await page.goto(url(variant));
    const worked = page.locator(":is(.acpmux-worked, .acpmux-working) .cv-worked");
    await worked.waitFor();
    return await page.evaluate(() => {
      const line = document.querySelector<HTMLElement>(":is(.acpmux-worked, .acpmux-working) .cv-worked")!;
      const box = line.getBoundingClientRect();
      const after = getComputedStyle(line, "::after");
      const height = parseFloat(after.height);
      const bottom = parseFloat(after.bottom);
      // The accent as the page resolves it: a probe painted with the token the mark reads.
      const probe = document.createElement("span");
      probe.style.color = "var(--cmux-app-accent)";
      line.parentElement!.appendChild(probe);
      const accent = getComputedStyle(probe).color;
      probe.remove();
      // Every rule the mark itself paints (a border or a box) that is on screen.
      const rules = [...document.querySelectorAll<HTMLElement>(".cv-since__rule")]
        .filter((rule) => rule.getClientRects().length > 0 && getComputedStyle(rule).opacity !== "0")
        .map((rule) => {
          const r = rule.getBoundingClientRect();
          return { top: r.top, height: r.height };
        });
      const tagNode = document.querySelector<HTMLElement>(".cv-since[data-shown] .cv-since__tag");
      const tag = tagNode?.getBoundingClientRect();
      const hit = tag && document.elementFromPoint(tag.left + tag.width / 2, tag.top + tag.height / 2);
      return {
        worked: { top: box.top, bottom: box.bottom },
        divider: { top: box.bottom - bottom - height, height, color: after.backgroundColor },
        accent,
        rules,
        tag: tag && { top: tag.top, bottom: tag.bottom },
        tagHit: !!hit && !!hit.closest(".cv-since"),
        font: {
          worked: getComputedStyle(line).fontSize,
          tag: tagNode ? getComputedStyle(tagNode).fontSize : undefined,
        },
      };
    });
  }

  for (const [name, bare, marked] of [
    ["Worked for", "no-line", "line-worked"],
    ["the running Working for", "no-line-working", "line-working"],
  ] as const)
    test(`New lights ${name} line's divider in place and draws no second line`, async () => {
      const page = await browser.newPage({ viewport: { width: 640, height: 400 }, reducedMotion: "reduce" });
      try {
        const plain = await measure(page, bare);
        const lit = await measure(page, marked);
        // One line: the mark paints no rule of its own over a Worked for line.
        expect(lit.rules).toEqual([]);
        // That line is the divider, lit in the accent, where the divider is with no mark at all.
        expect(lit.divider.color).toBe(lit.accent);
        expect(plain.divider.color).not.toBe(plain.accent);
        expect(lit.divider.top).toBe(plain.divider.top);
        expect(lit.divider.height).toBe(plain.divider.height);
        // No layout shift: the Worked for line keeps its place.
        expect(lit.worked).toEqual(plain.worked);
        // "New" sits on the line's words, above the divider, never under it.
        expect(lit.tag).toBeDefined();
        expect(lit.tag!.top).toBeGreaterThanOrEqual(lit.worked.top);
        expect(lit.tag!.bottom).toBeLessThanOrEqual(lit.divider.top);
        // One type size on the one line: "2 new messages" is the Working for words' size, the row
        // metric, not the prose size a pixel larger (Leo, 2026-11-27: "the font size on working for
        // and new messages is different" / "just make new messages the same size as normal stuff").
        expect(lit.font.tag).toBe(lit.font.worked);
        // And it is painted there: the mark lies past its 0 px row's box, and a row that clipped its
        // paint (styles.css .acpmux-row, contain: paint) cut it off, leaving only the lit divider.
        expect(lit.tagHit).toBe(true);
      } finally {
        await page.close();
      }
    });

  test("read, the divider is the plain rule again", async () => {
    const page = await browser.newPage({ viewport: { width: 640, height: 400 }, reducedMotion: "reduce" });
    try {
      const plain = await measure(page, "no-line");
      const read = await measure(page, "line-read");
      expect(read.rules).toEqual([]);
      expect(read.tag).toBeUndefined();
      expect(read.divider).toEqual(plain.divider);
    } finally {
      await page.close();
    }
  });
});
