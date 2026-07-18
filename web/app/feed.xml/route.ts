import { buildLocalizedBlogRssFeed } from "../lib/localized-blog-feed";
import { routing } from "../../i18n/routing";

export const dynamic = "force-static";

export async function GET(): Promise<Response> {
  return new Response(await buildLocalizedBlogRssFeed(routing.defaultLocale), {
    headers: {
      "Cache-Control": "public, max-age=0, s-maxage=3600",
      "Content-Language": routing.defaultLocale,
      "Content-Type": "application/rss+xml; charset=utf-8",
    },
  });
}
