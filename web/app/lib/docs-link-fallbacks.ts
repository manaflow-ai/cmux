/**
 * Docs links that shipped in cmux What's New entries but have no page in the
 * release docs: /docs/agents, /docs/cli and /docs/mobile never existed, and the
 * cmux-next track (/docs/next/<slug>) is not on main yet. The main site sends
 * each one to the nearest live page so a click from a shipped build is not a
 * 404.
 *
 * These are fallbacks, never overrides:
 * - tests/docs-link-fallbacks.test.ts fails when a docs page is added at one of
 *   the fixed paths, so the fallback for that path is removed with it;
 * - once the cmux-next track reaches main, next.config.ts redirects
 *   /docs/next/:slug to the nightly docs, and Next.js runs redirects before this
 *   middleware, so the real pages win without a change here.
 * The redirects are temporary (307), so no browser keeps them.
 */
const fixedFallbacks: Readonly<Record<string, string>> = {
  "/docs/agents": "/docs/getting-started",
  "/docs/cli": "/docs/api",
  "/docs/mobile": "/docs/ios",
};

/** cmux-next slugs (web/data/next-docs/pages.ts on feat-cmux-next) with a close release page. */
const nextSlugFallbacks: Readonly<Record<string, string>> = {
  browser: "/docs/browser-automation",
  cli: "/docs/api",
  cloud: "/docs/cloud",
  "keyboard-shortcuts": "/docs/keyboard-shortcuts",
  remote: "/docs/ssh",
  settings: "/docs/configuration",
};

const nextTrackPattern = /^\/docs\/next(?:\/([^/]+))?$/u;

/** The fixed paths, for the test that keeps them free of real pages. */
export const fixedDocsLinkFallbackPaths = Object.keys(fixedFallbacks);

/**
 * The live page for a docs path that has none, or undefined for every other
 * path. A cmux-next page with no close release page goes to Getting Started,
 * as the release channel does for pages it hides.
 */
export function docsLinkFallback(pathname: string): string | undefined {
  const path = pathname.length > 1 ? pathname.replace(/\/+$/u, "") : pathname;
  const fixed = fixedFallbacks[path];
  if (fixed) return fixed;
  const next = nextTrackPattern.exec(path);
  if (!next) return undefined;
  const slug = next[1];
  return (slug && nextSlugFallbacks[slug]) || "/docs/getting-started";
}
