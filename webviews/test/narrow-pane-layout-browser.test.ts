// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
//
// Key agent pane states at narrow pane widths, screenshotted in real Chromium on the gallery frame,
// fail on a new overlap or ellipsis (src/gallery/narrowLayout.ts). Leo, 2026-11-22: "ok, so simply
// prepare for this scenario beforehand and lay things out better". Per-surface narrow tests
// (sent-row-narrow, thread-rail-narrow-gutter, permission-ask-row-narrow, ...) each caught one
// regression after it shipped; this one holds every key pane to the same two rules before merge.
//
// narrow-pane-layout-baseline.json lists, for each case (entry@width), the violation kinds it has
// today (designed cuts, such as a long path in a 320 px pane). A violation the row does not list
// fails, so the PR that makes one more label give way, or one more control land on a title, is the
// one that is caught. A case with no row fails too, printing the row to add. Rows only shrink: a
// listed kind the run no longer shows is printed so its line can go.
//
// Screenshots go to webviews/test-results/narrow-pane-layout/ (react-apps-check uploads them).
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { narrowKeyKind, type NarrowViolation } from "../src/gallery/narrowLayout";
import baseline from "./narrow-pane-layout-baseline.json";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("narrow-pane-layout-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  // The panes a person sees in every chat: header, transcript, composer and its hat, the find bar,
  // the home lists and Session Info. Each at its default variant.
  const CASES = [
    "agent-pane.header",
    "agent-pane.transcript",
    "agent-pane.composer",
    "agent-pane.composer-hat",
    "agent-pane.chat-find-bar",
    "agent-pane.home-lists",
    "agent-pane.session-info-narrow-pane",
  ];
  // The gallery's narrow preset (env.ts WIDTHS.narrow) and the narrowest pane a split leaves.
  const WIDTHS = [320, 420];
  const HEIGHT = 720;
  const rows = (baseline as { cases: Record<string, string[]> }).cases;
  const shots = path.resolve(import.meta.dir, "..", "test-results", "narrow-pane-layout");
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  function frame(width: number) {
    return { width, height: HEIGHT, reducedMotion: "1" };
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE } : {}),
    });
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: frame(420) });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(entry: string, width: number, shot: string): Promise<NarrowViolation[]> {
    const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
    try {
      const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
      await page.goto(base + galleryFrame(entry, frame(width)));
      await page.waitForFunction(
        () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
        undefined,
        { timeout: 90_000 },
      );
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
      await page.evaluate(async () => {
        await document.fonts.ready;
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      });
      await page.screenshot({ path: shot, fullPage: false });
      return await page.evaluate(() => window.cmuxGalleryNarrowLayout?.() ?? []);
    } finally {
      await page.close();
    }
  }

  describe("key agent panes at narrow widths: no overlap, no new ellipsis", () => {
    for (const entry of CASES)
      for (const width of WIDTHS)
        test(`${entry} at ${width}px`, async () => {
          const name = `${entry}@${width}`;
          const shot = path.join(shots, `${name}.png`);
          // A violation counts only when a second load shows it too (a font still swapping in).
          const first = await measure(entry, width, shot);
          const again = first.length ? await measure(entry, width, shot) : [];
          const kinds = new Map<string, NarrowViolation>();
          for (const violation of first)
            if (again.some((other) => other.key === violation.key)) kinds.set(narrowKeyKind(violation.key), violation);
          const row = rows[name];
          if (!row) {
            console.log(`NARROW_LAYOUT_ROW ${JSON.stringify({ [name]: [...kinds.keys()].sort() })}`);
            throw new Error(
              `${name} has no row in narrow-pane-layout-baseline.json; add the NARROW_LAYOUT_ROW line above once its screenshot (${shot}) is right`,
            );
          }
          const listed = new Set(row);
          for (const kind of listed)
            if (!kinds.has(kind)) console.log(`${name}: fixed, drop from the baseline: ${JSON.stringify(kind)}`);
          const added = [...kinds].filter(([kind]) => !listed.has(kind)).map(([, violation]) => violation.detail);
          if (added.length) console.log(`NARROW_LAYOUT_ROW ${JSON.stringify({ [name]: [...kinds.keys()].sort() })}`);
          expect(added).toEqual([]);
        });
  });
});
