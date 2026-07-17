import { buildLocalizedBlogRssFeed } from "../lib/localized-blog-feed";

export const dynamic = "force-static";

export async function GET(): Promise<Response> {
  return new Response(await buildLocalizedBlogRssFeed("en"), {
    headers: {
      "Cache-Control": "public, max-age=0, s-maxage=3600",
      "Content-Language": "en",
      "Content-Type": "application/rss+xml; charset=utf-8",
    },
  });
}
