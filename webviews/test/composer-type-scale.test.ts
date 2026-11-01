// cmux-web-test-timeout: 240
// Leo, 2026-10-13 (coherence pass): "we ought to be unifying more font sizes". Every text the agent
// composer draws, its footer and the menus it opens included, sits on the one type scale
// (schemas/type-scale/type-scale.json): sizes 11, 12, 13, 15 and 20 px in two weights, 400 and 600. The
// prompt, the queued prompts and the model picker are reading content and follow the user's agent
// pane font size (--text-content). This loads
// every gallery state of the composer, its scope row and its pickers in Chromium and reads the
// computed size and weight of every element that draws text.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-type-scale.test.ts", async () => {
  setDefaultTimeout(120_000);
  const SIZES = [11, 12, 13, 15, 20];
  const WEIGHTS = [400, 600];
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-type-scale: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer type scale", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the gallery stage once, as composer-location-side.test.ts does: the first load can
    // trigger Vite's dependency optimizer and reload its context mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "new-chat" } });
    await warmGalleryFrame(vite, ["agent-pane.composer-context", "agent-pane.composer-pickers"], { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Each text style off the scale, as `size/weight where: text`. */
  async function offScale(entry: string, variant: string): Promise<string[]> {
    if (process.env.TYPE_SCALE_TRACE) console.error(`type-scale: ${entry} ${variant}`);
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(url(entry, variant));
    // Vite can reload the stage once while it optimizes a dependency a later entry imports.
    const ready = () =>
      page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30_000 });
    await ready().catch(async () => {
      await page.reload();
      await ready();
    });
    // The stage marks itself ready after a variant's play ran (the play's report is published with it).
    // A play whose own step never happened (a menu that never opened) would leave less text to read, so
    // it fails here; the stage's frame-timing and layout checks are the gallery's, not this test's.
    const playError = await page.evaluate(
      () => (window as unknown as { cmuxGalleryPlayReport?: { error?: string } }).cmuxGalleryPlayReport?.error,
    );
    if (playError) {
      await page.close();
      return [`the play did not run: ${playError}`];
    }
    const found = await page.evaluate(
      ({ sizes, weights }) => {
        const probe = document.createElement("span");
        probe.style.fontSize = "var(--text-content)";
        document.body.append(probe);
        const content = parseFloat(getComputedStyle(probe).fontSize);
        probe.remove();
        const out: string[] = [];
        for (const element of Array.from(document.body.querySelectorAll<HTMLElement>("*"))) {
          const draws =
            Array.from(element.childNodes).some(
              (node) => node.nodeType === Node.TEXT_NODE && node.textContent?.trim(),
            ) || element.matches("input, textarea, [contenteditable='true'], [data-placeholder]");
          const box = element.getBoundingClientRect();
          if (!draws || box.width === 0 || box.height === 0) continue;
          // The composer and what it opens (menus, popovers, the attachment viewer), not the stage's
          // transcript. Art is not text: a hidden glyph with no letter or digit (+, a check) and the
          // PDF thumbnail's sheet, drawn to the thumbnail's scale.
          if (!element.closest(".acpmux-composer, .ui-positioner, [role='dialog'], [role='menu'], [role='listbox']"))
            continue;
          const glyph = !/[\p{L}\p{N}]/u.test(element.textContent ?? "");
          if ((glyph && element.closest("[aria-hidden='true']")) || element.closest(".acpmux-pdf-sheet-mark")) continue;
          const style = getComputedStyle(element);
          if (style.visibility === "hidden" || style.display === "none") continue;
          const size = parseFloat(style.fontSize);
          const weight = parseInt(style.fontWeight, 10);
          // Reading content follows the chat font size (--text-content): the prompt, the queued
          // prompts (#26523, 2026-10-28) and the model picker's menu, which matches the composer's
          // text (#26071, 2026-10-27).
          const prompt = Boolean(element.closest(".acpmux-composer-prompt, .acpmux-queued-text, .acpmux-quick-menu"));
          const sizeOk = sizes.includes(size) || (prompt && size === content);
          if (sizeOk && weights.includes(weight)) continue;
          // The shared ghost button (src/ui/ghost.css, the footer's location buttons) keeps base's
          // medium weight: moving it onto the scale changes a default look, so it waits for that call.
          if (sizeOk && weight === 500 && element.closest(".ui-ghost")) continue;
          const where =
            element.className && typeof element.className === "string"
              ? element.className.split(" ")[0]
              : element.tagName;
          const text = (element.textContent || element.getAttribute("placeholder") || "").trim().slice(0, 24);
          out.push(`${size}px/${weight} ${where}: ${text}`);
        }
        return [...new Set(out)];
      },
      { sizes: SIZES, weights: WEIGHTS },
    );
    await page.close();
    return found;
  }

  // Every state the gallery draws of the composer, its scope row (the footer) and its pickers.
  const ENTRIES: Record<string, string[]> = {
    "agent-pane.composer": [
      "new-chat",
      "footer-essentials",
      "footer-full-access",
      "footer-essentials-new-chat",
      "agent-home",
      "agent-home-path",
      "agent-home-folders",
      "idle",
      "focused",
      "context-menu",
      "image-attached",
      "pdf-attached",
      "draft",
      "long-draft",
      "working",
      "working-stop",
      "working-steer",
      "working-queue",
      "queued",
      "queued-paused",
      "codex-model",
      "tray-long-branch",
      "docked-400",
      "folder-menu",
      "add-menu",
      "slash-menu",
      "mention-picker",
      "reasoning-claude",
      "reasoning-codex",
      "reasoning-menu",
      "model-menu-starred",
      "model-switching",
      "access-menu",
      "disconnected",
    ],
    "agent-pane.composer-context": ["closed", "folder-menu", "computer-menu", "ssh-chat"],
    "agent-pane.composer-pickers": ["closed", "model-menu", "effort-menu"],
  };
  // One variant at a time spends most of its ~2.2 s loading the stage (each page is a fresh
  // context, so it fetches its ~700 dev-server modules again), and 41 of them in a row ran past the
  // runner's 120 s file limit. So a few pages read variants at once, each variant still in its own
  // page, and each test awaits its own result.
  const PAGES = 4;
  const states = Object.entries(ENTRIES).flatMap(([entry, variants]) =>
    variants.map((variant) => ({ entry, variant })),
  );
  const results = new Map<string, Promise<string[]>>();
  beforeAll(() => {
    let free = PAGES;
    const waiting: (() => void)[] = [];
    const inPage = async (work: () => Promise<string[]>) => {
      if (free > 0) free--;
      else await new Promise<void>((resolve) => waiting.push(resolve));
      try {
        return await work();
      } finally {
        const next = waiting.shift();
        if (next) next();
        else free++;
      }
    };
    for (const { entry, variant } of states) {
      const result = inPage(() => offScale(entry, variant));
      // A test left out by a filter never awaits its result; its failure is not the run's.
      result.catch(() => {});
      results.set(`${entry} ${variant}`, result);
    }
  });
  for (const { entry, variant } of states) {
    test(`${entry} ${variant} draws its text on the type scale`, async () => {
      expect(await results.get(`${entry} ${variant}`)!).toEqual([]);
    });
  }
});
