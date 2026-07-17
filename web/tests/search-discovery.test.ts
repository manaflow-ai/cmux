import { describe, expect, test } from "bun:test";
import { buildBlogRssFeed } from "../app/lib/blog-feed";
import {
  indexNowEndpoint,
  indexNowKey,
  indexNowPayload,
  recentlyModifiedUrls,
  submitIndexNowUrls,
} from "../app/lib/indexnow";

describe("search discovery", () => {
  test("publishes a valid RSS channel with canonical blog URLs", () => {
    const feed = buildBlogRssFeed([
      {
        slug: "test-post",
        key: "testPost",
        title: "Agents & terminals",
        date: "2026-07-17",
        summary: "A <clear> update",
      },
    ]);

    expect(feed).toStartWith('<?xml version="1.0" encoding="UTF-8"?>');
    expect(feed).toContain('<rss version="2.0"');
    expect(feed).toContain("<title>Agents &amp; terminals</title>");
    expect(feed).toContain("<description>A &lt;clear&gt; update</description>");
    expect(feed).toContain("https://cmux.com/blog/test-post");
    expect(feed).toContain('href="https://cmux.com/feed.xml" rel="self"');
  });

  test("selects only recently modified sitemap URLs", () => {
    const urls = recentlyModifiedUrls(
      [
        { url: "https://cmux.com/new", lastModified: "2026-07-17" },
        { url: "https://cmux.com/recent", lastModified: "2026-07-16" },
        { url: "https://cmux.com/old", lastModified: "2026-07-01" },
        { url: "https://cmux.com/future", lastModified: "2026-07-18" },
      ],
      new Date("2026-07-17T14:00:00.000Z"),
    );

    expect(urls).toEqual([
      "https://cmux.com/new",
      "https://cmux.com/recent",
    ]);
  });

  test("submits the IndexNow protocol payload", async () => {
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
      requests.push({ url: String(url), init });
      return new Response(null, { status: 200 });
    }) as typeof fetch;

    const status = await submitIndexNowUrls(["https://cmux.com/new"], fetcher);

    expect(status).toBe(200);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe(indexNowEndpoint);
    expect(JSON.parse(String(requests[0]?.init?.body))).toEqual(
      indexNowPayload(["https://cmux.com/new"]),
    );
    expect(indexNowPayload([]).keyLocation).toBe(
      `https://cmux.com/${indexNowKey}.txt`,
    );
  });
});
