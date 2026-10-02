import { routing, type Locale } from "../../../i18n/routing";
import { buildLocalizedBlogRssFeed } from "../../lib/localized-blog-feed";

export const dynamic = "force-static";
export const dynamicParams = false;

export function generateStaticParams() {
  return routing.locales
    .filter((locale) => locale !== routing.defaultLocale)
    .map((locale) => ({ locale }));
}

export async function GET(
  _request: Request,
  context: { params: Promise<{ locale: string }> },
): Promise<Response> {
  const { locale } = await context.params;
  if (!routing.locales.includes(locale as Locale) || locale === routing.defaultLocale) {
    return new Response("Not found", { status: 404 });
  }

  return new Response(await buildLocalizedBlogRssFeed(locale as Locale), {
    headers: {
      "Cache-Control": "public, max-age=0, s-maxage=3600",
      "Content-Language": locale,
      "Content-Type": "application/rss+xml; charset=utf-8",
    },
  });
}
