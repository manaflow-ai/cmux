import { blogPosts, type BlogPost } from "../[locale]/components/blog-posts";

const siteUrl = "https://cmux.com";
const feedUrl = `${siteUrl}/feed.xml`;

export function buildBlogRssFeed(
  posts: readonly BlogPost[] = blogPosts,
): string {
  const items = posts
    .map((post) => {
      const url = `${siteUrl}/blog/${post.slug}`;
      return [
        "    <item>",
        `      <title>${escapeXml(post.title)}</title>`,
        `      <link>${url}</link>`,
        `      <guid isPermaLink="true">${url}</guid>`,
        `      <pubDate>${rssDate(post.date)}</pubDate>`,
        `      <description>${escapeXml(post.summary)}</description>`,
        "    </item>",
      ].join("\n");
    })
    .join("\n");

  const lastBuildDate = rssDate(posts[0]?.date ?? "2026-02-12");
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
    "  <channel>",
    "    <title>cmux blog</title>",
    `    <link>${siteUrl}/blog</link>`,
    "    <description>News and updates from the cmux team</description>",
    "    <language>en-us</language>",
    `    <lastBuildDate>${lastBuildDate}</lastBuildDate>`,
    `    <atom:link href="${feedUrl}" rel="self" type="application/rss+xml" />`,
    "    <generator>cmux</generator>",
    "    <docs>https://www.rssboard.org/rss-specification</docs>",
    items,
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function rssDate(date: string): string {
  return new Date(`${date}T00:00:00.000Z`).toUTCString();
}
