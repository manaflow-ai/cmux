import { buildBlogRssFeed } from "../lib/blog-feed";

export const dynamic = "force-static";

export function GET(): Response {
  return new Response(buildBlogRssFeed(), {
    headers: {
      "Content-Type": "application/rss+xml; charset=utf-8",
      "Cache-Control": "public, max-age=0, s-maxage=3600",
    },
  });
}
