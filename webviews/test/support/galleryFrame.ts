// A gallery stage for one entry, as a browser test opens it.
//
// `/gallery/frame.html?entry=<id>` alone starts every `*.gallery.ts(x)` file's load before it finds
// the one it renders (src/gallery/entryStore.ts), about 2,300 modules; warming that URL transforms
// them all again. Run once per test file, that cold load is what timed tests out on a busy CI
// runner (markdown-selection-drag, #23080). `entryPath` narrows the frame to the file that defines
// the entry (src/gallery/registry.ts), so the page and its warm-up load that entry alone.
// scripts/check-browser-test-lanes.ts fails a browser test that opens a frame without it.

import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFiles, SRC } from "../../scripts/gallery/entries";

const ids = new Map<string, string>();

/** The gallery file that defines entry `id` (its `id: "<id>"` line), as the frame's `entryPath`. */
export function galleryEntryPath(id: string): string {
  const known = ids.get(id);
  if (known) return known;
  const line = new RegExp(`^\\s*id:\\s*"${id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}",?\\s*$`, "m");
  const files = galleryFiles().filter((file) => line.test(readFileSync(file, "utf8")));
  if (files.length !== 1)
    throw new Error(
      `galleryEntryPath: ${files.length === 0 ? "no" : files.length} gallery files define entry ${JSON.stringify(id)}`,
    );
  const found = `src/${path.relative(SRC, files[0]!).split(path.sep).join("/")}`;
  ids.set(id, found);
  return found;
}

type Params = Record<string, string | number | undefined>;

/**
 * Whether a load error is a dependency-optimizer reload. Only its first line, without the URLs it
 * names (an entry id or path could spell "cancelled"): Playwright appends a call log ("navigating
 * to …") to every goto error, a refused connection too.
 */
export function reloaded(error: unknown): boolean {
  const first = String(error)
    .split("\n")[0]!
    .replace(/\bhttps?:\/\/\S+/g, "");
  return /context was destroyed|interrupted by another navigation|ERR_ABORTED|cancell?ed|frame was detached/i.test(
    first,
  );
}

/** `/gallery/frame.html` for one variant of one entry, narrowed to the entry's own file. */
export function galleryFrame(entry: string, params: Params = {}): string {
  const query = new URLSearchParams({ entry, entryPath: galleryEntryPath(entry) });
  for (const [key, value] of Object.entries(params)) if (value !== undefined) query.set(key, String(value));
  return `/gallery/frame.html?${query}`;
}

/**
 * Warms the dev server for these entries by loading each one's frame once (with `params`, such as
 * a variant), in `browser` or a headless Chromium of its own, before a test measures it. A stage
 * that fails to mount fails the warm-up. A module crawl (warmDevServer.ts) also follows lazy
 * imports the page never makes: frame/pages.ts names every page host, the editor's Monaco among
 * them. For the composer that crawl took 25 s and 1,227 modules where this load took 20 s and 685
 * (Huge Blue, a cold server). Returns how many requests the loads made.
 */
export async function warmGalleryFrame(
  server: ViteDevServer | string,
  entries: string | readonly string[],
  { browser, params, timeoutMs = 100_000 }: { browser?: Browser; params?: Params; timeoutMs?: number } = {},
): Promise<number> {
  const base =
    typeof server === "string" ? server : `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
  const own = browser ? undefined : await chromium.launch({ headless: true });
  // One budget for every entry of this call: the frame's own modules are cached after the first.
  const deadline = Date.now() + timeoutMs;
  const left = () => Math.max(1, deadline - Date.now());
  let requests = 0;
  try {
    for (const entry of typeof entries === "string" ? [entries] : entries) {
      const page = await (browser ?? own!).newPage();
      page.on("request", () => requests++);
      try {
        let ready: string | undefined;
        let message: string | null = null;
        // Vite's dependency optimizer can reload the page while it bundles a new dependency, during
        // the navigation or after it; each reload starts the load again, within the same budget.
        for (;;) {
          try {
            await page.goto(`${base}${galleryFrame(entry, params)}`, { waitUntil: "commit", timeout: left() });
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
              timeout: left(),
            });
            [ready, message] = await page.evaluate(() => [
              document.documentElement.dataset.galleryReady,
              document.body.textContent,
            ]);
            break;
          } catch (error) {
            if (Date.now() >= deadline || !reloaded(error))
              throw new Error(`warmGalleryFrame: ${entry}: ${String(error)}`, { cause: error });
          }
        }
        if (ready === "error") throw new Error(`warmGalleryFrame: ${entry}: ${message}`);
      } finally {
        await page.close();
      }
    }
  } finally {
    await own?.close();
  }
  return requests;
}
