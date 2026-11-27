// l10n-allow-file: gallery fixture names are test data.
// The composer hat's one-line strip (HatHeadDeck.tsx, SubagentTray.tsx, subagents.css) in real Chromium
// (Playwright; CI fails the file when it cannot launch, requireBrowserLane). Leo, 2026-11-27, on the
// strip of "14 subagents workin…" with its marks and "+12 more": "dont put this garish blue in man we
// dont need it to be blue or highlighted" and "overlapping text here what do we doooo" (the panel
// button drawn over the "mo" of "+12 more"); then "hm should we compact these and drop them away in
// favour of text when things shrink?" and "this is just an awkward looking layout".
//
// The detector for cmuxterm-hq docs/handbook `undeclared-layout-move`'s overlap half: every control and
// every word in the row owns a box no other one enters, at every pane width and any count. A geometry
// assertion, so it fails on the pixels and never on a class name:
//   - the panel button, the "+N more", the marks and the words share the row without their boxes
//     intersecting, and "+N more" is never clipped by the row's end;
//   - the words are the plain muted ink on no background in every state (rest, hover, focus, open);
//   - the marks and "+N more" show only when they fit beside the whole sentence; too narrow, they drop
//     away (never half-drawn), and the words are then whole;
//   - the "+N more" follows the last mark with no gap of empty slots between them.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-strip-plain.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.composer-hat-line";
  // Where to leave a screenshot of each case (the before/after proof); unset in CI.
  const shots = process.env.SUBAGENT_STRIP_SHOTS;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "marks" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  type Box = { left: number; right: number; top: number; bottom: number };
  type Strip = {
    row: Box;
    title: (Box & { whole: boolean; ink: string; fill: string }) | null;
    deckDrawn: boolean;
    rest: Box | null;
    marks: Box[];
    open: Box | null;
    hide: Box | null;
  };

  const settle = (page: Page) =>
    page.evaluate(() => {
      for (const animation of document.getAnimations()) {
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
      }
    });

  const measure = (page: Page): Promise<Strip> =>
    page.evaluate(() => {
      const box = (node: Element | null | undefined) => {
        if (!node) return null;
        const rect = node.getBoundingClientRect();
        return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom };
      };
      const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
      const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      const title = head.querySelector<HTMLElement>(".acpmux-running-tray__title");
      const deck = head.querySelector<HTMLElement>(".acpmux-hat-deck");
      const drawn = Boolean(deck && deck.dataset.fit !== "off");
      const style = title ? getComputedStyle(title) : null;
      return {
        row: box(head)!,
        title: title
          ? {
              ...box(title)!,
              whole: title.scrollWidth <= title.clientWidth + 0.5,
              ink: style!.color,
              fill: style!.backgroundColor,
            }
          : null,
        deckDrawn: drawn,
        rest: drawn ? box(deck!.querySelector(".acpmux-hat-deck__rest")) : null,
        marks: drawn ? [...deck!.querySelectorAll(".acpmux-hat-deck__mark")].map((mark) => box(mark)!) : [],
        open: box(tray.querySelector(".acpmux-running-tray__open")),
        hide: box(tray.querySelector(".acpmux-hat-hide")),
      };
    });

  const meets = (a: Box, b: Box) =>
    Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
    Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;

  const open = async (page: Page, variant: string, width: number, theme: string) => {
    const port = (server.httpServer!.address() as { port: number }).port;
    await page.setViewportSize({ width, height: 420 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-running-tray__head").first().waitFor();
    await page.locator(".acpmux-hat-deck").first().waitFor({ state: "attached" });
    await settle(page);
  };

  // Narrow pane to wide, light and dark; the folded strip and the open one (panel button).
  for (const width of [240, 280, 340, 400, 520, 900]) {
    for (const variant of ["marks", "marks-open"]) {
      for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
        test(`the strip's words, marks, "+N more" and panel button never overlap: ${variant} at ${width}px (${theme})`, async () => {
          const page = await browser.newPage({ deviceScaleFactor: 2, reducedMotion: "reduce" });
          try {
            await open(page, variant, width, theme);
            const strip = await measure(page);
            if (shots) {
              await mkdir(shots, { recursive: true });
              await page.screenshot({
                path: path.join(shots, `${variant}-${width}-${theme.includes("Light") ? "light" : "dark"}.png`),
              });
            }
            expect(strip.hide).toBeNull();
            const parts: Array<readonly [string, Box]> = [];
            if (strip.title) parts.push(["words", strip.title]);
            strip.marks.forEach((box, index) => parts.push([`mark ${index}`, box]));
            if (strip.rest) parts.push(["+N more", strip.rest]);
            if (strip.open) {
              expect(strip.open.left).toBeGreaterThanOrEqual(strip.row.left - 0.5);
              expect(strip.open.right).toBeLessThanOrEqual(strip.row.right + 0.5);
              parts.push(["panel button", strip.open]);
            }
            // No two parts' boxes intersect, and every drawn part lies inside the row.
            for (const [name, box] of parts) {
              expect([name, box.right <= strip.row.right + 0.5]).toEqual([name, true]);
              expect([name, box.left >= strip.row.left - 0.5]).toEqual([name, true]);
            }
            for (let i = 0; i < parts.length; i += 1) {
              for (let j = i + 1; j < parts.length; j += 1) {
                expect([parts[i]![0], parts[j]![0], meets(parts[i]![1], parts[j]![1])]).toEqual([
                  parts[i]![0],
                  parts[j]![0],
                  false,
                ]);
              }
            }
            // Drawn at all only when the whole sentence is there beside it.
            if (strip.deckDrawn && strip.title) expect(strip.title.whole).toBe(true);
            // "+N more" follows the last mark with no empty slots between: one gap, never a hole.
            if (strip.rest && strip.marks.length > 0) {
              const last = strip.marks[strip.marks.length - 1]!;
              expect(strip.rest.left - last.right).toBeLessThanOrEqual(12);
            }
          } finally {
            await page.close();
          }
        });
      }
    }
  }

  test("the strip compacts with the width: marks and '+N more' at a wide pane, text alone at a narrow one", async () => {
    const page = await browser.newPage({ deviceScaleFactor: 2, reducedMotion: "reduce" });
    try {
      await open(page, "marks", 900, "Apple System Colors");
      const wide = await measure(page);
      expect(wide.deckDrawn).toBe(true);
      expect(wide.title!.whole).toBe(true);
      await open(page, "marks", 240, "Apple System Colors");
      const narrow = await measure(page);
      expect(narrow.deckDrawn).toBe(false);
      expect(narrow.marks.length).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("the words are plain at rest, hovered, focused and open: the muted ink, on no background", async () => {
    const page = await browser.newPage({ deviceScaleFactor: 2, reducedMotion: "reduce" });
    try {
      await open(page, "marks", 900, "Apple System Colors");
      const rest = await measure(page);
      expect(rest.title).not.toBeNull();
      const plain = (strip: Strip) => {
        expect(strip.title!.ink).toBe(rest.title!.ink);
        // No fill: a transparent background, whatever the state.
        expect(strip.title!.fill === "rgba(0, 0, 0, 0)" || strip.title!.fill === "transparent").toBe(true);
      };
      plain(rest);
      await page.locator(".acpmux-running-tray__head").hover();
      await settle(page);
      plain(await measure(page));
      await page.locator(".acpmux-running-tray__head").focus();
      await settle(page);
      plain(await measure(page));
      await page.locator(".acpmux-running-tray__head").click();
      await page.locator(".acpmux-running-tray__list > li").first().waitFor();
      await settle(page);
      plain(await measure(page));
    } finally {
      await page.close();
    }
  });
});
