// cmux-web-test-timeout: 420
// New Tab's composer keeps its place now that the page has no greeting (Leo 2026-10-22: "new tab
// page let's have no greeting text by default... maybe as toggle but as useful toggle"). Under the
// old greeting the composer's top sat the greeting's box (its heading line and the 6px under it)
// plus the page's gap below the page's top padding; removing the greeting must not lift it, and
// turning the headline on (any look, with or without a project) must not move it either.
//
// Someone who had turned the greeting off (`"greeting": false` saved in cmux.json, sent as
// `headlineOff`) had the composer at the page's top padding; it stays there for them.
//
// Also: the headline gallery entry's Compare arms (agent-pane.new-tab-headline) starts from every
// variant, each arm reaching its first step, so the comparison view has a picker to drive.
//
// Real Chromium on the gallery's dev server; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-headline-place.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-headline-place: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab headline place", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRIES = ["agent-pane.new-tab", "agent-pane.new-tab-headline"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRIES, { browser, timeoutMs: 240_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// One gallery stage, ready (or failed), in its own page.
  async function open(entry: string, params: Record<string, string>): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, params)}`);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryReady), undefined, {
      timeout: 90_000,
    });
    return page;
  }

  /// Where the composer's top sits under the page's top padding, and the old greeting's box: its
  /// heading line plus the 6px under it plus the page's gap (what the composer sat under).
  const place = (page: Page) =>
    page.evaluate(() => {
      const screen = document.querySelector<HTMLElement>(".nt-screen")!;
      const style = getComputedStyle(screen);
      const probe = document.createElement("p");
      probe.style.lineHeight = "var(--text-heading--line-height)";
      screen.append(probe);
      const heading = parseFloat(getComputedStyle(probe).lineHeight);
      probe.remove();
      const composer = document.querySelector(".nt-composer")!.getBoundingClientRect().top;
      return {
        minimal: screen.hasAttribute("data-minimal"),
        headline: document.querySelector(".nt-headline-text")?.textContent ?? null,
        offset: composer - screen.getBoundingClientRect().top - parseFloat(style.paddingTop),
        old: heading + 6 + parseFloat(style.rowGap),
      };
    });

  test("the composer sits where it sat under the greeting, with the headline off and on", async () => {
    const cases: [string, Record<string, string>][] = [
      ["agent-pane.new-tab", { variant: "minimal-default" }],
      ["agent-pane.new-tab-headline", { variant: "on" }],
      ["agent-pane.new-tab-headline", { variant: "picked" }],
      ["agent-pane.new-tab-headline", { variant: "picked", exp: "new-tab-headline", arm: "quiet" }],
      ["agent-pane.new-tab-headline", { variant: "picked", exp: "new-tab-headline", arm: "chip" }],
    ];
    const seen: unknown[] = [];
    for (const [entry, params] of cases) {
      const page = await open(entry, params);
      try {
        expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
        const measured = await place(page);
        seen.push({ entry, ...params, ...measured });
        expect(measured.minimal).toBe(true);
        expect(measured.headline === null).toBe(entry === "agent-pane.new-tab");
        expect(Math.abs(measured.offset - measured.old)).toBeLessThan(0.5);
      } finally {
        await page.close();
      }
    }
    console.log("new-tab-headline-place", JSON.stringify(seen));
  });

  test("a greeting set to false keeps the composer where it sat with the greeting off", async () => {
    const page = await open("agent-pane.new-tab", { variant: "minimal-headline-off" });
    try {
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
      const measured = await place(page);
      console.log("new-tab-headline-place headline-off", JSON.stringify(measured));
      expect(measured.minimal).toBe(true);
      expect(measured.headline).toBeNull();
      expect(await page.locator(".nt-headline-slot").count()).toBe(0);
      // With the greeting off the composer was the page's first row, at its top padding.
      expect(Math.abs(measured.offset)).toBeLessThan(0.5);
    } finally {
      await page.close();
    }
  });

  test("Compare arms starts from every headline variant and runs its first step in every arm", async () => {
    for (const variant of ["on", "picked", "picker-open"])
      for (const arm of ["hero", "quiet", "chip"]) {
        const page = await open("agent-pane.new-tab-headline", { variant, exp: "new-tab-headline", arm, step: "1" });
        try {
          const state = await page.evaluate(() => ({
            ready: document.documentElement.dataset.galleryReady,
            error: document.documentElement.dataset.galleryReady === "error" ? document.body.textContent : null,
            menu: document.querySelector(".acpmux-project-menu") !== null,
            headline: document.querySelector(".nt-headline-text")?.textContent ?? null,
          }));
          expect({ variant, arm, ...state }).toEqual({
            variant,
            arm,
            ready: "1",
            error: null,
            menu: true,
            headline: "What should we work on in cmux?",
          });
        } finally {
          await page.close();
        }
      }
  });

  test("the first variant, where Compare arms opens, draws the headline", async () => {
    const page = await open("agent-pane.new-tab-headline", {});
    try {
      expect(await page.locator(".nt-headline .acpmux-project-button").count()).toBeGreaterThan(0);
    } finally {
      await page.close();
    }
  });
});
