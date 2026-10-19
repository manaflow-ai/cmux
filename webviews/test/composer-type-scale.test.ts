// Leo, 2026-10-13 (coherence pass): "we ought to be unifying more font sizes". Every text the agent
// composer draws, its footer and the menus it opens included, sits on the one type scale
// (schemas/type-scale/type-scale.json): sizes 11, 12, 13, 15 and 20 px in two weights, 400 and 600. The
// prompt is reading content and follows the user's agent pane font size (--text-content). This loads
// every gallery state of the composer, its scope row and its pickers in Chromium and reads the
// computed size and weight of every element that draws text.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // Warm the gallery stage once, as composer-location-side.test.ts does: the first load can
    // trigger Vite's dependency optimizer and reload its context mid-compile.
    const warm = await browser.newPage({ viewport: { width: 760, height: 560 } });
    await warm.goto(url("agent-pane.composer", "new-chat"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
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
          const prompt = Boolean(element.closest(".acpmux-composer-prompt"));
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
      "working-interrupt",
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
  for (const [entry, variants] of Object.entries(ENTRIES)) {
    for (const variant of variants) {
      test(`${entry} ${variant} draws its text on the type scale`, async () => {
        expect(await offScale(entry, variant)).toEqual([]);
      });
    }
  }
});
