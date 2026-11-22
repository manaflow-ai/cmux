// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-11-07: a prompt sent with an image landed, then "it just sort of needs to readjust and
// pop up for the video preview or the image preview", and "we should show more than we are
// showing right now. And also, like, we do not want to have this card thing going on, this double
// card thing". A sent bubble keeps one size from the frame it lands, through acpmux's echo of it
// and its images loading; a prompt shows more of its lines before Show more; and a paste is the
// bubble's own text, with no card drawn inside the bubble.
//
// It renders gallery `agent-pane.sent-bubble-size` in Chromium, which sends each prompt as the pane
// does (its own row, then acpmux's echo naming the images before the pane primed them), and reads
// every prompt's height on every frame from the first. CI fails the file when Chromium cannot
// launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/sent-bubble-final-size.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

/// Each prompt's height on every painted frame, by its `data-sent-prompt` index.
type SentHeights = Record<string, number[]>;

await requireBrowserLane("sent-bubble-final-size.test.ts", async () => {
  const ENTRY = "agent-pane.sent-bubble-size";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("sent bubble final size", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 1200 } });
    // Before the stage mounts: after every painted frame, each sent prompt's height, from the first
    // frame it paints.
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      const heights: Record<string, number[]> = {};
      (window as unknown as { sentHeights: Record<string, number[]> }).sentHeights = heights;
      window.cmuxAfterPaint(() => {
        for (const prompt of document.querySelectorAll<HTMLElement>("[data-sent-prompt]")) {
          const key = prompt.dataset.sentPrompt!;
          (heights[key] ??= []).push(Math.round(prompt.getBoundingClientRect().height * 2) / 2);
        }
      });
    });
    for (;;) {
      await page.goto(stageURL(variant));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };

  /// Waits until every prompt's echo has landed and the pane has primed its images, and a few
  /// frames more.
  const settled = async (page: Page) => {
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll("[data-sent-prompt]")].every((prompt) =>
          prompt.hasAttribute("data-sent-settled"),
        ),
      undefined,
      { timeout: 20_000 },
    );
    // Ten painted frames more, so a reshape after the last change would show.
    for (let frame = 0; frame < 10; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };

  for (const variant of ["text-only", "one-image", "several-files", "video", "long-paste", "long-text"])
    test(`${variant}: the sent prompt keeps the size it landed at`, async () => {
      const page = await open(variant);
      try {
        await settled(page);
        const heights = await page.evaluate(() => (window as unknown as { sentHeights: SentHeights }).sentHeights);
        expect(Object.keys(heights).length).toBeGreaterThan(0);
        for (const [prompt, frames] of Object.entries(heights)) {
          const drawn = frames.filter((height) => height > 0);
          expect(drawn.length).toBeGreaterThan(5);
          // Every frame from the first it drew: one height.
          expect({ prompt, heights: [...new Set(drawn)] }).toEqual({ prompt, heights: [drawn[0]!] });
        }
      } finally {
        await page.close();
      }
    });

  test("long-paste: the paste is the bubble's own text, with no card inside the bubble", async () => {
    const page = await open("long-paste");
    try {
      const look = await page.evaluate(() => {
        const bubble = document.querySelector<HTMLElement>(".cv-user__bubble")!;
        const cards = [...bubble.querySelectorAll<HTMLElement>("*")].filter((element) => {
          const style = getComputedStyle(element);
          const fill = style.backgroundColor;
          const filled = fill !== "transparent" && !/rgba\([^)]*,\s*0\)$/.test(fill);
          const bordered = ["Top", "Right", "Bottom", "Left"].some(
            (side) => parseFloat(style.getPropertyValue(`border-${side.toLowerCase()}-width`)) > 0,
          );
          return filled || bordered || style.boxShadow !== "none";
        });
        return {
          cards: cards.map((element) => element.className),
          text: bubble.innerText,
          more: Boolean(bubble.querySelector(".cv-user__more")),
        };
      });
      expect(look.cards).toEqual([]);
      // Its characters, whole: a 600-character paste is well under the fold.
      expect(look.text).toContain(
        "Can you find where the height is measured and why it changes after the tab has opened?",
      );
      expect(look.text).not.toContain("Pasted text");
      expect(look.more).toBe(false);
    } finally {
      await page.close();
    }
  });

  // A paste whose folded head (its first HUGE_PROMPT_HEAD_CHARS) is one line but whose whole text
  // is past the fold: the fold measured the head, unfolded, measured the whole, folded again, and so
  // on until React's maximum update depth (cross-model review of #37675).
  test("short-head-paste: a paste whose head is one line folds once and stays folded", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 1200 } });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(String(error)));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    await page.addInitScript(() => {
      // Every time the prompt's text box gains or loses its clamp.
      const flips = { count: 0 };
      (window as unknown as { clampFlips: typeof flips }).clampFlips = flips;
      new MutationObserver((records) => {
        for (const record of records) {
          const node = record.target as HTMLElement;
          if (!node.classList?.contains("cv-user__text")) continue;
          if (node.classList.contains("is-clamped") !== /\bis-clamped\b/.test(record.oldValue ?? "")) flips.count += 1;
        }
      }).observe(document, { subtree: true, attributes: true, attributeFilter: ["class"], attributeOldValue: true });
    });
    try {
      for (;;) {
        await page.goto(stageURL("short-head-paste"));
        try {
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      // A fold that loops until React gives up unmounts the stage: say so before anything else.
      const drawn = await page
        .waitForSelector("[data-sent-settled] .cv-user__text", { timeout: 20_000 })
        .then(() => true)
        .catch(() => false);
      expect(errors.filter((error) => /Maximum update depth/i.test(error))).toEqual([]);
      expect(drawn).toBe(true);
      const read = () =>
        page.evaluate(() => {
          const text = document.querySelector<HTMLElement>("[data-sent-prompt] .cv-user__text")!;
          return {
            clamped: text.classList.contains("is-clamped"),
            more: document.querySelector<HTMLElement>("[data-sent-prompt] .cv-user__more")?.textContent ?? null,
            flips: (window as unknown as { clampFlips: { count: number } }).clampFlips.count,
          };
        });
      const first = await read();
      // Twenty frames more: a fold that oscillates flips its clamp on each.
      for (let frame = 0; frame < 20; frame++) await page.evaluate(() => new Promise(requestAnimationFrame));
      const last = await read();
      expect(errors.filter((error) => /Maximum update depth/i.test(error))).toEqual([]);
      expect(last).toEqual({ clamped: true, more: "Show more", flips: first.flips });
      // At most one clamp change from mount (a guess the measure corrects).
      expect(last.flips).toBeLessThanOrEqual(1);
    } finally {
      await page.close();
    }
  });

  test("long-text: 15 lines draw whole; 40 open on their first 20 over Show more", async () => {
    const page = await open("long-text");
    try {
      const prompts = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>("[data-sent-prompt]")].map((prompt) => {
          const text = prompt.querySelector<HTMLElement>(".cv-user__text")!;
          const line = parseFloat(getComputedStyle(prompt.querySelector(".cv-user__bubble")!).lineHeight);
          return {
            more: Boolean(prompt.querySelector(".cv-user__more")),
            clamped: text.classList.contains("is-clamped"),
            lines: text.classList.contains("is-clamped") ? Math.round(text.getBoundingClientRect().height / line) : 0,
          };
        }),
      );
      expect(prompts[0]).toEqual({ more: false, clamped: false, lines: 0 });
      expect(prompts[1]).toEqual({ more: true, clamped: true, lines: 20 });
    } finally {
      await page.close();
    }
  });
});
