// Warms a Vite dev server for a page before a test loads it.
//
// `vp dev` prints its port before it has transformed a module, and it transforms each one on its
// first request. A test's first `page.goto` therefore paid for the whole module graph: beside a
// second dev server and browser on the CI runner that took more than the 30 s navigation timeout
// (chat-find, text-field-focus), while the next load of the same page took 2 s. This requests the
// page and every module it imports, as the browser will, so the server caches each transform and
// the test's own timeouts measure the page, not the cold server.
//
// Same-origin paths are followed, absolute (`/src/…`, `/node_modules/.vite/deps/…`, `/@vite/client`)
// or relative to the file that names them (an entry page's `src="./harness.tsx"`); bare package
// names never reach the browser in dev, Vite rewrites them. Gallery frame URLs are special: a
// frame with no `entry=` query is only a warm-up shell, so following every registry glob would
// eagerly compile hundreds of unrelated `*.gallery.ts(x)` entries before the test opens its real
// stage. Those entry modules are requested by the browser when the concrete stage URL loads.

import type { ViteDevServer } from "vite";

const IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*)["']((?:\.{1,2})?\/[^"'\s]+)["']/g;
const SCRIPT = /<script\b[^>]*\bsrc=["']((?:\.{1,2})?\/[^"']+)["']/g;
const GALLERY_ENTRY = /^\/(?:gallery\/)?src\/.*\.gallery\.(?:ts|tsx)$/;

export type WarmDevServerOptions = {
  timeoutMs?: number;
  limit?: number;
  jobs?: number;
  /** Include every gallery entry in a no-entry frame warm-up. Defaults to false. */
  includeGalleryEntries?: boolean;
};

/** Whether a discovered module belongs in a warm-up crawl. Kept pure for a focused regression test. */
export function shouldWarmPath(path: string, from: string, includeGalleryEntries: boolean): boolean {
  if (includeGalleryEntries) return true;
  return !GALLERY_ENTRY.test(new URL(path, new URL(from, "http://gallery.invalid")).pathname);
}

/** Requests `page` on `base` and every module it imports; returns how many modules it fetched. */
export async function warmDevServer(
  base: string,
  page: string,
  { timeoutMs = 100_000, limit = 4_000, jobs = 8, includeGalleryEntries }: WarmDevServerOptions = {},
) {
  const deadline = Date.now() + timeoutMs;
  const seen = new Set<string>();
  const queue: string[] = [];
  const pageUrl = new URL(page, base);
  // Both the shell warm-up and a concrete frame are lazy registry surfaces. A concrete frame
  // imports its requested entry after boot; crawling every *.gallery module here recreates the
  // compile burst this helper is intended to avoid. Full registry warming remains opt-in.
  const warmGalleryEntries = includeGalleryEntries ?? pageUrl.pathname !== "/gallery/frame.html";
  const follow = (text: string, from: string, pattern: RegExp) => {
    for (const match of text.matchAll(pattern)) {
      const url = new URL(match[1], new URL(from, base));
      const path = url.pathname + url.search;
      if (
        url.origin === new URL(base).origin &&
        shouldWarmPath(path, from, warmGalleryEntries) &&
        !seen.has(path) &&
        seen.size < limit
      ) {
        seen.add(path);
        queue.push(path);
      }
    }
  };
  const fetchText = async (path: string) => {
    const left = deadline - Date.now();
    if (left <= 0) throw new Error(`warmDevServer: ${page} still cold after ${timeoutMs} ms (${seen.size} modules)`);
    const response = await fetch(new URL(path, base), { signal: AbortSignal.timeout(left) });
    return response.ok ? response.text() : "";
  };

  const html = await fetchText(page);
  follow(html, page, SCRIPT);
  // Inline module scripts: Vite's HTML transform adds `/@vite/client` and the React preamble.
  follow(html, page, IMPORT);

  const running = new Set<Promise<void>>();
  let failure: unknown;
  while (queue.length > 0 || running.size > 0) {
    while (queue.length > 0 && running.size < jobs) {
      const path = queue.shift()!;
      const visit: Promise<void> = fetchText(path)
        .then((code) => follow(code, path, IMPORT))
        .catch((error: unknown) => {
          failure ??= error;
        })
        .finally(() => running.delete(visit));
      running.add(visit);
    }
    await Promise.race(running);
    // The first failure ends the warm-up; the visits still running end on the same deadline.
    if (failure !== undefined) throw failure;
  }
  return seen.size;
}

/** `warmDevServer` for a server started in-process (`createServer(…)` then `listen()`). */
export function warmViteServer(vite: ViteDevServer, page: string, options?: Parameters<typeof warmDevServer>[2]) {
  const { port } = vite.httpServer!.address() as { port: number };
  return warmDevServer(`http://127.0.0.1:${port}`, page, options);
}
