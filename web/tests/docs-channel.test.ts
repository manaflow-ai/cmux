import { afterEach, expect, test } from "bun:test";
import {
  docsCanonicalOrigin,
  docsChannel,
  docsChannelUrl,
  docsNavPath,
  docsPathAvailableInChannel,
  docsZoneSelfRewrites,
} from "../app/lib/docs-channel";
import { nextDocHref, nextDocPages } from "../data/next-docs/pages";
import {
  flatNavItems,
  navItemsForLocale,
} from "../app/[locale]/components/docs-nav-items";

const saved = {
  channel: process.env.CMUX_DOCS_CHANNEL,
};

afterEach(() => {
  process.env.CMUX_DOCS_CHANNEL = saved.channel;
});

test("channel switching preserves localized path, query, and hash", () => {
  expect(
    docsChannelUrl("nightly", "/ja/docs/base", "?q=base", "#install"),
  ).toBe("/ja/docs/nightly/base?q=base#install");
  expect(docsChannelUrl("release", "/ja/docs/nightly/base")).toBe(
    "/ja/docs/getting-started",
  );
});

test("pager matching removes locale and nightly prefixes", () => {
  expect(docsNavPath("/ja/docs/nightly/concepts", "ja")).toBe(
    "/docs/concepts",
  );
  expect(docsNavPath("/docs/nightly/concepts", "en")).toBe(
    "/docs/concepts",
  );
});

test("nightly-only pages keep their own path for sidebar and pager matching", () => {
  // The nightly zone serves /docs/next/spaces; the nav must mark that page, not
  // the release fallback (Getting Started).
  expect(docsNavPath("/docs/next/spaces", "en")).toBe("/docs/next/spaces");
  expect(docsNavPath("/en/docs/nightly/next", "en")).toBe("/docs/next");
  expect(docsNavPath("/docs/base", "en")).toBe("/docs/base");
});

test("Base appears only in nightly documentation navigation", () => {
  const releasePaths = flatNavItems(navItemsForLocale("en", "release")).map(
    (item) => item.href,
  );
  const nightlyPaths = flatNavItems(navItemsForLocale("en", "nightly")).map(
    (item) => item.href,
  );

  expect(releasePaths).not.toContain("/docs/base");
  expect(nightlyPaths).toContain("/docs/base");
  expect(docsPathAvailableInChannel("release", "/docs/base")).toBe(false);
  expect(docsPathAvailableInChannel("nightly", "/docs/nightly/base")).toBe(true);
});

test("release docs are the canonical default", () => {
  delete process.env.CMUX_DOCS_CHANNEL;
  expect(docsChannel()).toBe("release");
  expect(docsCanonicalOrigin()).toBe("https://cmux.com");
});

test("nightly docs canonically point to the release channel", () => {
  process.env.CMUX_DOCS_CHANNEL = "nightly";
  expect(docsChannel()).toBe("nightly");
  expect(docsCanonicalOrigin()).toBe("https://cmux.com");
});

/** Where a docs zone's own rewrites send `path`, as Next matches `:name` and `:name*`. */
function zoneRoute(path: string, rewrites: { source: string; destination: string }[]): string {
  for (const { source, destination } of rewrites) {
    const names: string[] = [];
    const pattern = source.replace(/\/:(\w+)(\*)?/g, (_, name: string, star?: string) => {
      names.push(name);
      return star ? "(?:/(.*))?" : "/([^/]+)";
    });
    const match = new RegExp(`^${pattern}$`).exec(path);
    if (!match) continue;
    return destination.replace(/:(\w+)\*?/g, (_, name: string) => match[names.indexOf(name) + 1] ?? "")
      .replace(/\/$/, "");
  }
  return path;
}

// The nightly zone renders each docs link as /docs/nightly/... (docsChannelUrl), the public
// path cmux.com rewrites to the zone's /docs/.... On the zone's own host every sidebar entry
// and every cmux-next page link 404'd: nothing mapped /docs/nightly there.
test("every nightly docs link opens on the nightly zone's own host", () => {
  const rewrites = docsZoneSelfRewrites("nightly");
  const hrefs = [
    ...flatNavItems(navItemsForLocale("en", "nightly")).map((item) => item.href),
    ...nextDocPages.flatMap((page) => (page.links ?? []).map(nextDocHref)),
  ];
  expect(hrefs.length).toBeGreaterThan(20);
  for (const href of hrefs) {
    const rendered = docsChannelUrl("nightly", href);
    expect(rendered.startsWith("/docs/nightly")).toBe(true);
    expect(zoneRoute(rendered, rewrites)).toBe(href);
    expect(zoneRoute(`/en${rendered}`, rewrites)).toBe(`/en${href}`);
  }
  expect(zoneRoute("/docs/nightly", rewrites)).toBe("/docs/getting-started");
  expect(zoneRoute("/ja/docs/nightly/ssh", rewrites)).toBe("/ja/docs/ssh");
  expect(zoneRoute("/ja/docs/nightly", rewrites)).toBe("/ja/docs/getting-started");
  // The release zone's links have no /nightly prefix and need no rewrite.
  expect(docsZoneSelfRewrites("release")).toEqual([]);
});
