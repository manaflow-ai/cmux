// A reply's footer: its buttons first, on the prose's left edge, and its time after them, shown on
// hover; the finished chat's last reply keeps its buttons in sight at rest.
//
// Leo, 2026-11-02: "this should not be placed in front of the copy/whatever buttons. those buttons
// should always just be there left aligned"; "i should be able to see the copy buttons on your
// responses when your things end"; and on ChatGPT's row: "notice how on hover it reveals the exact
// timestamp. let's follow those."
//
// In gallery entry agent-pane.transcript-row-alignment, light and dark:
// - `footer` (the pointer on the first turn's footer): every footer's first element is its button
//   group, and its first glyph's box (the 16px icon box, design/grid.md 5.5) starts on the prose's
//   left edge, for a turn whose time and tokens are known (they go in the time's tooltip) and for
//   one without them;
// - `finished` (a finished chat, no pointer): the last reply's buttons show at rest, its time is
//   hidden; pointed at, the time shows after the last button and the buttons do not move.
//
// CMUX_REPLY_FOOTER_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes 2x stills of the
// last reply and its footer, at rest and pointed at, in each theme.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reply-footer.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-row-alignment";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  /** How far apart two edges may be, in CSS px. */
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("reply footer", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "finished" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, theme: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 900, height: 1200 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 720, theme, reducedMotion: "true" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  const artifacts = process.env.CMUX_REPLY_FOOTER_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;
  /** A 2x still of the chat's last reply and its footer, with room around them. */
  const still = async (page: Page, name: string) => {
    if (!artifacts) return;
    const box = await page.evaluate(() => {
      const footer = document.querySelector(".acpmux-row--final-footer")!.getBoundingClientRect();
      const replies = [...document.querySelectorAll(".acpmux-row.acpmux-assistant")];
      const reply = replies.at(-1)!.getBoundingClientRect();
      const top = Math.max(0, reply.top - 24);
      return { x: Math.max(0, reply.left - 24), y: top, width: reply.width + 48, height: footer.bottom + 32 - top };
    });
    await mkdir(artifacts, { recursive: true });
    await page.screenshot({ path: path.join(artifacts, `reply-footer-${name}.png`), clip: box });
  };

  type Footer = {
    first: string;
    glyph: number | undefined;
    detail: string | null;
    buttons: number[];
    lastButtonRight: number;
    actionsOpacity: number;
    time: { left: number; opacity: number } | undefined;
  };

  /** Each turn footer's row, measured from its transcript row's left edge (the prose's). */
  const footers = (page: Page, scope = ".acpmux-turnSummary"): Promise<Footer[]> =>
    page.evaluate((scope) => {
      const found: Footer[] = [];
      for (const row of document.querySelectorAll<HTMLElement>(scope)) {
        const actions = row.querySelector<HTMLElement>(".cv-turn-actions:not(.cv-turn-actions--empty)");
        const line = actions?.querySelector(".cv-turn-footer-row");
        if (!actions || !line) continue;
        const left = row.getBoundingClientRect().left;
        const group = line.querySelector(".cv-turn-action-group");
        const glyph = group?.querySelector(".cv-iconbtn svg");
        const buttons = [...(group?.querySelectorAll(".cv-iconbtn") ?? [])];
        const time = line.querySelector<HTMLElement>(".cv-turn-time");
        found.push({
          first: line.firstElementChild?.className ?? "",
          glyph: glyph ? glyph.getBoundingClientRect().left - left : undefined,
          detail: time?.getAttribute("title") ?? null,
          buttons: buttons.map((button) => button.getBoundingClientRect().left - left),
          lastButtonRight: buttons.length ? buttons.at(-1)!.getBoundingClientRect().right - left : 0,
          actionsOpacity: Number(getComputedStyle(actions).opacity),
          time: time
            ? { left: time.getBoundingClientRect().left - left, opacity: Number(getComputedStyle(time).opacity) }
            : undefined,
        });
      }
      return found;
    }, scope);

  for (const theme of THEMES) {
    test(`a footer's buttons come first, the first glyph on the prose's left edge (${theme.name})`, async () => {
      const page = await open("footer", theme.name);
      try {
        await page.locator(".acpmux-turnSummary .cv-turn-action-group").first().waitFor();
        const measured = await footers(page);
        console.log(`REPLY_FOOTER ${theme.file} footer ${JSON.stringify(measured)}`);
        // The first turn's footer knows its time and tokens; the folded turn's footer does not.
        const withStats = measured.filter((footer) => footer.detail?.includes("Worked for"));
        const without = measured.filter((footer) => !footer.detail);
        expect(withStats.length, "a footer with the turn's time and tokens").toBeGreaterThan(0);
        expect(without.length, "a footer without them").toBeGreaterThan(0);
        for (const footer of withStats) expect(footer.detail).toMatch(/Worked for 5s · ↓ .+ out ↑ .+ in/);
        for (const footer of measured) {
          expect(footer.first).toContain("cv-turn-action-group");
          expect(footer.glyph).toBeDefined();
          expect(
            Math.abs(footer.glyph!),
            `first glyph at ${footer.glyph}px, not on the prose's edge`,
          ).toBeLessThanOrEqual(TOLERANCE);
          // The time comes after the last button.
          expect(footer.time!.left).toBeGreaterThanOrEqual(footer.lastButtonRight - TOLERANCE);
        }
        expect(await page.locator(".cv-turn-summary").count()).toBe(0);
      } finally {
        await page.close();
      }
    });

    test(`a finished chat's last reply shows its buttons at rest and its time on hover (${theme.name})`, async () => {
      const page = await open("finished", theme.name);
      try {
        const last = ".acpmux-turnSummary.acpmux-row--final-footer";
        await page.locator(`${last} .cv-turn-action-group`).waitFor();
        await page.mouse.move(1, 1);
        const [rest] = await footers(page, last);
        console.log(`REPLY_FOOTER ${theme.file} rest ${JSON.stringify(rest)}`);
        await still(page, `${theme.file}-rest`);
        expect(rest, "the chat's last footer").toBeDefined();
        expect(rest!.buttons.length).toBeGreaterThan(0);
        expect(rest!.actionsOpacity).toBe(1);
        expect(rest!.time!.opacity).toBe(0);
        expect(Math.abs(rest!.glyph!)).toBeLessThanOrEqual(TOLERANCE);
        await page.hover(`${last} .cv-turn-action-group`);
        await page.waitForFunction(
          (selector) => getComputedStyle(document.querySelector(`${selector} .cv-turn-time`)!).opacity === "1",
          last,
          { timeout: 10_000 },
        );
        const [hover] = await footers(page, last);
        console.log(`REPLY_FOOTER ${theme.file} hover ${JSON.stringify(hover)}`);
        await still(page, `${theme.file}-hover`);
        expect(hover!.time!.opacity).toBe(1);
        expect(hover!.time!.left).toBeGreaterThanOrEqual(hover!.lastButtonRight - TOLERANCE);
        expect(hover!.buttons).toEqual(rest!.buttons);
        // Earlier footers stay hidden at rest: only the last reply's row is in sight.
        await page.mouse.move(1, 1);
        const earlier = await footers(page, ".acpmux-turnSummary:not(.acpmux-row--final-footer)");
        for (const footer of earlier) expect(footer.actionsOpacity).toBe(0);
      } finally {
        await page.close();
      }
    });
  }
});
