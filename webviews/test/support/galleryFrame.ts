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

/**
 * Vite's own evidence that a stage imported a dependency the optimizer has since replaced: its 504
 * "Outdated Optimize Dep" answer. A stage that shows it loads again once the optimizer settles.
 */
export function outdatedOptimizeDep(message: string | null | undefined): boolean {
  return /Outdated Optimize Dep/i.test(message ?? "");
}

/**
 * A stage that failed to mount on a dynamic import. On its own this is no evidence of the
 * optimizer (a missing or broken module fails the same way): the warm-up waits for the optimizer
 * and loads again only when the optimizer then reloaded the page (reloadsSent), else fails at once.
 */
export function dynamicImportFailed(message: string | null | undefined): boolean {
  return /Failed to fetch dynamically imported module|error loading dynamically imported module|Importing a module script failed/i.test(
    message ?? "",
  );
}

/** A goto that has not committed in this long is stuck on its page: the load starts again on a new one. */
export const NAVIGATION_ATTEMPT_MS = 30_000;

/** Whether a load error is a goto that did not commit within its attempt (NAVIGATION_ATTEMPT_MS). */
export function stalled(error: unknown): boolean {
  return /^TimeoutError: (?:page\.)?goto: Timeout \d+ms exceeded/.test(String(error).split("\n")[0]!);
}

/** `/gallery/frame.html` for one variant of one entry, narrowed to the entry's own file. */
export function galleryFrame(entry: string, params: Params = {}): string {
  const query = new URLSearchParams({ entry, entryPath: galleryEntryPath(entry) });
  for (const [key, value] of Object.entries(params)) if (value !== undefined) query.set(key, String(value));
  return `/gallery/frame.html?${query}`;
}

const reloadCounts = new WeakMap<ViteDevServer, { sent: number }>();

/**
 * How many full-page reloads `server` has sent since its first warm-up (none for a server given by
 * URL). The count wraps the client's hot channel once per server, so warm-ups that overlap share it.
 */
function reloadsSent(server: ViteDevServer | string): number {
  if (typeof server === "string") return 0;
  let count = reloadCounts.get(server);
  if (!count) {
    const counted = { sent: 0 };
    count = counted;
    reloadCounts.set(server, counted);
    const hot = server.environments.client.hot;
    const send = hot.send;
    hot.send = ((...args: Parameters<typeof send>) => {
      if ((args[0] as { type?: string } | undefined)?.type === "full-reload") counted.sent += 1;
      return (send as (...args: unknown[]) => void).apply(hot, args);
    }) as typeof send;
  }
  return count.sent;
}

/**
 * Waits until the dependency optimizer of `server` has bundled every dependency the loads so far
 * discovered. The optimizer bundles them once the requests go idle and, when the bundle changes,
 * reloads every page a few microtasks after it commits: the extra turn lets that reload be counted.
 */
async function optimizerSettled(server: ViteDevServer, left: () => number): Promise<void> {
  const client = server.environments.client;
  for (;;) {
    // Both waits share the warm-up's deadline: an optimizer that never goes idle fails it, with
    // the page closed by the caller, instead of hanging past timeoutMs.
    await withinDeadline(client.waitForRequestsIdle(), left, "the dev server's requests did not go idle");
    const pending = Object.values(client.depsOptimizer?.metadata.discovered ?? {})
      .map((dep) => dep.processing)
      .filter((processing): processing is Promise<void> => processing !== undefined);
    if (pending.length === 0) break;
    await withinDeadline(Promise.all(pending), left, "the dependency optimizer did not settle");
  }
  await new Promise((resolve) => setImmediate(resolve));
}

/** `work`, or a rejection naming `what` once `left()` milliseconds pass first. */
async function withinDeadline<T>(work: Promise<T>, left: () => number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timedOut = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(what)), left());
  });
  try {
    return await Promise.race([work, timedOut]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Warms the dev server for these entries by loading each one's frame once (with `params`, such as
 * a variant), in `browser` or a headless Chromium of its own, before a test measures it. A stage
 * that fails to mount fails the warm-up. A module crawl (warmDevServer.ts) also follows lazy
 * imports the page never makes: frame/pages.ts names every page host, the editor's Monaco among
 * them. For the composer that crawl took 25 s and 1,227 modules where this load took 20 s and 685
 * (Huge Blue, a cold server). Returns how many requests the loads made.
 *
 * Given the server itself, it returns only once a load ended with the optimizer settled and no
 * reload sent: a reload that came after would land on the test's page once the test had set it up
 * (new-tab-list-motion lost its rows that way, 2026-10-21).
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
      const target = browser ?? own!;
      const open = async () => {
        const opened = await target.newPage();
        opened.on("request", () => requests++);
        return opened;
      };
      let page = await open();
      try {
        let ready: string | undefined;
        let message: string | null = null;
        // Vite's dependency optimizer can reload the page while it bundles a new dependency, during
        // the navigation or after it, or leave the stage importing a module it has since replaced
        // (a reload it sends, or its 504 Outdated Optimize Dep); each starts the load again, within
        // the same budget, on a fresh page. The last document's module requests can hold its
        // connections while the optimizer bundles, and
        // a goto on that page then never commits: #26637's warm-up on a cold fleet worker waited out
        // its whole budget in one goto (85 s, 2026-10-28), where a new page loaded in about 1 s.
        for (;;) {
          const sent = reloadsSent(server);
          let raced = false;
          try {
            await page.goto(`${base}${galleryFrame(entry, params)}`, {
              waitUntil: "commit",
              timeout: Math.min(left(), NAVIGATION_ATTEMPT_MS),
            });
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
              timeout: left(),
            });
            [ready, message] = await page.evaluate(() => [
              document.documentElement.dataset.galleryReady,
              document.body.textContent,
            ]);
            // A failed dynamic import may be the optimizer replacing a dependency mid-load: let it
            // settle, so the reload it sends for that is counted before deciding.
            const importFailed = ready === "error" && dynamicImportFailed(message);
            if (typeof server !== "string" && (ready !== "error" || importFailed)) await optimizerSettled(server, left);
            raced = ready === "error" && outdatedOptimizeDep(message);
            // A reload since this load began (the optimizer's own signal), or Vite's 504 for a
            // stale optimized dependency: load again. Any other mount error fails below at once.
            if (reloadsSent(server) === sent && !raced) break;
          } catch (error) {
            if (Date.now() >= deadline || !(reloaded(error) || stalled(error)))
              throw new Error(`warmGalleryFrame: ${entry}: ${String(error)}`, { cause: error });
          }
          if (Date.now() >= deadline)
            throw new Error(
              `warmGalleryFrame: ${entry}: ${raced ? message : "the dependency optimizer was still reloading the page"} at the ${timeoutMs} ms deadline`,
            );
          await page.close();
          page = await open();
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
