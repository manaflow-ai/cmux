import { describe, expect, test } from "bun:test";
import { buildBlogRssFeed } from "../app/lib/blog-feed";
import {
  indexNowEndpoint,
  indexNowKey,
  indexNowPayload,
  indexNowTimeoutMs,
  recentlyModifiedUrls,
  submitIndexNowUrls,
} from "../app/lib/indexnow";
import { buildLocalizedBlogRssFeed } from "../app/lib/localized-blog-feed";
import { POST as submitIndexNowDeployment } from "../app/api/cron/indexnow/route";

describe("search discovery", () => {
  test("publishes a valid RSS channel with canonical blog URLs", () => {
    const feed = buildBlogRssFeed(
      [
        {
          slug: "test-post",
          key: "testPost",
          title: "Agents & terminals",
          date: "2026-07-17",
          summary: "A <clear> update",
        },
      ],
      {
        blogUrl: "https://cmux.com/blog",
        description: "News & updates",
        feedUrl: "https://cmux.com/feed.xml",
        language: "en",
        title: "cmux blog",
      },
    );

    expect(feed).toStartWith('<?xml version="1.0" encoding="UTF-8"?>');
    expect(feed).toContain('<rss version="2.0"');
    expect(feed).toContain("<title>Agents &amp; terminals</title>");
    expect(feed).toContain("<description>A &lt;clear&gt; update</description>");
    expect(feed).toContain("https://cmux.com/blog/test-post");
    expect(feed).toContain('href="https://cmux.com/feed.xml" rel="self"');
  });

  test("publishes locale-specific feeds with translated discovery URLs", async () => {
    const feed = await buildLocalizedBlogRssFeed("ja");

    expect(feed).toContain("<language>ja</language>");
    expect(feed).toContain("<link>https://cmux.com/ja/blog</link>");
    expect(feed).toContain('href="https://cmux.com/ja/feed.xml"');
    expect(feed).toContain("<title>cmux Forkの紹介</title>");
    expect(feed).not.toContain("/ja/blog/cmux-omo");
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

  test("anchors the lookback to sitemap changes after a delayed deployment", () => {
    const urls = recentlyModifiedUrls(
      [
        { url: "https://cmux.com/new", lastModified: "2026-07-17" },
        { url: "https://cmux.com/recent", lastModified: "2026-07-16" },
        { url: "https://cmux.com/old", lastModified: "2026-07-01" },
      ],
      new Date("2026-08-17T14:00:00.000Z"),
    );

    expect(urls).toEqual([
      "https://cmux.com/new",
      "https://cmux.com/recent",
    ]);
  });

  test("handles a maximum-size sitemap without spreading timestamps", () => {
    const entries = Array.from({ length: 50_000 }, (_, index) => ({
      url: `https://cmux.com/page-${index}`,
      lastModified: index === 49_999 ? "2026-07-17" : "2026-07-01",
    }));

    expect(
      recentlyModifiedUrls(entries, new Date("2026-07-17T14:00:00.000Z")),
    ).toEqual(["https://cmux.com/page-49999"]);
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
    expect(requests[0]?.init?.signal).toBeInstanceOf(AbortSignal);
    expect(indexNowTimeoutMs).toBe(10_000);
    expect(JSON.parse(String(requests[0]?.init?.body))).toEqual(
      indexNowPayload(["https://cmux.com/new"]),
    );
    expect(indexNowPayload([]).keyLocation).toBe(
      `https://cmux.com/${indexNowKey}.txt`,
    );
  });

  test("rejects deployment triggers without the server cron secret", async () => {
    const originalSecret = process.env.CRON_SECRET;
    delete process.env.CRON_SECRET;

    try {
      const response = await submitIndexNowDeployment(
        new Request("https://cmux.com/api/cron/indexnow", { method: "POST" }),
      );

      expect(response.status).toBe(401);
    } finally {
      if (originalSecret === undefined) {
        delete process.env.CRON_SECRET;
      } else {
        process.env.CRON_SECRET = originalSecret;
      }
    }
  });
});
