// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// No chip or strip in the chat cuts its text mid-word (support/hardClip.ts). Leo, 2026-11-22, on the
// composer hat's "53 subagents running · 5 waits · 5 commands · 8 done · 5 stc": "this should not be
// cutting off so harshly like this. we basically never want that kinda shit"; on a started line of
// seven chips cut to "M…", "iO…", "i…": "this is so fucking awkward as ui"; and on the unverified
// sender's 12px question bubble: "too small/weird/not really representative".
//
// First the detector itself, on a page of its own: it flags "5 stopped" cut to "5 stc" by a strip's
// overflow and a name ellipsized to two letters, and passes an ellipsis that keeps a word, a fade and a
// segment dropped whole onto a hidden line. Then each surface, in real Chromium on its gallery frame at
// the chat pane's narrow width: the composer hat's kinds strip folded with every kind, the started
// line's group of seven (folded and opened, two, one), and a claimed sender's line. CI fails the file
// when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { findHardClips } from "./support/hardClip";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("no-hard-clip-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  /// Each surface: entry, variant, the pane width, what to do first, and the part of the page to scan.
  const SURFACES: {
    name: string;
    entry: string;
    variant: string;
    width: number;
    root: string;
    before?: (page: Page) => Promise<void>;
  }[] = [
    {
      name: "the composer hat's kinds strip, folded, every kind",
      entry: "agent-pane.subagent-tray-kinds",
      variant: "folded",
      width: 360,
      root: ".acpmux-running-tray__head",
    },
    {
      name: "the composer hat's kinds strip, folded, at 420px",
      entry: "agent-pane.subagent-tray-kinds",
      variant: "folded",
      width: 420,
      root: ".acpmux-running-tray__head",
    },
    {
      name: "the composer hat's header with eleven things of every kind, folded",
      entry: "agent-pane.subagent-tray-command-kinds",
      variant: "every-kind",
      width: 360,
      root: ".acpmux-running-tray__head",
    },
    {
      name: "the composer hat's header with eleven things of every kind, folded, at 420px",
      entry: "agent-pane.subagent-tray-command-kinds",
      variant: "every-kind",
      width: 420,
      root: ".acpmux-running-tray__head",
    },
    {
      name: "seven subagents started",
      entry: "agent-pane.subagent-started-line",
      variant: "seven",
      width: 420,
      root: "[data-started-line-gallery]",
    },
    {
      name: "seven subagents started, opened",
      entry: "agent-pane.subagent-started-line",
      variant: "seven",
      width: 420,
      root: "[data-started-line-gallery]",
      before: async (page) => {
        await page.locator(".cv-subagent-started.is-count").click();
        await page.locator(".cv-subagent-started__names").waitFor();
      },
    },
    {
      name: "two subagents started",
      entry: "agent-pane.subagent-started-line",
      variant: "two",
      width: 420,
      root: "[data-started-line-gallery]",
    },
    {
      name: "a claimed sender's line",
      entry: "agent-pane.verified-sender",
      variant: "claimed",
      width: 420,
      root: "[data-verified-sender]",
    },
  ];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [...new Set(SURFACES.map((surface) => surface.entry))], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("the detector", () => {
    test("flags a strip that cuts a word and a name ellipsized to two letters; passes ellipsis, fade and a dropped segment", async () => {
      const page = await browser!.newPage({ viewport: { width: 600, height: 300 } });
      try {
        await page.setContent(`<!doctype html><style>
          body { font: 14px sans-serif; margin: 0; }
          .strip { display: inline-flex; width: 220px; overflow: hidden; white-space: nowrap; }
          .strip > span { flex: none; }
          .tag { display: inline-block; width: 22px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .ok { display: block; width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .fade { display: block; width: 120px; overflow: hidden; white-space: nowrap; mask-image: linear-gradient(to right, black 70%, transparent); }
          .wrap { display: flex; flex-wrap: wrap; width: 160px; height: 18px; line-height: 18px; overflow: hidden; white-space: nowrap; }
          .wrap > span { flex: none; }
        </style>
        <div id="cut"><div class="strip"><span>53 subagents running</span><span>&nbsp;·&nbsp;8 done</span><span>&nbsp;·&nbsp;5 stopped</span></div></div>
        <div id="tiny"><span class="tag">Mac grant switch</span></div>
        <div id="ok"><span class="ok">Experiment registry sweep across every page</span></div>
        <div id="fade"><span class="fade">Experiment registry sweep across every page</span></div>
        <div id="drop"><div class="wrap"><span>53 subagents running</span><span>&nbsp;·&nbsp;5 stopped</span></div></div>`);
        const scan = (root: string) => page.evaluate(findHardClips, { root });
        const cut = await scan("#cut");
        expect(cut.some((finding) => finding.kind === "hard-clip" && finding.text.includes("stopped"))).toBe(true);
        const tiny = await scan("#tiny");
        expect(tiny.map((finding) => finding.kind)).toEqual(["illegible"]);
        expect(await scan("#ok")).toEqual([]);
        expect(await scan("#fade")).toEqual([]);
        expect(await scan("#drop")).toEqual([]);
      } finally {
        await page.close();
      }
    });

    test("Leo's started line as it was (the experiment's before arm) is flagged illegible", async () => {
      const page = await browser!.newPage({ viewport: { width: 420, height: 320 } });
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(
          base +
            galleryFrame("agent-pane.subagent-started-line", {
              variant: "seven",
              width: 420,
              exp: "subagent-started-line",
              arm: "before",
            }),
        );
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        const findings = await page.evaluate(findHardClips, { root: "[data-started-line-gallery]" });
        expect(findings.filter((finding) => finding.kind === "illegible").length).toBeGreaterThan(2);
      } finally {
        await page.close();
      }
    });
  });

  describe("chips and strips in the chat at the pane's narrow width", () => {
    for (const surface of SURFACES)
      test(`${surface.name}: no text cut mid-word, no name cut to a letter or two`, async () => {
        const page = await browser!.newPage({ viewport: { width: surface.width, height: 640 } });
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        try {
          const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
          await page.goto(base + galleryFrame(surface.entry, { variant: surface.variant, width: surface.width }));
          await page.waitForFunction(
            () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
            undefined,
            { timeout: 90_000 },
          );
          expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
          await page.locator(surface.root).first().waitFor();
          await surface.before?.(page);
          // Let a slide or a fold end before measuring.
          await page.waitForFunction(() =>
            document
              .getAnimations()
              .every(
                (animation) =>
                  animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
              ),
          );
          const findings = await page.evaluate(findHardClips, { root: surface.root });
          expect(findings).toEqual([]);
          expect(errors).toEqual([]);
        } finally {
          await page.close();
        }
      });
  });
});
