import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// The release docs read is cached with `use cache`; outside Next the cache
// profile call has no runtime, so it is a no-op here.
mock.module("next/cache", () => ({ cacheLife: () => {} }));

const { default: sitemap, sitemapEntries } = await import("../app/sitemap");

// cmux.com/docs is served by the release docs zone, built from the latest
// release tag. Docs added on main after that tag returned 404 there while the
// main site's sitemap still listed them (182 URLs on 2026-10-02).
const RELEASED_DOCS = [
  "https://cmux.com/docs/getting-started",
  "https://cmux.com/ja/docs/getting-started",
  "https://cmux.com/docs/ssh",
  "https://cmux.com/ja/docs/ssh",
];

function releaseSitemapXml(urls: readonly string[]): string {
  const body = urls.map((url) => `<url><loc>${url}</loc></url>`).join("");
  return `<?xml version="1.0" encoding="UTF-8"?><urlset>${body}<url><loc>https://cmux.com/pricing</loc></url></urlset>`;
}

const saved = {
  fetch: globalThis.fetch,
  channel: process.env.CMUX_DOCS_CHANNEL,
  origin: process.env.CMUX_RELEASE_DOCS_ORIGIN,
};
let requested: string[] = [];

function serveReleaseSitemap(response: () => Response) {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    requested.push(String(input));
    return response();
  }) as typeof fetch;
}

beforeEach(() => {
  requested = [];
  delete process.env.CMUX_DOCS_CHANNEL;
  process.env.CMUX_RELEASE_DOCS_ORIGIN = "https://release-docs.test";
});

afterEach(() => {
  globalThis.fetch = saved.fetch;
  if (saved.channel === undefined) delete process.env.CMUX_DOCS_CHANNEL;
  else process.env.CMUX_DOCS_CHANNEL = saved.channel;
  if (saved.origin === undefined) delete process.env.CMUX_RELEASE_DOCS_ORIGIN;
  else process.env.CMUX_RELEASE_DOCS_ORIGIN = saved.origin;
});

describe("main site sitemap", () => {
  test("lists only the docs the release docs zone serves", async () => {
    serveReleaseSitemap(() => new Response(releaseSitemapXml(RELEASED_DOCS)));
    const urls = (await sitemap()).map((entry) => entry.url);

    expect(requested).toEqual(["https://release-docs.test/sitemap.xml"]);
    expect(urls).toContain("https://cmux.com/docs/getting-started");
    expect(urls).toContain("https://cmux.com/ja/docs/ssh");
    expect(urls).not.toContain("https://cmux.com/docs/cloud");
    expect(urls).not.toContain("https://cmux.com/ja/docs/coderouter");
    expect(urls).not.toContain("https://cmux.com/docs/configuration");
    // Pages this deployment serves itself are unaffected.
    expect(urls).toContain("https://cmux.com/pricing");
    expect(urls).toContain("https://cmux.com/ja/pricing");
  });

  test("drops alternates that point at docs the release zone does not serve", async () => {
    serveReleaseSitemap(() => new Response(releaseSitemapXml(["https://cmux.com/docs/ssh"])));
    const ssh = (await sitemap()).find((entry) => entry.url === "https://cmux.com/docs/ssh");

    expect(ssh?.alternates?.languages).toEqual({
      en: "https://cmux.com/docs/ssh",
      "x-default": "https://cmux.com/docs/ssh",
    });
  });

  test("falls back to every authored entry when the release sitemap is unavailable", async () => {
    for (const response of [
      () => new Response("unavailable", { status: 503 }),
      () => new Response("<urlset><url><loc>https://cmux.com/pricing</loc></url></urlset>"),
    ]) {
      serveReleaseSitemap(response);
      expect((await sitemap()).map((entry) => entry.url)).toEqual(
        sitemapEntries().map((entry) => entry.url),
      );
    }
  });
});

describe("docs zone sitemap", () => {
  test("lists the docs the zone was built with and reads no other zone", async () => {
    process.env.CMUX_DOCS_CHANNEL = "release";
    serveReleaseSitemap(() => {
      throw new Error("a docs zone must not read the release sitemap");
    });

    expect((await sitemap()).map((entry) => entry.url)).toEqual(
      sitemapEntries().map((entry) => entry.url),
    );
    expect(requested).toEqual([]);
  });
});
